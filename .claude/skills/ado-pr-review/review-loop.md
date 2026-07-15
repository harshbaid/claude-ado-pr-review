# PR review bot - per-tick instructions

You are the orchestrator for an automated Azure DevOps PR review bot.
You run once per `/loop` tick (or once per `/pr-review` invocation). Do exactly what this file
says and return.

## Context (do not re-derive)

- **Repo/org/project:** read from `.claude/skills/ado-pr-review/config.json` (`azureDevOps.*`).
- **Auth:** PAT is in `$env:AZURE_DEVOPS_EXT_PAT`. If unset, stop and tell the user.
- **Config:** `.claude/skills/ado-pr-review/config.json`
- **State:** `.claude/skills/ado-pr-review/state.json`
- **Libs:** `.claude/skills/ado-pr-review/lib/ado.ps1`, `.claude/skills/ado-pr-review/lib/state.ps1`
- **Dry-run:** controlled by `behavior.dryRun` in config. While `true`, NO writes to Azure DevOps. Print what would happen and update state only.

## Per-tick algorithm

Run each step. Stop early if something errors and log it.

### 1-4. Preflight: compute the tick plan (cheap, no model reasoning)

Lane assignment is pure data - connectivity check, SHA compares, and a thread-reply scan -
so it runs entirely in PowerShell. This keeps an idle tick (everything in Lane C) at ~zero
model tokens: you read one JSON line and, if there is no work, stop.

```powershell
. .\.claude\skills\ado-pr-review\lib\ado.ps1
. .\.claude\skills\ado-pr-review\lib\state.ps1
. .\.claude\skills\ado-pr-review\lib\preflight.ps1
Get-TickPlanJson
```

`Get-TickPlanJson` returns one compact JSON line:

```json
{"ok":true,"error":null,"dryRun":false,"scanned":2,"laneA":[{"id":3667,"sha":"543d...","title":"..."}],"laneB":[{"id":3611,"threadIds":[15562]}],"laneC":[3622]}
```

- If `ok` is `false`: print `ADO unreachable: <error>`, append an error log line (step 7), and stop.
- **If `laneA` and `laneB` are both empty, you are done.** Skip steps 5-6 entirely, append the log line (step 7), print the summary (step 8), and return. Do NOT read diffs, dispatch subagents, or reason further - an idle tick must stay nearly free.
- Otherwise: cap `laneA` to `cfg.behavior.perTickMaxPRsReviewed` entries (process lowest PR id first so nothing starves) and proceed to steps 5/6 using the plan's `laneA[].{id,sha}` and `laneB[].{id,threadIds}`.

Lane definitions (already applied by the preflight, for reference):

- **Lane A - NEW or CHANGED:** `state[prId].lastReviewedSha` is missing or differs from the PR's current source SHA. Dispatch the review subagent (step 5).
- **Lane B - REPLIES TO HANDLE:** an open/counter-pending finding thread we authored has a comment newer than `state[prId].threads[<id>].lastSeenCommentId` (and beyond our opening comment id 1). Dispatch the resolver subagent (step 6).
- **Lane C - NOTHING TO DO:** SHA unchanged AND no new replies. Skipped.

No top-level `git fetch` is needed. `Get-PRDiff` (called per PR in Lane A) already fetches `sourceBranch` and `targetBranch` from `origin`, which is the only freshness `review-pr.md` Step 5.5 depends on - it verifies against `$headSha`, not the working tree.

### 5. Lane A - dispatch the review subagent

For a PR in Lane A, use the Agent tool with `subagent_type: "general-purpose"` and pass this prompt:

> Read `.claude/skills/ado-pr-review/review-pr.md` and execute it for PR `<id>`. The PR head SHA is `<sha>`. After posting (or dry-run-printing) findings AND reconciling existing open threads against this SHA, return a JSON object `{ prId, headSha, issuesPosted: [{threadId, category, filePath, line, signature}], resolvedFixed: [{threadId, signature}], errors: [] }`.

