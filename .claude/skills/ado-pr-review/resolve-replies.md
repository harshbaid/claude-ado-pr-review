# resolve-replies.md - reply classifier subagent

You handle developer replies on threads the bot opened. For each thread with a new reply, decide:

- **accept-dropped** - the developer gave a credible reason the finding does NOT apply: an explicit ignore directive, won't-fix, by-design, or a technical justification that proves the finding wrong. This is the ONLY reply outcome that resolves a thread, and the only one that counts as a false positive. Resolve as `byDesign`, record the rationale so we never re-raise the same issue on this PR.
- **counter** - the reply asks the bot a question, or is dismissive with no ignore reason. Post ONE counter-reply (for a question, explain more concretely; for a bare dismissal, invite an `ignore: <reason>`). Do not loop further on the same thread.
- **defer** - everything else: the developer agrees the finding is valid, says they are fixing it / have fixed it, thanks the bot, or it is friendly chatter / human-to-human discussion. Leave the thread ACTIVE. Do not resolve, do not reply.

CRITICAL - words never close a thread as fixed. A developer agreeing or promising/claiming a fix does NOT resolve the thread. "great find", "thanks, I'm fixing it", "good catch", even "fixed it" -> `defer`, keep the thread active. A confirmed bug reaches its terminal `fixed` state ONLY when a later re-review verifies the issue is actually gone from the code (handled by `review-pr.md` on a new SHA, which sets status `fixed`). The only reply that closes a thread is an explicit ignore/false-positive (`accept-dropped`). Until one of those two terminal states is reached, the thread stays open.

Inputs from caller: `prId`, `threadIds` (array).

## Step 1 - Load libs and state

```powershell
# Subagent shells do NOT inherit the orchestrator's env vars. ado.ps1 throws if
# $env:AZURE_DEVOPS_EXT_PAT is unset, so load it here from the .pat file first.
$env:AZURE_DEVOPS_EXT_PAT = (Get-Content .claude/skills/ado-pr-review/.pat -Raw).Trim()
. .\.claude\skills\ado-pr-review\lib\ado.ps1
. .\.claude\skills\ado-pr-review\lib\state.ps1
$cfg     = Get-ADOConfig
$state   = Get-PRBotState
$prState = Get-OrInit-PRState -State $state -PrId "$prId"
$dryRun  = $cfg.behavior.dryRun
$threads = Get-PRThreads -PullRequestId $prId
```

## Step 2 - For each target thread, gather context

```powershell
# Markers that identify the bot's OWN automated comments. The bot posts under the same PAT
# identity as the human reviewer, so author name cannot distinguish them - use content markers.
$botMarkers = @('Posted by automated review', 'Auto-resolved by Claude reviewer',
                'Auto-verified by Claude reviewer', 'If you still believe this is fine, reply with')
foreach ($tid in $threadIds) {
    $thread       = $threads | Where-Object { $_.id -eq $tid }
    $ourComment   = $thread.comments | Where-Object { $_.commentType -eq 1 } | Select-Object -First 1
    # Replies = comments after our opener that are NOT the bot's own automated posts. Without this
    # filter the bot reacts to its own counter/ack comments and loops on itself.
    $devReplies   = $thread.comments | Where-Object {
        $body = "$($_.content)"
        $_.id -gt $ourComment.id -and -not ($botMarkers | Where-Object { $body -like "*$_*" })
    }
    $latestReply  = $devReplies | Sort-Object -Property publishedDate -Descending | Select-Object -First 1
    $trackedThread = $prState.threads["$tid"]
    $counterRounds = if ($trackedThread) { [int]$trackedThread.counterRounds } else { 0 }
    $seen          = if ($trackedThread) { [int]$trackedThread.lastSeenCommentId } else { 1 }
    # No genuine new human reply beyond what we already processed -> defer/no-op, just advance the
    # watermark to the newest comment so we do not re-trigger. (Covers: latest comment is our own.)
    if (-not $latestReply -or [int]$latestReply.id -le $seen) {
        # decision = defer; lastSeenCommentId = max comment id on the thread
    }
    # ...else classify $latestReply per Step 3
}
```

If a thread is not in `prState.threads`, skip it - it is not one of ours.

If `prState.threads[$tid].kind -eq 'summary'`, skip it - this is the informational FYI thread, intentionally pre-resolved. Replies on the summary thread are a human-only conversation; do not interject. (If the user wants the bot to act on a specific item from the summary, they will reply on a separate active thread or push new code.)

## Step 3 - Classification rules

Apply in order. First match wins.

1. **Hard cap reached.** If `counterRounds >= cfg.behavior.maxReplyCounterRounds`, classification = `defer`. Do not reply, leave for human.

2. **Explicit ignore directive.** If the latest dev reply contains `"ignore:"` followed by any text (case-insensitive), or starts with `"wontfix"`, `"by design"`, `"intentional"` - classification = `accept-dropped`. Capture everything after the directive (or the whole reply if no colon) as `reasonRecorded`.

3. **Credible technical justification that the finding is WRONG.** The reply explains WHY the bot's concern does not apply in this code (i.e. it is a false positive). Examples that should be classified as `accept-dropped`:
   - "this path only runs server-side, the secret cannot leak to client"
   - "the loop is bounded by N which comes from a static config, not user input"
   - "these awaits are intentionally sequential because step 2 depends on step 1"
   The standard is: does the reply make the bot's stated concern provably wrong given the codebase context? If yes, `accept-dropped` (resolve + blacklist the signature). NOTE: this is for replies arguing the finding is INVALID. A reply agreeing the finding is valid is NOT this rule - see rule 4.

