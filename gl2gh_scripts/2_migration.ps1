# GitLab -> GitHub parallel migration runner (GitHub Actions optimized)
# - Configurable via parameters for GitHub Actions workflow
# - Keeps your status bar and CSV writes
# - Ensures background job emits only the final result object (no log noise on the output stream)
# - Robust Receive-Job parsing so $failed increments correctly

param(
    [Parameter(Mandatory=$false)]
    [int]$MaxConcurrent = 3,

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "projects.csv",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [bool]$UseGithubStorage = $true
)

# Read GitHub API URL from environment
$GITHUB_TYPE = $env:GITHUB_TYPE
$github_api_url = $env:GITHUB_API_URL

if ([string]::IsNullOrWhiteSpace($GITHUB_TYPE)) {
    Write-Host "[ERROR] GITHUB_TYPE env not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GITHUB_TYPE = 'GitHub' or 'GitHubDR'" -ForegroundColor Yellow
    exit 1
}

if ($GITHUB_TYPE -eq "GitHub") {
    Write-Host "[INFO] GITHUB_TYPE is set to GitHub"
    $github_api_url = "https://api.github.com"
    Write-Host "[INFO] Target API URL: $github_api_url"

} elseif ($GITHUB_TYPE -eq "GitHubDR") {
    Write-Host "[INFO] GITHUB_TYPE is set to GitHubDR"

    if ([string]::IsNullOrWhiteSpace($github_api_url)) {
        Write-Host "[ERROR] GITHUB_API_URL env not set." -ForegroundColor Red
        Write-Host "Set it using: `$env:GITHUB_API_URL='https://api.SUBDOMAIN.ghe.com'" -ForegroundColor Yellow
        exit 1
    } else {
        Write-Host "[INFO] Target API URL: $github_api_url"
    }

} else {
    Write-Host "[ERROR] Invalid GITHUB_TYPE. Use GitHub or GitHubDR." -ForegroundColor Red
    exit 1
}

# Export back so background jobs / child processes see the same value
$env:GITHUB_API_URL = $github_api_url

# GitLab source server (single instance for the whole CSV, mirrors $github_api_url above)
$GITLAB_SERVER_URL = $env:GITLAB_SERVER_URL
if ([string]::IsNullOrWhiteSpace($GITLAB_SERVER_URL)) {
    Write-Host "[ERROR] GITLAB_SERVER_URL env not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'" -ForegroundColor Yellow
    exit 1
}
$GITLAB_SERVER_URL = $GITLAB_SERVER_URL.TrimEnd('/')
$env:GITLAB_SERVER_URL = $GITLAB_SERVER_URL

# migrate-repo reads GH_PAT and GITLAB_PAT directly from the environment - make sure they're set before running this script
if ([string]::IsNullOrWhiteSpace($env:GH_PAT)) {
    Write-Host "[ERROR] GH_PAT env not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GH_PAT = 'your-github-pat-here'" -ForegroundColor Yellow
    exit 1
}
if ([string]::IsNullOrWhiteSpace($env:GITLAB_PAT)) {
    Write-Host "[ERROR] GITLAB_PAT env not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GITLAB_PAT = 'your-gitlab-pat-here'" -ForegroundColor Yellow
    exit 1
}

# -------------------- Settings --------------------
# Validate max concurrent limit
if ($MaxConcurrent -gt 5) {
    Write-Host "[ERROR] Maximum concurrent migrations ($MaxConcurrent) exceeds the allowed limit of 5." -ForegroundColor Red
    Write-Host "[ERROR] Please set MaxConcurrent to 5 or less." -ForegroundColor Red
    exit 1
}

if ($MaxConcurrent -lt 1) {
    Write-Host "[ERROR] MaxConcurrent must be at least 1." -ForegroundColor Red
    exit 1
}

# Repository list (from inventory-report + github mapping columns) - read from CSV
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputCsvPath = "repo_migration_output-$timestamp.csv"
} else {
    $outputCsvPath = $OutputPath
}

if (-not (Test-Path -Path $CsvPath)) {
    Write-Host "[ERROR] CSV file not found at path: $CsvPath" -ForegroundColor Red
    exit 1
}

