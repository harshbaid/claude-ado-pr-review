# Atomic state read/write for the PR review bot.
# Compatible with Windows PowerShell 5.1 (no ConvertFrom-Json -AsHashtable).
#
# State schema:
# {
#   "<prId>": {
#     "lastReviewedSha": "<sha>",
#     "lastReviewedAt":  "<iso8601>",
#     "threads": {
#       "<threadId>": {
#         "status":  "open" | "resolved" | "counter-pending",
#         "category": "Bugs" | "Security" | "Runtime" | "Data integrity",
#         "filePath": "...",
#         "rightLine": 123,
#         "issueSignature": "<sha256 of normalized issue text>",
#         "ignoredReason": null | "<text from dev that justified ignore>",
#         "counterRounds": 0
#       }
#     },
#     "ignoredIssueSignatures": ["<sig>", ...]
#   }
# }

$ErrorActionPreference = 'Stop'

$script:StatePath = Join-Path $PSScriptRoot '..\state.json'

function ConvertTo-PRBotHashtable {
    param([Parameter(ValueFromPipeline)] $InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $list = @(foreach ($item in $InputObject) { ConvertTo-PRBotHashtable -InputObject $item })
            ,$list
        } elseif ($InputObject -is [PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) {
                $h[$p.Name] = ConvertTo-PRBotHashtable -InputObject $p.Value
            }
            $h
        } else {
            $InputObject
        }
    }
}

function Get-PRBotState {
    if (-not (Test-Path $script:StatePath)) { return @{} }
    $raw = Get-Content $script:StatePath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    $obj = $raw | ConvertFrom-Json
    return (ConvertTo-PRBotHashtable -InputObject $obj)
}

function Save-PRBotState {
    param([Parameter(Mandatory)] [hashtable] $State)
    $tmp = "$script:StatePath.tmp"
    ($State | ConvertTo-Json -Depth 30) | Out-File -FilePath $tmp -Encoding utf8 -NoNewline
    Move-Item -Path $tmp -Destination $script:StatePath -Force
}

function Get-OrInit-PRState {
    param(
        [Parameter(Mandatory)] [hashtable] $State,
        [Parameter(Mandatory)] [string] $PrId
    )
    if (-not $State.ContainsKey($PrId)) {
        $State[$PrId] = @{
            lastReviewedSha         = $null
            lastReviewedAt          = $null
            threads                 = @{}
            ignoredIssueSignatures  = @()
        }
    }
    return $State[$PrId]
}

function Get-IssueSignature {
    # Normalize an issue (category + file + line + first 120 chars of problem text)
    # so we can recognize "the same issue" across re-reviews.
    param(
        [Parameter(Mandatory)][string] $Category,
        [string] $FilePath,
        [int]    $RightLine,
        [Parameter(Mandatory)][string] $ProblemText
    )
    $normalized = ($ProblemText -replace '\s+', ' ').Trim().ToLowerInvariant()
    if ($normalized.Length -gt 120) { $normalized = $normalized.Substring(0, 120) }
    $key = "$Category|$FilePath|$RightLine|$normalized"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
        $hash  = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hash) -replace '-','').Substring(0, 16).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Test-IssueIgnored {
    param(
        [Parameter(Mandatory)] [hashtable] $PrState,
        [Parameter(Mandatory)] [string] $Signature
    )
    if ($null -eq $PrState.ignoredIssueSignatures) { return $false }
    return ($PrState.ignoredIssueSignatures -contains $Signature)
}