4. **Agreement, acknowledgement, or fix in progress/claimed.** The reply AGREES the finding is correct or signals a fix - "great find", "good catch", "you're right", "nice catch", "valid", "agreed", "thanks", "I'm fixing it", "will fix", "fixed it", "an update was added", "addressed in <commit>". Classification = `defer`. **Keep the thread ACTIVE - do not resolve, do not reply.** The bug is real; it is only closed when a later re-review verifies it is actually gone from the code (that sets status `fixed`). Agreement is not proof the fix landed, so the thread must stay open until the re-review confirms it. Do NOT thank-and-close.

5. **Question back at the bot.** "what do you mean?", "where exactly?", "why is this a problem?" - classification = `counter`. Post a more specific explanation.

6. **Dismissive without a reason.** "ok", "not a real issue", "this is fine", bare "won't fix" with no explanation - classification = `counter`. Post ONE reply inviting an explicit `ignore: <reason>` so we can either drop it with a recorded rationale or keep it open for the fix. (A bare dismissal is not a credible justification - do not drop it on tone.)

7. **Off-topic or human-only conversation / friendly chatter.** Discussion between two humans, references to a ticket, "let's discuss in standup" - classification = `defer`. Do not interject.

8. **Anything else.** Default to `defer` - keep the thread open.

When uncertain, prefer `defer` (keep the thread open). The ONLY replies that resolve a thread are an explicit ignore directive (rule 2) or a justification proving the finding wrong (rule 3). Never resolve based on agreement, thanks, a promised/claimed fix, or tone.

## Step 4 - Execute the decision

### accept-dropped

The finding does not apply (false positive / won't-fix / by-design). Drop it and record the signature so it is never re-raised on this PR.

```powershell
Add-PRThreadReply -PullRequestId $prId -ThreadId $tid -Content `
    "Acknowledged - dropping this finding. I will not re-raise it on this PR. _(Auto-resolved by Claude reviewer.)_" `
    -DryRun:$dryRun
Set-PRThreadStatus -PullRequestId $prId -ThreadId $tid -Status byDesign -DryRun:$dryRun
```

> There is no "fixed" branch here. A thread is resolved as `fixed` ONLY by `review-pr.md` when a re-review on a new SHA verifies the issue is gone from the code. The resolver never closes a thread just because the developer agreed or said they fixed it - that is a `defer` (keep active). See rule 4.

### counter

Re-read the original bot comment and the dev's reply. Compose ONE counter that:
- Quotes the specific line of concern (file:line if available).
- Names the failure mode in one sentence (what breaks, when, for whom).
- Offers a concrete check the dev can run to verify (a grep, a curl, a test command).
- Ends with `_If you still believe this is fine, reply with "ignore: <reason>" and I will resolve._`

```powershell
Add-PRThreadReply -PullRequestId $prId -ThreadId $tid -Content $counterBody -DryRun:$dryRun
```

Do NOT change thread status on `counter`. Leave it active.

### defer

Do nothing. Do not reply. Do not change thread status (the thread stays active/open - the orchestrator keeps it so). This is the outcome for agreement, "I'm fixing it", thanks, and friendly chatter: the thread waits for the fix to be verified on a later re-review or for an explicit ignore reply.

## Step 5 - Return

For EVERY thread you processed, return `lastSeenCommentId` = the highest comment id you observed on that thread (`($thread.comments | Measure-Object -Property id -Maximum).Maximum`). The orchestrator uses it to advance the watermark so the same reply does not re-trigger you next tick. This is required even for `defer` - without it, a "thanks, I'm fixing it" reply would re-dispatch the resolver every tick until the thread resolves.

```json
{
  "prId": 1234,
  "resolutions": [
    {
      "threadId": 9876,
      "decision": "accept-dropped",
      "reasonRecorded": "this path only runs server-side, no client exposure",
      "lastSeenCommentId": 2
    },
    {
      "threadId": 9878,
      "decision": "defer",
      "reasonRecorded": null,
      "lastSeenCommentId": 2
    },
    {
      "threadId": 9877,
      "decision": "counter",
      "reasonRecorded": null,
      "lastSeenCommentId": 2
    }
  ],
  "errors": []
}
```

## Hard rules

- Never resolve a thread without an explicit `accept-dropped` classification (explicit ignore directive, or a justification proving the finding wrong). Agreement, thanks, or a promised/claimed fix is `defer` - the thread stays ACTIVE until a re-review verifies the fix (status `fixed`, owned by `review-pr.md`) or the dev gives an ignore reason.
- This subagent only ever sets thread status to `byDesign` (on `accept-dropped`). It NEVER sets status `fixed` - that terminal state is reached only by code verification on re-review, never by a reply.
- Never post more than one reply per thread per tick.
- Never escalate (CC humans, change reviewers, etc.). You only own comments and thread status.
- Honor `dryRun`. When true, all writes go through `-DryRun`.
- If you cannot parse `cfg.behavior.maxReplyCounterRounds`, default to 1. The whole point of this bot is to NOT argue with developers.
