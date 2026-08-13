# gl2gh-migration

PowerShell scripts that drive the `gh gl2gh` GitHub CLI extension to migrate repositories from
GitLab to GitHub, using GitHub's GEI ("Octoshift") migration engine under the hood.

## Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) installed and on `PATH`.
- The `gl2gh` extension installed: `gh extension install github/gh-gl2gh`.
- A **GitLab personal access token** (`GITLAB_PAT`) with API access to the source group/projects.
- A **GitHub personal access token** (`GH_PAT`) with permissions to create repos in the target org.
- PowerShell 7+ (`pwsh`).

## Migration steps

### 1. Generate the GitLab inventory report

Set the source GitLab server and group, then run `gh gl2gh inventory-report` to produce
`groups.csv` and `projects.csv` in the current directory:

```powershell
$env:GITLAB_PAT = 'xxxx'
$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'
$env:GITLAB_GROUP = 'my-group'

gh gl2gh inventory-report --gitlab-server-url "$env:GITLAB_SERVER_URL" --gitlab-group "$env:GITLAB_GROUP"
```

This also writes `<timestamp>.octoshift.log` / `.octoshift.verbose.log` files. `groups.csv` is
informational only (list of subgroups found); `projects.csv` is the file you'll use for every
step below.

### 2. Map projects to GitHub

Open `projects.csv` and append three columns to every row you want to migrate:

| Column | Description |
|---|---|
| `github_org` | Target GitHub organization |
| `github_repo` | Target GitHub repository name |
| `gh_repo_visibility` | `private`, `internal`, or `public` |

Delete or leave out any rows for projects you don't want migrated — the scripts only process
what's in the CSV. All three `gl2gh_scripts/` scripts read `projects.csv` by default (override
with `-CsvPath`), and each only requires the columns it actually needs, so it's safe to keep this
as a single working file across all three steps.

### 3. Pre-migration readiness check

Checks every project in `projects.csv` for open merge requests and active (non-terminal)
pipelines — things you'll want to resolve or accept before migrating, since GEI migrates a
point-in-time snapshot.

```powershell
$env:GITLAB_PAT = 'xxxx'
$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'

./gl2gh_scripts/1_migration_readiness_check.ps1 -CsvPath projects.csv
```

This only warns — it doesn't block you from proceeding. Review the output before continuing.

### 4. Run the migration

Migrates each project in `projects.csv` from GitLab to GitHub, up to `-MaxConcurrent` (max 5) at
a time.

```powershell
$env:GH_PAT = 'xxxx'
$env:GITLAB_PAT = 'xxxx'
$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'
$env:GITHUB_TYPE = 'GitHub'          # or 'GitHubDR' (requires $env:GITHUB_API_URL too)

./gl2gh_scripts/2_migration.ps1 -CsvPath projects.csv -MaxConcurrent 3
```

Optional parameters:

- `-OutputPath <file>` — status CSV path (defaults to `repo_migration_output-<timestamp>.csv`).
  Updated live as each migration starts/finishes, with `Migration_Status`/`Log_File` columns.
- `-UseGithubStorage $true|$false` (default `$true`) — passes `--use-github-storage` to
  `migrate-repo`, uploading the GitLab export via GitHub-owned storage instead of the default path.

Each project gets its own log file: `migration-<github_repo>-<timestamp>.txt`. Watch the console
for a live status bar (`QUEUE | IN PROGRESS | MIGRATED | MIGRATION FAILED`) and streamed log
output per job.

### 5. Post-migration validation

Compares each migrated project against its GitHub counterpart: default branch, branch
count/names, and per-branch commit counts + latest commit SHA.

```powershell
$env:GITLAB_PAT = 'xxxx'
$env:GITLAB_SERVER_URL = 'https://gitlab.mycompany.com'

./gl2gh_scripts/3_post_migration_validation.ps1 -CsvPath projects.csv
```

`gh` must already be authenticated against the target GitHub host (`gh auth login` /
`gh auth status`) — this script calls `gh api` for the GitHub side. Output goes to
`validation-log-<yyyyMMdd>.txt` plus a `validation-<github_repo>.json` snapshot per project.

## Notes

- All required env vars (`GITLAB_PAT`, `GITLAB_SERVER_URL`, `GH_PAT`, `GITHUB_TYPE`, and
  `GITHUB_API_URL` when using `GitHubDR`) are validated up front — each script exits with a clear
  `[ERROR]` message telling you what to set if something's missing.
- `projects.csv`, `groups.csv`, and the various `*.octoshift*.log`, `migration-*.txt`,
  `validation-*` output files are local run artifacts and are not tracked in git.
- See `CLAUDE.md` for implementation details on how these scripts work internally.
