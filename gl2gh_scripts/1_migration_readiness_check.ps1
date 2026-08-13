param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = "projects.csv"
)

$GITLAB_PAT = $env:GITLAB_PAT
if (-not $GITLAB_PAT) {
    Write-Host "[ERROR] GITLAB_PAT environment variable is not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GITLAB_PAT = 'your-pat-token-here'" -ForegroundColor Yellow
    exit 1
}

$GITLAB_SERVER_URL = $env:GITLAB_SERVER_URL
if (-not $GITLAB_SERVER_URL) {
    Write-Host "[ERROR] GITLAB_SERVER_URL environment variable is not set." -ForegroundColor Red
    Write-Host "Set it using: `$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'" -ForegroundColor Yellow
    exit 1
}
$GITLAB_SERVER_URL = $GITLAB_SERVER_URL.TrimEnd('/')
$GitLabHeaders = @{ "PRIVATE-TOKEN" = $GITLAB_PAT }

# Declare arrays for validation results and flags for REST API failures
$activeMrSummary = @()
$runningPipelineSummary = @()
$mrCheckFailed = $false
$pipelineCheckFailed = $false

# Pipeline statuses that indicate a pipeline has not finished running yet
# Reference: https://docs.gitlab.com/ee/api/pipelines.html#list-project-pipelines
$ActivePipelineStatuses = @('created', 'waiting_for_resource', 'preparing', 'pending', 'running', 'scheduled')

