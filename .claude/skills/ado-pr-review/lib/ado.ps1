# Azure DevOps REST wrappers for the Claude PR review bot.
# Pure REST + PAT - no az CLI dependency at runtime (az is only a one-time setup convenience
# in the README). Every URL is built from config.azureDevOps.orgUrl, so pointing this at
# Azure DevOps Server (on-prem) is a config change (orgUrl + apiVersion), not a code change.
#
# Auth: relies on $env:AZURE_DEVOPS_EXT_PAT being set (the same env var az repos uses).
# PAT scopes required: Code (Read), Pull Request Threads (Read & Write).

$ErrorActionPreference = 'Stop'

$script:ConfigPath = Join-Path $PSScriptRoot '..\config.json'
$script:Config = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$script:Org      = $script:Config.azureDevOps.organization
$script:Project  = $script:Config.azureDevOps.project
$script:Repo     = $script:Config.azureDevOps.repository
$script:OrgUrl   = $script:Config.azureDevOps.orgUrl
$script:ApiVer   = $script:Config.azureDevOps.apiVersion

function Get-ADOConfig { $script:Config }

function Assert-Pat {
    if ([string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_EXT_PAT)) {
        throw "AZURE_DEVOPS_EXT_PAT environment variable is not set. See .claude/skills/ado-pr-review/README.md for PAT setup."
    }
}

function Get-ADOAuthHeader {
    Assert-Pat
    $pair  = ":" + $env:AZURE_DEVOPS_EXT_PAT
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    $b64   = [Convert]::ToBase64String($bytes)
    return @{
        Authorization = "Basic $b64"
        'Content-Type' = 'application/json'
        Accept = 'application/json'
    }
}

function Invoke-ADORest {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $RelativeUrl,  # e.g. _apis/git/repositories/<repo>/pullrequests
        $Body,
        [string] $ApiVersionOverride
    )
    $ver = if ($ApiVersionOverride) { $ApiVersionOverride } else { $script:ApiVer }
    $sep = if ($RelativeUrl.Contains('?')) { '&' } else { '?' }
    $projectPath = [System.Uri]::EscapeDataString($script:Project)
    $url = "$script:OrgUrl/$projectPath/$RelativeUrl${sep}api-version=$ver"
    $headers = Get-ADOAuthHeader
    $params = @{
        Method  = $Method
        Uri     = $url
        Headers = $headers
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }
    Invoke-RestMethod @params
}

function Get-RepoId {
    if ($script:RepoIdCache) { return $script:RepoIdCache }
    $result = Invoke-ADORest -Method GET -RelativeUrl "_apis/git/repositories/$([System.Uri]::EscapeDataString($script:Repo))"
    $script:RepoIdCache = $result.id
    return $script:RepoIdCache
}

function Get-ActivePRs {
    param(
        [string[]] $TargetBranches,
        [switch] $IncludeDrafts
    )
    $repoId = Get-RepoId
    # NOTE: ADO API only filters one targetRefName at a time. Fetch all active and filter client-side.
    $resp = Invoke-ADORest -Method GET -RelativeUrl "_apis/git/repositories/$repoId/pullrequests?searchCriteria.status=active"
    $prs = $resp.value
    if ($TargetBranches -and $TargetBranches.Count -gt 0) {
        $wanted = $TargetBranches | ForEach-Object { "refs/heads/$_" }
        $prs = $prs | Where-Object { $wanted -contains $_.targetRefName }
    }
    if (-not $IncludeDrafts) {
        $prs = $prs | Where-Object { -not $_.isDraft }
    }
    return $prs
}

function Get-PRDetail {
    param([Parameter(Mandatory)][int] $PullRequestId)
    $repoId = Get-RepoId
    return Invoke-ADORest -Method GET -RelativeUrl "_apis/git/repositories/$repoId/pullrequests/$PullRequestId"
}

