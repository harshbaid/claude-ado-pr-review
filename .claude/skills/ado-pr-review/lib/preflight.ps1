# Preflight lane planner for the PR review bot.
#
# Token optimization (#3): an idle tick should cost ~zero model tokens. This computes
# which active PRs fall into Lane A / B / C using pure data (SHA compare + thread reply
# scan), so the orchestrator model only has to engage a subagent when laneA/laneB are
# non-empty. On an all-Lane-C tick the orchestrator just prints the summary line.
#
# Requires ado.ps1 + state.ps1 to be dot-sourced in the same session.

$ErrorActionPreference = 'Stop'

function Get-TickPlan {
    [CmdletBinding()] param()
    $plan = [ordered]@{
        ok      = $true
        error   = $null
        dryRun  = $false
        scanned = 0
        laneA   = @()   # new/changed source SHA -> dispatch review-pr.md
        laneB   = @()   # new dev replies on our finding threads -> dispatch resolve-replies.md
        laneC   = @()   # nothing to do
    }

    $cfg   = Get-ADOConfig
    $state = Get-PRBotState
    $plan.dryRun = [bool]$cfg.behavior.dryRun

    $probe = Test-ADOConnectivity
    if (-not $probe.ok) { $plan.ok = $false; $plan.error = "ADO unreachable: $($probe.error)"; return $plan }

    $prs = @(Get-ActivePRs -TargetBranches $cfg.polling.targetBranches)
    $plan.scanned = $prs.Count

    foreach ($pr in $prs) {
        $idKey  = "$($pr.pullRequestId)"
        $curSha = $pr.lastMergeSourceCommit.commitId

        $prState = $null
        if ($state.ContainsKey($idKey)) { $prState = $state[$idKey] }

        # Lane A: never reviewed, or source SHA moved since the last review.
        if (-not $prState -or $prState.lastReviewedSha -ne $curSha) {
            $plan.laneA += [ordered]@{ id = [int]$pr.pullRequestId; sha = $curSha; title = $pr.title }
            continue
        }

        # SHA unchanged -> Lane B only if a tracked, still-actionable finding thread has a
        # reply we have not processed. Summary/resolved/deferred threads do not re-trigger.
        $newReplyThreads = @()
        if ($prState.threads -and $prState.threads.Keys.Count -gt 0) {
            $actionable = @($prState.threads.Keys | Where-Object {
                $t = $prState.threads[$_]
                $t.kind -eq 'finding' -and (@('open', 'counter-pending') -contains $t.status)
            })
            if ($actionable.Count -gt 0) {
                $live = @(Get-PRThreads -PullRequestId $pr.pullRequestId)
                foreach ($tid in $actionable) {
                    $lt = $live | Where-Object { "$($_.id)" -eq $tid } | Select-Object -First 1
                    if (-not $lt) { continue }
                    $maxId = ($lt.comments | Measure-Object -Property id -Maximum).Maximum
                    $seen  = [int]$prState.threads[$tid].lastSeenCommentId
                    # Our opening comment is id 1; a comment beyond it AND beyond what we last
                    # processed is an unhandled dev reply.
                    if ($maxId -gt $seen -and $maxId -gt 1) { $newReplyThreads += [int]$tid }
                }
            }
        }

        if ($newReplyThreads.Count -gt 0) {
            $plan.laneB += [ordered]@{ id = [int]$pr.pullRequestId; threadIds = @($newReplyThreads) }
        } else {
            $plan.laneC += [int]$pr.pullRequestId
        }
    }

    return $plan
}

function Get-TickPlanJson {
    # Compact single-line JSON so the orchestrator reads the whole plan cheaply.
    Get-TickPlan | ConvertTo-Json -Depth 6 -Compress
}
