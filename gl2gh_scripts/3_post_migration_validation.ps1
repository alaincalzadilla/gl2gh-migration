# post-migration-validation.ps1

param(
    [string]$CsvPath = "projects.csv"
)

# Log file with timestamp
$LogFile = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

# Branch validation threshold
$BranchValidationThreshold = 10

function Write-Log {
    param(
        [string]$Message
    )

    $Message | Tee-Object -FilePath $LogFile -Append
}

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function UrlEncode {
    param(
        [string]$Value
    )

    return [System.Uri]::EscapeDataString($Value)
}

function Test-ArrayContains {
    param(
        [string]$Value,
        [string[]]$Array
    )

    return $Array -contains $Value
}

function Invoke-GitHubApi {
    param(
        [string]$ApiPath
    )

    try {
        $response = gh api $ApiPath 2>$null

        if ([string]::IsNullOrWhiteSpace($response)) {
            return $null
        }

        return $response | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-GitHubBranches {
    param(
        [string]$GitHubOrg,
        [string]$GitHubRepo
    )

    try {
        # Same GitHub branches API, using gh pagination support.
        # --slurp is used so paginated JSON remains valid.
        $response = gh api "/repos/$GitHubOrg/$GitHubRepo/branches" --paginate --slurp 2>$null

        if ([string]::IsNullOrWhiteSpace($response)) {
            return @()
        }

        $pages = $response | ConvertFrom-Json

        $branches = @()

        foreach ($page in $pages) {
            foreach ($branch in $page) {
                $branches += $branch.name
            }
        }

        return $branches
    }
    catch {
        return @()
    }
}

function Invoke-GitLabApi {
    param(
        [string]$ApiPath
    )

    try {
        $uri = "$($env:GITLAB_SERVER_URL.TrimEnd('/'))/api/v4/$ApiPath"
        return Invoke-RestMethod -Uri $uri -Headers @{ "PRIVATE-TOKEN" = $env:GITLAB_PAT } -Method Get
    }
    catch {
        return $null
    }
}

function Get-GitLabBranches {
    param(
        [int]$GitLabProjectId
    )

    $branches = @()
    $page = 1
    $perPage = 100

    while ($true) {
        $batch = Invoke-GitLabApi -ApiPath "projects/$GitLabProjectId/repository/branches?per_page=$perPage&page=$page"

        if ($null -eq $batch) { break }

        foreach ($branch in $batch) {
            $branches += $branch.name
        }

        if (@($batch).Count -lt $perPage) { break }
        $page++
    }

    return $branches
}

function Validate-Migration {
    param(
        [string]$GitLabGroup,
        [string]$GitLabProject,
        [string]$GitHubOrg,
        [string]$GitHubRepo
    )

    Write-Log "[$(Get-UtcTimestamp)] Validating migration: $GitHubRepo"

    # --- GitHub repo info ---
    try {
        gh repo view "$GitHubOrg/$GitHubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate > "validation-$GitHubRepo.json" 2>$null
    }
    catch {
        # Optional information, so continue
    }

    # --- GitHub branches ---
    $GhBranchArray = @(Get-GitHubBranches -GitHubOrg $GitHubOrg -GitHubRepo $GitHubRepo)

    if ($GhBranchArray.Count -eq 0) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitHub branches for $GitHubOrg/$GitHubRepo"
        return
    }

    # --- GitLab auth ---
    if ([string]::IsNullOrWhiteSpace($env:GITLAB_PAT)) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: GITLAB_PAT environment variable is not set"
        return
    }

    if ([string]::IsNullOrWhiteSpace($env:GITLAB_SERVER_URL)) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: GITLAB_SERVER_URL environment variable is not set"
        return
    }

    # --- Resolve GitLab project by its full namespace path ---
    $GitLabProjectPath = "$GitLabGroup/$GitLabProject"
    $EncodedProjectPath = UrlEncode $GitLabProjectPath

    $ProjectInfo = Invoke-GitLabApi -ApiPath "projects/$EncodedProjectPath"

    if ($null -eq $ProjectInfo) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitLab project '$GitLabProjectPath'"
        return
    }

    $GitLabProjectId = $ProjectInfo.id

    # --- Get default branches ---
    $GhRepoInfo = Invoke-GitHubApi -ApiPath "repos/$GitHubOrg/$GitHubRepo"

    if ($null -eq $GhRepoInfo) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitHub repo details for $GitHubOrg/$GitHubRepo"
        return
    }

    $GhDefaultBranch = $GhRepoInfo.default_branch
    $GitLabDefaultBranch = $ProjectInfo.default_branch

    Write-Log "[$(Get-UtcTimestamp)] Default Branch: GitLab=$GitLabDefaultBranch | GitHub=$GhDefaultBranch"

    # --- GitLab branches using project_id ---
    $GitLabBranchArray = @(Get-GitLabBranches -GitLabProjectId $GitLabProjectId)

    if ($GitLabBranchArray.Count -eq 0) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitLab branches for $GitLabProjectPath"
        return
    }

    # --- Compare branch counts ---
    $GhBranchCount = $GhBranchArray.Count
    $GitLabBranchCount = $GitLabBranchArray.Count

    $BranchCountStatus = "❌ Not Matching"

    if ($GhBranchCount -eq $GitLabBranchCount) {
        $BranchCountStatus = "✅ Matching"
    }

    Write-Log "[$(Get-UtcTimestamp)] Branch Count: GitLab=$GitLabBranchCount | GitHub=$GhBranchCount | $BranchCountStatus"

    # --- Compare branch names ---
    $MissingInGh = @()
    $MissingInGitLab = @()

    foreach ($GitLabBranch in $GitLabBranchArray) {
        if ($GhBranchArray -notcontains $GitLabBranch) {
            $MissingInGh += $GitLabBranch
        }
    }

    foreach ($GhBranch in $GhBranchArray) {
        if ($GitLabBranchArray -notcontains $GhBranch) {
            $MissingInGitLab += $GhBranch
        }
    }

    if ($MissingInGh.Count -gt 0) {
        Write-Log "[$(Get-UtcTimestamp)] Branches missing in GitHub: $($MissingInGh -join ' ')"
    }

    if ($MissingInGitLab.Count -gt 0) {
        Write-Log "[$(Get-UtcTimestamp)] Branches missing in GitLab: $($MissingInGitLab -join ' ')"
    }

    # --- Decide which branches to validate ---
    $BranchesToValidate = @()
    $MaxBranchCount = [Math]::Max($GitLabBranchCount, $GhBranchCount)

    if ($MaxBranchCount -gt $BranchValidationThreshold) {
        $BranchesToValidate = @($GhDefaultBranch)
        Write-Log "[$(Get-UtcTimestamp)] Branch count is above $BranchValidationThreshold. Validating default branch only: $GhDefaultBranch"
    }
    else {
        $BranchesToValidate = @($GitLabBranchArray)
        Write-Log "[$(Get-UtcTimestamp)] Branch count is $BranchValidationThreshold or below. Validating all branches."
    }

    # --- Validate commit counts and latest commit IDs ---
    foreach ($BranchName in $BranchesToValidate) {

        if ([string]::IsNullOrWhiteSpace($BranchName) -or $BranchName -eq "null") {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Empty branch name found. Skipping validation."
            continue
        }

        if (-not (Test-ArrayContains -Value $BranchName -Array $GhBranchArray)) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Branch '$BranchName' exists in GitLab but missing in GitHub. Skipping commit/SHA validation for this branch."
            continue
        }

        if (-not (Test-ArrayContains -Value $BranchName -Array $GitLabBranchArray)) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Branch '$BranchName' exists in GitHub but missing in GitLab. Skipping commit/SHA validation for this branch."
            continue
        }

        # --- GitHub commits ---
        $GhCommitCount = 0
        $GhLatestSha = ""
        $Page = 1
        $PerPage = 100

        while ($true) {
            $EncodedGhBranchName = UrlEncode $BranchName

            # Same GitHub commits API
            $GhCommitsPath = "/repos/$GitHubOrg/$GitHubRepo/commits?sha=$EncodedGhBranchName&page=$Page&per_page=$PerPage"

            try {
                $GhCommitsRaw = gh api $GhCommitsPath 2>$null

                if ([string]::IsNullOrWhiteSpace($GhCommitsRaw)) {
                    break
                }

                $GhCommits = $GhCommitsRaw | ConvertFrom-Json
            }
            catch {
                Write-Log "[$(Get-UtcTimestamp)] ERROR: Non-JSON GitHub commits for '$BranchName' page=$Page."
                break
            }

            $CommitBatchCount = @($GhCommits).Count

            if ($Page -eq 1 -and $CommitBatchCount -gt 0) {
                $GhLatestSha = @($GhCommits)[0].sha
            }

            $GhCommitCount += $CommitBatchCount
            $Page++

            if ($CommitBatchCount -lt $PerPage) {
                break
            }
        }

        # --- GitLab commits ---
        $GitLabCommitCount = 0
        $GitLabLatestSha = ""
        $GlPage = 1
        $GlPerPage = 100
        $EncodedBranch = UrlEncode $BranchName

        while ($true) {
            # Same GitLab commits API
            $GitLabCommitsPath = "projects/$GitLabProjectId/repository/commits?ref_name=$EncodedBranch&per_page=$GlPerPage&page=$GlPage"

            $GitLabCommits = Invoke-GitLabApi -ApiPath $GitLabCommitsPath

            if ($null -eq $GitLabCommits) {
                Write-Log "[$(Get-UtcTimestamp)] ERROR: Failed to fetch GitLab commits for '$BranchName' page=$GlPage."
                break
            }

            $GlBatchCount = @($GitLabCommits).Count

            if ($GlPage -eq 1 -and $GlBatchCount -gt 0) {
                $GitLabLatestSha = @($GitLabCommits)[0].id
            }

            $GitLabCommitCount += $GlBatchCount
            $GlPage++

            if ($GlBatchCount -lt $GlPerPage) {
                break
            }
        }

        # --- Match status ---
        $CommitCountStatus = "❌ Not Matching"
        $ShaStatus = "❌ Not Matching"

        if ($GhCommitCount -eq $GitLabCommitCount) {
            $CommitCountStatus = "✅ Matching"
        }

        if (-not [string]::IsNullOrWhiteSpace($GhLatestSha) -and $GhLatestSha -eq $GitLabLatestSha) {
            $ShaStatus = "✅ Matching"
        }

        Write-Log "[$(Get-UtcTimestamp)] Branch '$BranchName': GitLab Commits=$GitLabCommitCount | GitHub Commits=$GhCommitCount | $CommitCountStatus"
        Write-Log "[$(Get-UtcTimestamp)] Branch '$BranchName': GitLab SHA=$GitLabLatestSha | GitHub SHA=$GhLatestSha | $ShaStatus"
    }

    Write-Log "[$(Get-UtcTimestamp)] Validation complete for $GitHubRepo"
}