function Get-PRDiff {
    # Computes the unified diff between PR source and target heads using local git.
    # Requires the repo at $PWD to be the same repo and to have fetched the source branch.
    #
    # Token optimization: skipPathGlobs from config.review are excluded HERE, in git,
    # via glob-exclude pathspec args - so generated/serialized/lockfile churn never enters
    # model context. (Previously the full diff was handed to the model, which filtered it
    # mentally after already paying to read it.) MaxBytes truncation is now per-file:
    # whole files are kept until the budget is hit, then remaining files are omitted by
    # name rather than the diff being chopped mid-hunk alphabetically.
    param(
        [Parameter(Mandatory)][int] $PullRequestId,
        [int] $MaxBytes
    )
    $pr = Get-PRDetail -PullRequestId $PullRequestId
    $sourceBranch = $pr.sourceRefName -replace '^refs/heads/', ''
    $targetBranch = $pr.targetRefName -replace '^refs/heads/', ''
    $sourceSha    = $pr.lastMergeSourceCommit.commitId
    $targetSha    = $pr.lastMergeTargetCommit.commitId

    # Fetch both refs so we have them locally.
    # NOTE: git writes normal progress ("From <remote>", "Already up to date") to stderr.
    # In Windows PowerShell 5.1, native-command stderr is intercepted and converted to
    # ErrorRecord objects BEFORE PowerShell-level redirection (2>$null) can apply, so
    # $ErrorActionPreference=Stop still promotes harmless git chatter to terminating errors.
    # Push the redirect down to cmd.exe so it happens at the OS level.
    $null = cmd /c "git fetch origin $sourceBranch 2>nul 1>nul"
    if ($LASTEXITCODE -ne 0) { Write-Warning "git fetch origin $sourceBranch exit $LASTEXITCODE - continuing with local state" }
    $null = cmd /c "git fetch origin $targetBranch 2>nul 1>nul"
    if ($LASTEXITCODE -ne 0) { Write-Warning "git fetch origin $targetBranch exit $LASTEXITCODE - continuing with local state" }

    # Build exclude pathspecs from config. git diff does NOT support --pathspec-from-file,
    # so we pass them as args via the call operator (& git @args), which hands each element
    # to git verbatim - the ':(glob,exclude)' magic (parens, colons, '*') survives without
    # the cmd.exe quoting hell. Each config glob is excluded both anchored at repo root AND
    # anywhere in the tree ('**/' prefix), because globs like 'src/.generated/**' are written
    # relative to a sub-package (e.g. apps/web/) rather than the repo root.
    # ':(glob,exclude)' makes '**' span directory separators.
    $skipGlobs = @($script:Config.review.skipPathGlobs)
    $excludeSpecs = New-Object System.Collections.Generic.List[string]
    foreach ($g in $skipGlobs) {
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        $excludeSpecs.Add(":(glob,exclude)$g")
        # Also exclude the glob anywhere in the tree, UNLESS it already starts with '**/'.
        # (Must be StartsWith, not -like '**/*' - the latter is a wildcard match that is true
        # for any glob containing a slash, so sub-package-relative globs like 'src/generated/**'
        # would wrongly skip the '**/' variant and never match apps/web/src/generated/.)
        if (-not $g.StartsWith('**/')) { $excludeSpecs.Add(":(glob,exclude)**/$g") }
    }
    # pathspec arg list: '--' separator, positive '.', then the excludes.
    $pathspecArgs = @()
    if ($excludeSpecs.Count -gt 0) { $pathspecArgs = @('--', '.') + $excludeSpecs }

    # Native-command stderr becomes terminating ErrorRecords under EAP=Stop in PS 5.1, so
    # drop to Continue around git invocations and gate real failures on $LASTEXITCODE.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $diff = & git diff --no-color "$targetSha...$sourceSha" @pathspecArgs 2>$null
        if ($LASTEXITCODE -ne 0) { throw "git diff $targetSha...$sourceSha failed (exit $LASTEXITCODE). Are both commits fetched locally?" }
        $diffText = (@($diff) -join "`n")

        # Count files dropped by the glob filter (for transparency in logs - no silent caps).
        $allFiles  = @(& git diff --name-only "$targetSha...$sourceSha" 2>$null)
        $keptFiles = @(& git diff --name-only "$targetSha...$sourceSha" @pathspecArgs 2>$null)
        $skippedByGlob = [Math]::Max(0, $allFiles.Count - $keptFiles.Count)
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }

    # Per-file truncation: keep whole file sections until MaxBytes, then omit the rest by name.
    $omittedForSize = @()
    if ($MaxBytes -and $diffText.Length -gt $MaxBytes) {
        $sections = [regex]::Split($diffText, '(?m)(?=^diff --git )') | Where-Object { $_ -ne '' }
        $kept = New-Object System.Collections.Generic.List[string]
        $running = 0
        $over = $false
        foreach ($s in $sections) {
            if (-not $over -and ($running + $s.Length) -le $MaxBytes) {
                $kept.Add($s); $running += $s.Length
            } else {
                $over = $true
                $m = [regex]::Match($s, '(?m)^diff --git a/(.+?) b/')
                $omittedForSize += if ($m.Success) { $m.Groups[1].Value } else { '<unknown>' }
            }
        }
        $diffText = ($kept -join "")
        if ($omittedForSize.Count -gt 0) {
            # Show a bounded sample of omitted names, not all of them - listing hundreds of
            # paths would itself bloat model context and defeat the size cap.
            $sample = $omittedForSize | Select-Object -First 15
            $more   = $omittedForSize.Count - $sample.Count
            $names  = ($sample -join ', ') + $(if ($more -gt 0) { " (+$more more)" } else { '' })
            $diffText += "`n`n[...diff size cap ($MaxBytes bytes) reached; $($omittedForSize.Count) file(s) omitted: $names...]"
        }
    }

    return [PSCustomObject]@{
        PullRequestId  = $PullRequestId
        SourceBranch   = $sourceBranch
        TargetBranch   = $targetBranch
        SourceSha      = $sourceSha
        TargetSha      = $targetSha
        Diff           = $diffText
        SkippedByGlob  = $skippedByGlob
        OmittedForSize = $omittedForSize
        Truncated      = ($omittedForSize.Count -gt 0)
    }
}