When the subagent returns, merge results into state. The PR id and source SHA come from the Lane A plan entry (`$entry.id` / `$entry.sha` below = the preflight's `laneA[].id` / `laneA[].sha`):

```powershell
$prState = Get-OrInit-PRState -State $state -PrId "$($entry.id)"
$prState.lastReviewedSha = $entry.sha
$prState.lastReviewedAt  = (Get-Date).ToString("o")

# Active findings posted as their own threads.
foreach ($issue in $result.issuesPosted) {
    $prState.threads["$($issue.threadId)"] = @{
        status         = "open"
        kind           = "finding"
        category       = $issue.category
        filePath       = $issue.filePath
        rightLine      = $issue.line
        issueSignature = $issue.signature
        verifiable     = $issue.verifiable
        ignoredReason  = $null
        counterRounds  = 0
        lastSeenCommentId = 1
    }
}

# FYI summary thread (posted at status=closed). Record so resolver knows to skip it.
if ($result.summaryThreadId -and $result.summaryThreadId -ne -1) {
    $prState.threads["$($result.summaryThreadId)"] = @{
        status            = "informational"
        kind              = "summary"
        lastSeenCommentId = 1
    }
}

# Findings considered but dropped get their signatures recorded so we never re-raise
# them on this PR (even if a future re-review produces the same hypothesis).
if (-not $prState.ignoredIssueSignatures) { $prState.ignoredIssueSignatures = @() }
foreach ($dropped in $result.issuesConsideredAndDropped) {
    if ($dropped.signature -and -not ($prState.ignoredIssueSignatures -contains $dropped.signature)) {
        $prState.ignoredIssueSignatures += $dropped.signature
    }
}

# Verified-fixed reconciliation: open threads whose underlying issue is GONE from the code at
# this SHA. review-pr.md set their ADO status to `fixed`; record them as confirmed true positives.
# This is the ONLY path to the terminal `fixed` state - a real bug the dev actually fixed. Do NOT
# blacklist these signatures (no need - the issue no longer regenerates), and do NOT count them as
# false positives.
foreach ($fixed in $result.resolvedFixed) {
    $t = $prState.threads["$($fixed.threadId)"]
    if ($t) {
        $t.status = "resolved-fixed"
        $t.confirmedTruePositive = $true
    }
}

Save-PRBotState -State $state
```

### 6. Lane B - dispatch the resolver subagent

For each PR with new replies, use the Agent tool with `subagent_type: "general-purpose"` and pass:

> Read `.claude/skills/ado-pr-review/resolve-replies.md` and execute it for PR `<id>`. Threads with new activity: `<threadId list>`. Return a JSON object `{ prId, resolutions: [{threadId, decision: "accept-dropped" | "counter" | "defer", reasonRecorded, lastSeenCommentId}], errors: [] }`.

Merge:

```powershell
$maxRounds = [int]$cfg.behavior.maxReplyCounterRounds
foreach ($r in $result.resolutions) {
    $t = $prState.threads["$($r.threadId)"]
    if (-not $t) { continue }
    switch ($r.decision) {
        # False positive / won't-fix / by-design: the ONLY reply-driven resolution. Resolve AND
        # permanently suppress the signature so the same finding is never re-raised on this PR.
        { $_ -in 'accept-dropped','accept' } {   # bare 'accept' kept for backward-compat == dropped
            $t.status        = "resolved"
            $t.ignoredReason = $r.reasonRecorded
            $t.confirmedTruePositive = $false
            if (-not $prState.ignoredIssueSignatures) { $prState.ignoredIssueSignatures = @() }
            if ($t.issueSignature -and -not ($prState.ignoredIssueSignatures -contains $t.issueSignature)) {
                $prState.ignoredIssueSignatures += $t.issueSignature
            }
        }
        "counter" { $t.status = "counter-pending"; $t.counterRounds = ([int]$t.counterRounds + 1) }
        # Agreement / "I'm fixing it" / thanks / chatter. Keep the thread ACTIVE ('open') so future
        # replies are still handled AND it stays eligible for verified-fixed reconciliation on the
        # next re-review. Park as 'deferred' (hand to human, stop re-triggering) ONLY once the
        # counter cap has been hit - that is the bot's "stop arguing" terminal state, not agreement.
        "defer"   {
            if ([int]$t.counterRounds -ge $maxRounds -and [int]$t.counterRounds -gt 0) {
                $t.status = "deferred"
            } else {
                $t.status = "open"
            }
        }
    }
    # Advance the watermark to the reply we just processed so the SAME comment does not
    # re-trigger the resolver every tick. The resolver returns the max comment id it observed.
    if ($r.lastSeenCommentId) { $t.lastSeenCommentId = [int]$r.lastSeenCommentId }
}
Save-PRBotState -State $state
```

### 7. Append a log line

`.claude/skills/ado-pr-review/logs/YYYY-MM-DD.log` - one JSON object per line:

```json
{"ts":"2026-05-26T08:00:00-05:00","tick":1,"dryRun":true,"prsScanned":4,"laneA":1,"laneB":2,"laneC":1,"errors":[]}
```

### 8. Return concisely

Print one line summarizing the tick. Example:
`Tick @ 2026-05-26T08:00:00 - scanned 4 PRs, reviewed 1, handled 2 replies, 0 errors (DRY-RUN)`

Do not print diffs or full subagent transcripts to the user during a tick. Keep noise low.

## Hard rules

- **Never** post real comments while `dryRun=true`. Use the `-DryRun` switch on `New-PRThread`, `Add-PRThreadReply`, `Set-PRThreadStatus`.
- **Never** re-raise an issue whose signature is in `prState.ignoredIssueSignatures`. The signature check happens inside `review-pr.md`.
- **Never** loop more than `behavior.maxReplyCounterRounds` rounds on the same thread. After that, set status to `deferred` and leave it for the human.
- **Stop the loop** if connectivity, auth, or state file corruption errors occur on the same PR twice in a row. Tell the user.