function Validate-FromCsv {
    param(
        [string]$CsvPath = "projects.csv"
    )

    if (-not (Test-Path $CsvPath)) {
        Write-Log "[$(Get-UtcTimestamp)] ERROR: CSV file not found: $CsvPath"
        return
    }

    $Rows = Import-Csv -Path $CsvPath

    foreach ($Row in $Rows) {
        $GitLabGroup = $Row.'group-path'
        $GitLabProject = $Row.project
        $GitHubOrg = $Row.github_org
        $GitHubRepo = $Row.github_repo

        if (
            [string]::IsNullOrWhiteSpace($GitLabGroup) -or
            [string]::IsNullOrWhiteSpace($GitLabProject) -or
            [string]::IsNullOrWhiteSpace($GitHubOrg) -or
            [string]::IsNullOrWhiteSpace($GitHubRepo)
        ) {
            Write-Log "[$(Get-UtcTimestamp)] WARNING: Skipping invalid or incomplete CSV row."
            continue
        }

        Write-Log "[$(Get-UtcTimestamp)] Processing: $GitLabProject -> $GitHubRepo"

        Validate-Migration `
            -GitLabGroup $GitLabGroup `
            -GitLabProject $GitLabProject `
            -GitHubOrg $GitHubOrg `
            -GitHubRepo $GitHubRepo
    }

    Write-Log "[$(Get-UtcTimestamp)] All validations from CSV completed"
}

# --- Batch mode ---
Validate-FromCsv -CsvPath $CsvPath