# Read CSV file
if (-not (Test-Path $CsvPath)) {
    Write-Host "[ERROR] CSV file '$CsvPath' not found. Exiting..." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`nReading input from file: '$CsvPath'"
}

# Import CSV
try {
    $projectList = Import-Csv -LiteralPath $CsvPath -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] CSV header validation failed." -ForegroundColor Red
    Write-Host "Expected columns: group-path, project" -ForegroundColor Yellow
    Write-Host "Reason: Header row is missing or invalid." -ForegroundColor Yellow
    exit 1
}

# Validate required columns
$requiredColumns = @('group-path', 'project')

if ($projectList.Count -eq 0) {

    # Read header line
    $headerLine = Get-Content -LiteralPath $CsvPath -TotalCount 1 -ErrorAction SilentlyContinue

    # Verify headers are present
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        Write-Host "[ERROR] CSV header validation failed. File does not contain a valid header row." -ForegroundColor Red
        Write-Host "Expected columns: group-path, project" -ForegroundColor Yellow
        exit 1
    }

    $csvColumns = $headerLine.Split(',') | ForEach-Object { $_.Trim().Trim('"') }
    $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

    if ($missingColumns.Count -gt 0) {
        Write-Host "[ERROR] CSV header validation failed. Missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
        Write-Host "Expected columns: group-path, project" -ForegroundColor Yellow
        exit 1
    }

    # Verify atleast one row with data present
    Write-Host "[ERROR] CSV file contains valid headers but no project entries." -ForegroundColor Red
    exit 1
}

$csvColumns = $projectList[0].PSObject.Properties.Name
$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }

if ($missingColumns.Count -gt 0) {
    Write-Host "[ERROR] CSV header validation failed. Missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host "Expected columns: group-path, project" -ForegroundColor Yellow
    exit 1
}

# Validate GitLab PAT against the server (a single PAT is valid for the whole server, unlike ADO's per-org PATs)
try {
    $resp = Invoke-WebRequest -Uri "$GITLAB_SERVER_URL/api/v4/user" -Headers $GitLabHeaders -ErrorAction Stop

    if ($resp.StatusCode -ne 200) {
        Write-Host "[ERROR] GITLAB_PAT validation failed (StatusCode: $($resp.StatusCode))" -ForegroundColor Red
        exit 1
    }
}
catch {
    $statusCode = $null

    try {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode.value__
        }
    }
    catch { }

    if (-not $statusCode -and $_.Exception.Message -match '(\d{3})\s*\(([^)]+)\)') {
        $statusCode = [int]$Matches[1]
    }

    Write-Host "[ERROR] GITLAB_PAT validation failed against $GITLAB_SERVER_URL$(if ($statusCode) { " (HTTP $statusCode)" })" -ForegroundColor Red
    Write-Host "Verify GITLAB_SERVER_URL is correct and GITLAB_PAT has API access." -ForegroundColor Yellow
    exit 1
}

Write-Host "`nScanning projects for open merge requests and active pipelines..."
foreach ($entry in $projectList) {
    $groupPath = $entry.'group-path'
    $projectName = $entry.project
    $projectPath = "$groupPath/$projectName"
    $encodedProjectPath = [System.Uri]::EscapeDataString($projectPath)

    # Resolve project ID from its full namespace path
    try {
        $project = Invoke-RestMethod -Method GET -Uri "$GITLAB_SERVER_URL/api/v4/projects/$encodedProjectPath" -Headers $GitLabHeaders -ErrorAction Stop
        $projectId = $project.id
    }
    catch {
        $mrCheckFailed = $true
        $pipelineCheckFailed = $true
        Write-Host "[ERROR] Failed to resolve project '$projectPath'. Skipping MR/pipeline checks for this project." -ForegroundColor Red
        continue
    }

    # Get open merge requests (paginated)
    try {
        $page = 1
        $perPage = 100
        while ($true) {
            $mrUri = "$GITLAB_SERVER_URL/api/v4/projects/$projectId/merge_requests?state=opened&per_page=$perPage&page=$page"
            $mrs = Invoke-RestMethod -Method GET -Uri $mrUri -Headers $GitLabHeaders -ErrorAction Stop

            foreach ($mr in $mrs) {
                $activeMrSummary += @{
                    Project = $projectPath
                    Title   = $mr.title
                    Status  = $mr.state
                    Url     = $mr.web_url
                }
            }

            if (@($mrs).Count -lt $perPage) { break }
            $page++
        }
    }
    catch {
        $mrCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve merge requests for project '$projectPath'." -ForegroundColor Red
    }

    # Get active (unfinished) pipelines
    try {
        $page = 1
        $perPage = 100
        while ($true) {
            $pipelineUri = "$GITLAB_SERVER_URL/api/v4/projects/$projectId/pipelines?per_page=$perPage&page=$page"
            $pipelines = Invoke-RestMethod -Method GET -Uri $pipelineUri -Headers $GitLabHeaders -ErrorAction Stop

            $activePipelines = $pipelines | Where-Object { $_.status -in $ActivePipelineStatuses }

            foreach ($pipeline in $activePipelines) {
                $runningPipelineSummary += @{
                    Project = $projectPath
                    Ref     = $pipeline.ref
                    Status  = $pipeline.status
                    Url     = $pipeline.web_url
                }
            }

            if (@($pipelines).Count -lt $perPage) { break }
            $page++
        }
    }
    catch {
        $pipelineCheckFailed = $true
        Write-Host "[ERROR] Failed to retrieve pipelines for project '$projectPath'." -ForegroundColor Red
    }
}

# Final Summary
Write-Host "`nPre-Migration Validation Summary"
Write-Host "================================"

if (-not $mrCheckFailed) {
    if ($activeMrSummary.Count -gt 0) {
        Write-Host "[WARNING] Detected Open Merge Request(s):" -ForegroundColor Yellow
        foreach ($entry in $activeMrSummary) {
            Write-Host "Project: $($entry.Project) | Title: $($entry.Title) | Status: $($entry.Status)"
            Write-Host "MR URL: $($entry.Url)`n"
        }
    }
    else {
        Write-Host "`nMerge Request Summary --> No Open Merge Requests" -ForegroundColor Green
    }
}

if (-not $pipelineCheckFailed) {
    if ($runningPipelineSummary.Count -gt 0) {
        Write-Host "`n[WARNING] Detected Active Pipeline(s):" -ForegroundColor Yellow
        foreach ($entry in $runningPipelineSummary) {
            Write-Host "Project: $($entry.Project) | Ref: $($entry.Ref) | Status: $($entry.Status)"
            Write-Host "Run URL: $($entry.Url)`n"
        }
    }
    else {
        Write-Host "`nPipeline Summary --> No Active Pipelines" -ForegroundColor Green
    }
}

$hasActiveItems = ($activeMrSummary.Count -gt 0) -or ($runningPipelineSummary.Count -gt 0)
$hasFailures = $mrCheckFailed -or $pipelineCheckFailed

if ($hasFailures -and -not $hasActiveItems) {
    $finalMessage = "Validation checks could not be completed due to API failures. Please review errors before proceeding."
    $finalColor = "Red"
}
elseif ($hasFailures -and $hasActiveItems) {
    $finalMessage = "Active items detected, but some validation checks failed. Review warnings and errors before proceeding."
    $finalColor = "Yellow"
}
elseif (-not $hasFailures -and $hasActiveItems) {
    $finalMessage = "Open merge requests or active pipelines found. Continue with migration if you have reviewed and are comfortable proceeding."
    $finalColor = "Yellow"
}
else {
    $finalMessage = "No open merge requests or active pipelines detected. You can proceed with migration."
    $finalColor = "Green"
}
Write-Host "`n$finalMessage`n" -ForegroundColor $finalColor