$REOSource = Import-Csv -Path $CsvPath
if ($REOSource.Count -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

# Convert to ArrayList for mutation-friendly operations later
$REPOS = New-Object System.Collections.ArrayList
foreach ($repo in $REOSource) { [void]$REPOS.Add($repo) }

# Validate required columns
$requiredColumns = @('group-path', 'project', 'github_org', 'github_repo', 'gh_repo_visibility')
$firstRepo = $REPOS[0]
$missingColumns = $requiredColumns | Where-Object { $_ -notin $firstRepo.PSObject.Properties.Name }

if ($missingColumns) {
    Write-Host "[ERROR] CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host "[ERROR] Required columns: $($requiredColumns -join ', ')" -ForegroundColor Red
    exit 1
}

# Ensure expected columns exist / initialize
foreach ($repo in $REPOS) {
    if ($repo.PSObject.Properties["Migration_Status"]) {
        $repo.Migration_Status = "Pending"
    } else {
        $repo | Add-Member -NotePropertyName Migration_Status -NotePropertyValue "Pending"
    }

    if ($repo.PSObject.Properties["Log_File"]) {
        $repo.Log_File = ""
    } else {
        $repo | Add-Member -NotePropertyName Log_File -NotePropertyValue ""
    }
}

function Write-MigrationStatusCsv {
    $REPOS | Export-Csv -Path $outputCsvPath -NoTypeInformation
}

Write-MigrationStatusCsv
Write-Host "[INFO] Starting migration with $MaxConcurrent concurrent jobs..."
Write-Host "[INFO] Processing $($REPOS.Count) repositories from: $CsvPath" -ForegroundColor Cyan
Write-Host "[INFO] Initialized migration status output: $outputCsvPath" -ForegroundColor Cyan

# -------------------- MAIN: parallel migration with concurrent jobs --------------------
$queue      = [System.Collections.ArrayList]@($REPOS)
$inProgress = [System.Collections.ArrayList]@()
$migrated   = [System.Collections.ArrayList]@()
$failed     = [System.Collections.ArrayList]@()

$script:StatusLineWidth = 0

function Show-StatusBar {
    param($queue, $inProgress, $migrated, $failed)
    $queueCount     = $queue.Count
    $progressCount  = $inProgress.Count
    $migratedCount  = $migrated.Count
    $failedCount    = $failed.Count

    $statusLine  = "QUEUE: $queueCount | "
    $statusLine += "IN PROGRESS: $progressCount | "
    $statusLine += "MIGRATED: $migratedCount | "
    $statusLine += "MIGRATION FAILED: $failedCount"

    if ($statusLine.Length -gt $script:StatusLineWidth) {
        $script:StatusLineWidth = $statusLine.Length
    }

    $statusLine = $statusLine.PadRight($script:StatusLineWidth)
    Write-Host "`r$statusLine" -NoNewline -ForegroundColor Cyan
}

while ($queue.Count -gt 0 -or $inProgress.Count -gt 0) {
    # Start new jobs if below max concurrent
    while ($inProgress.Count -lt $MaxConcurrent -and $queue.Count -gt 0) {
        $repo = $queue[0]
        $queue.RemoveAt(0)

        $gitlabGroup    = $repo.'group-path'
        $gitlabProject  = $repo.project
        $githubOrg      = $repo.github_org
        $githubRepo     = $repo.github_repo
        $gh_repo_visibility = $repo.gh_repo_visibility

        # Create log file (per repo)
        $logFile = "migration-$githubRepo-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

        # Ensure log directory exists (if any)
        $logDir = Split-Path -Path $logFile
        if ($logDir) { $null = New-Item -ItemType Directory -Force -Path $logDir }

        $repo.Log_File = $logFile
        Write-MigrationStatusCsv

        # Background job script: emits ONLY @{ MigrationSuccess = <bool> }
        $scriptBlock = {
            param($gitlabGroup, $gitlabProject, $githubOrg, $githubRepo, $gh_repo_visibility, $useGithubStorage, $logFile, $workDir)

            Set-Location -Path $workDir

            function Migrate-Repository {
                param ($gitlabGroup, $gitlabProject, $githubOrg, $githubRepo, $gh_repo_visibility, $useGithubStorage, $logFile)

                $github_api_url = $env:GITHUB_API_URL
                $gitlab_server_url = $env:GITLAB_SERVER_URL

                "[{0}] [START] Migration: {1}/{2} -> {3}/{4} (gh_repo_visibility: {5})" -f `
                (Get-Date), $gitlabGroup, $gitlabProject, $githubOrg, $githubRepo, $gh_repo_visibility |
                Tee-Object -FilePath $logFile -Append | Out-Null

                $extraArgs = @()
                if ($useGithubStorage) { $extraArgs += '--use-github-storage' }

                "[{0}] [DEBUG] Running: gh gl2gh migrate-repo --gitlab-server-url {1} --gitlab-group {2} --gitlab-project {3} --github-org {4} --github-repo {5} --target-api-url {6} --target-repo-visibility {7} {8}" -f `
                (Get-Date), $gitlab_server_url, $gitlabGroup, $gitlabProject, $githubOrg, $githubRepo, $github_api_url, $gh_repo_visibility, ($extraArgs -join ' ') |
                Tee-Object -FilePath $logFile -Append | Out-Null

                & gh gl2gh migrate-repo `
                    --gitlab-server-url $gitlab_server_url `
                    --gitlab-group $gitlabGroup `
                    --gitlab-project $gitlabProject `
                    --github-org $githubOrg `
                    --github-repo $githubRepo `
                    --target-api-url $github_api_url `
                    --target-repo-visibility $gh_repo_visibility `
                    @extraArgs *>&1 |
                    Tee-Object -FilePath $logFile -Append | Out-Null

                $migrateExit = $LASTEXITCODE

                $logContent = Get-Content -Path $logFile -Raw
                if ($logContent -match "No operation will be performed") { return $false }
                if ($logContent -notmatch "State: SUCCEEDED") { return $false }

                if ($migrateExit -eq 0) {
                    "[{0}] [SUCCESS] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $gitlabGroup, $gitlabProject, $githubOrg, $githubRepo |
                    Tee-Object -FilePath $logFile -Append | Out-Null
                    return $true
                } else {
                    "[{0}] [FAILED] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $gitlabGroup, $gitlabProject, $githubOrg, $githubRepo |
                    Tee-Object -FilePath $logFile -Append | Out-Null
                    return $false
                }
            }

            # Execute migration and return a simple result object
            $migrationSuccess = Migrate-Repository -gitlabGroup $gitlabGroup -gitlabProject $gitlabProject -githubOrg $githubOrg -githubRepo $githubRepo -gh_repo_visibility $gh_repo_visibility -useGithubStorage $useGithubStorage -logFile $logFile
            return @{ MigrationSuccess = $migrationSuccess }
        }

        # Start background job
        $workDir = (Get-Location).Path
        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $gitlabGroup, $gitlabProject, $githubOrg, $githubRepo, $gh_repo_visibility, $UseGithubStorage, $logFile, $workDir

        $null = $inProgress.Add([PSCustomObject]@{
            Job = $job
            Repo = $repo
            LogFile = $logFile
            LastOutputLength = 0   # track how much of the log we've printed
        })

        Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
    }

    # --- Stream new output from each job's log file to the console ---
    foreach ($item in @($inProgress)) {
        if (Test-Path -Path $item.LogFile) {
            try {
                $content = Get-Content -Path $item.LogFile -Raw
                $newLen = $content.Length

                if ($newLen -gt $item.LastOutputLength) {
                    $delta = $content.Substring($item.LastOutputLength)
                    $item.LastOutputLength = $newLen

                    # Print the new portion, then re-render status bar
                    if ($delta) {
                        Write-Host ""
                        # Trim trailing newlines to keep the status bar tidy
                        $delta.TrimEnd("`r","`n") -split "(`r`n|`n|`r)" | ForEach-Object {
                            if ($_ -ne '') { Write-Host $_ }
                        }
                        Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
                    }
                }
            } catch {
                # Ignore transient read errors while the job is writing
            }
        }
    }

    # --- Check completed/failed/stopped jobs ---
    foreach ($item in @($inProgress)) {
        if ($item.Job.State -in 'Completed','Failed','Stopped') {
            # Receive only result objects; logs have already been printed from files
            $jobOutput = Receive-Job -Job $item.Job
            Remove-Job -Job $item.Job

            # Pick the last object that actually has the MigrationSuccess property
            $result =
              $jobOutput |
              Where-Object { $_ -is [hashtable] -and $_.ContainsKey('MigrationSuccess') } |
              Select-Object -Last 1

            if ($null -eq $result) {
                # If the job didn't return the expected result object, treat as failure
                $null = $failed.Add($item.Repo)
                $item.Repo.Migration_Status = "Failure"
            }
            elseif ($result.MigrationSuccess -eq $true) {
                $null = $migrated.Add($item.Repo)
                $item.Repo.Migration_Status = "Success"
            }
            else {
                $null = $failed.Add($item.Repo)
                $item.Repo.Migration_Status = "Failure"
            }

            Write-MigrationStatusCsv

            $inProgress.Remove($item)
            Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
        }
    }

    Start-Sleep -Seconds 5
}

Write-Host "`n[INFO] All migrations completed."
Write-Host "[SUMMARY] Total: $($REPOS.Count) | Migrated: $($migrated.Count) | Failed: $($failed.Count) " -ForegroundColor Green

Write-MigrationStatusCsv
Write-Host "[INFO] Wrote migration results with Migration_Status column: $outputCsvPath" -ForegroundColor Cyan

# Exit with error code if there were failures (for GitHub Actions)
if ($failed.Count -gt 0) {
    Write-Host "[WARNING] Migration completed with $($failed.Count) failures" -ForegroundColor Yellow
    # Don't exit with error - let workflow handle it
}