function Get-PRThreads {
    param([Parameter(Mandatory)][int] $PullRequestId)
    $repoId = Get-RepoId
    $resp = Invoke-ADORest -Method GET -RelativeUrl "_apis/git/repositories/$repoId/pullrequests/$PullRequestId/threads"
    return $resp.value
}

function New-PRThread {
    # Creates a new thread on a PR. If FilePath is supplied, anchors to that file/line.
    # InitialStatus controls the thread state on creation (default 'active').
    # Use 'closed' for informational/pre-resolved threads so they do not block merge under
    # "all comments resolved" branch policy.
    param(
        [Parameter(Mandatory)][int] $PullRequestId,
        [Parameter(Mandatory)][string] $Content,
        [string] $FilePath,
        [int] $RightLine,
        [ValidateSet('active','fixed','wontFix','closed','byDesign','pending')] [string] $InitialStatus = 'active',
        [switch] $DryRun
    )
    $statusMap = @{ active=1; fixed=2; wontFix=3; closed=4; byDesign=5; pending=6 }
    $body = @{
        comments = @(@{ parentCommentId = 0; content = $Content; commentType = 1 })
        status   = $statusMap[$InitialStatus]
    }
    if ($FilePath) {
        $ctx = @{ filePath = $FilePath }
        if ($RightLine -gt 0) {
            $ctx.rightFileStart = @{ line = $RightLine; offset = 1 }
            $ctx.rightFileEnd   = @{ line = $RightLine; offset = 1 }
        }
        $body.threadContext = $ctx
    }
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create thread on PR $PullRequestId at ${FilePath}:${RightLine} (status=$InitialStatus)"
        Write-Host "[DRY-RUN] Content:"
        Write-Host $Content
        return [PSCustomObject]@{ id = -1; dryRun = $true }
    }
    $repoId = Get-RepoId
    return Invoke-ADORest -Method POST -RelativeUrl "_apis/git/repositories/$repoId/pullrequests/$PullRequestId/threads" -Body $body
}

function Add-PRThreadReply {
    param(
        [Parameter(Mandatory)][int] $PullRequestId,
        [Parameter(Mandatory)][int] $ThreadId,
        [Parameter(Mandatory)][string] $Content,
        [switch] $DryRun
    )
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would reply to thread $ThreadId on PR ${PullRequestId}: $Content"
        return $null
    }
    $repoId = Get-RepoId
    $body = @{ parentCommentId = 1; content = $Content; commentType = 1 }
    return Invoke-ADORest -Method POST -RelativeUrl "_apis/git/repositories/$repoId/pullrequests/$PullRequestId/threads/$ThreadId/comments" -Body $body
}

function Set-PRThreadStatus {
    # status: 1=active, 2=fixed, 3=wontFix, 4=closed, 5=byDesign, 6=pending
    param(
        [Parameter(Mandatory)][int] $PullRequestId,
        [Parameter(Mandatory)][int] $ThreadId,
        [Parameter(Mandatory)][ValidateSet('active','fixed','wontFix','closed','byDesign','pending')] [string] $Status,
        [switch] $DryRun
    )
    $map = @{ active=1; fixed=2; wontFix=3; closed=4; byDesign=5; pending=6 }
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would set thread $ThreadId on PR $PullRequestId to status=$Status"
        return $null
    }
    $repoId = Get-RepoId
    $body = @{ status = $map[$Status] }
    return Invoke-ADORest -Method PATCH -RelativeUrl "_apis/git/repositories/$repoId/pullrequests/$PullRequestId/threads/$ThreadId" -Body $body
}

function Test-ADOConnectivity {
    # Smoke test - call without writing anything.
    try {
        $repoId = Get-RepoId
        $count = (Get-ActivePRs -TargetBranches $script:Config.polling.targetBranches | Measure-Object).Count
        return [PSCustomObject]@{ ok = $true; repoId = $repoId; activePRs = $count }
    } catch {
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}
