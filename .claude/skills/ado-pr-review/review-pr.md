# review-pr.md - per-PR review subagent

You are reviewing a single Azure DevOps pull request.
Your job: produce a diff review, then post each finding as its own resolvable PR thread.
You are invoked with two inputs in the caller's prompt:

- `prId` - the Azure DevOps pull request id
- `headSha` - the source-branch HEAD commit SHA at the time of dispatch

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
```

## Step 2 - Pull the diff

```powershell
$diff = Get-PRDiff -PullRequestId $prId -MaxBytes $cfg.review.maxDiffBytes
```

`Get-PRDiff` applies `cfg.review.skipPathGlobs` **inside git** (glob-exclude pathspecs), so generated files, lockfiles, and minified bundles never enter your context - do NOT re-read or re-filter them. The returned object also carries:

- `$diff.SkippedByGlob` - count of files dropped by the glob filter
- `$diff.Truncated` / `$diff.OmittedForSize` - whether the per-file size cap (`maxDiffBytes`) was hit and which files were omitted

If `$diff.Truncated` is true, note it in your final summary (no silent caps) so the human knows some files were not reviewed this pass.

Note on generated/serialized churn: some repos carry generated or serialized files that are NOT in `skipPathGlobs` because a change there *can* be a genuine finding (e.g. ORM migrations, i18n bundles, serialized CMS content). The glob filter intentionally leaves those in. Use judgment: review meaningful changes, but do not narrate or flag pure machine-generated noise (reordered keys, regenerated hashes). Tune `skipPathGlobs` in `config.json` for your repo's noise.

## Step 3 - Run the review with the EXACT prompt below

Pipe the (filtered) diff into a model call with this prompt verbatim. Do not paraphrase, summarize, or extend it. This prompt is the bot's source of truth and **your project's #1 customization point** - edit the stack description and the category list to fit what your team cares about. See `references/review-prompt-examples.md` for a worked example and tuning guidance.

```
You are a senior reviewer for a <DESCRIBE YOUR STACK: languages, frameworks, runtime, platform>. Report ONLY issues in these categories: (1) Bugs — incorrect logic, wrong function calls, broken type invariants (2) Security — leaked secrets, token exposure, injection/XSS (3) Runtime performance — sequential awaits that should be parallel, missing lazy-loading for heavy modules, unbounded loops over API data (4) Data integrity — silent data loss, incorrect filters, wrong entity mappings. Skip: style, naming, formatting, minor type casts that do not cause runtime errors, things that are correct, accessibility unless broken. For each issue output exactly: **[CATEGORY]** file path + line context, the problem in one sentence, the fix in one sentence or a short code block. If no issues found, say so in one line. Do not summarize the PR, do not explain what the code does, do not list things that look good.
```

You can run the review by calling the model yourself (you are Claude) on the captured diff. Treat this as a structured-output extraction task: parse the response into a list of findings.

## Step 4 - Parse findings

Expected output shape per finding (one per line block):

```
**[CATEGORY]** path/to/file.ts:LINE
problem sentence.
fix sentence or code block.
```

Parse into:

```typescript
type Finding = {
    category: "Bugs" | "Security" | "Runtime performance" | "Data integrity";
    filePath: string;        // path WITHOUT leading slash, as shown in diff
    rightLine: number;       // line in the new file; 0 if not pinpointed
    problem: string;         // first sentence after the header
    fix: string;             // remaining body (may contain a code block)
};
```

If the model output says "no issues found" - record that, post nothing, mark the PR reviewed at this SHA, return.

## Step 5 - Deduplicate against ignored signatures AND already-open threads

For each parsed finding:

```powershell
$sig = Get-IssueSignature -Category $f.category -FilePath $f.filePath -RightLine $f.rightLine -ProblemText $f.problem
if (Test-IssueIgnored -PrState $prState -Signature $sig) { continue }   # dev already told us to ignore this
```

Also do NOT post a finding that already has a live open thread from a previous pass. Build the set of currently-open finding threads once:

```powershell
$openThreads = @($prState.threads.GetEnumerator() | Where-Object {
    $_.Value.kind -eq 'finding' -and (@('open','counter-pending','deferred') -contains $_.Value.status)
} | ForEach-Object { $_.Value })
```

A finding is a duplicate of an open thread when it is the **same problem in the same file**, allowing for line drift (the dev may have edited above it). Match on category + `filePath` + the substance of the problem, not on `rightLine` alone - a shifted line is still the same finding. If a finding matches an open thread, skip posting it (the existing thread stands; do not nag with a second one). Keep the matched open threads' signatures in a `stillPresent` set - you need it in Step 5.7.

Cap the remaining (genuinely new) findings at `cfg.behavior.perPRMaxIssues`.

## Step 5.5 - Pre-verify each finding

A review prompt produces "verify this" findings as well as "this is broken" findings. Before posting, attempt to verify each finding's hypothesis YOURSELF so we only post high-signal threads. This is the single biggest lever on precision. For each surviving finding:

**1. Extract the testable hypothesis.** Look at the problem sentence and identify what claim could be checked with grep, file-read, or AST inspection. Examples:

| Finding shape | Testable hypothesis | How to check |
|---|---|---|
| "X export removed, other consumers may break" | "no other code references X" | `git grep -l 'X' $headSha -- src/` |
| "symbol/id Y referenced but not introduced" | "Y is defined somewhere on this branch" | `git grep -l 'Y' $headSha` |
| "secret may leak to client" | "this code path runs server-only" | `git show $headSha:<path>` then check for a server-only entry point / API handler |
| "sequential awaits should be parallel" | "the awaits are independent" | Read the function from the diff or `git show $headSha:<path>`, check for data dependency |
| "loop unbounded" | "loop bound comes from user input vs static config" | `git show $headSha:<path>` for surrounding code |
| "wrong filter / data loss" | "the filter matches PR-stated intent" | Diff context + `git show $headSha:<path>` for surrounding logic |
| "env var renamed / split / one is empty/stale" | "the two names actually hold the same logical value" | `git show $headSha:<path>` each consumer + any config/doc that spells the value out; compare structure |

**Env-var / config-rename findings (mandatory caveat).** Whether a variable is *set, empty, or stale in a given deployment* is **not observable from source** - the bot cannot see your CI/host env config, so never assert "setting only one leaves X empty/stale" as a Bug or Data-integrity finding. What IS verifiable at `$headSha`: whether two var names hold the *same logical value* or *structurally different* values. Before claiming a rename/split is a mistake, `git show` every consumer and any docs/type comments - if one name is a bare host and the other already bakes in an environment path segment, they may be intentionally distinct by consumer, so DROP the finding. Only if the values are genuinely identical may you keep it, and then downgrade it to a "confirm both `X` and `Y` are set in every environment" question, not a hard assertion.

If the hypothesis is not testable with available tools (needs runtime profiling, needs network call, needs human judgment), skip verification - mark the finding as `verifiable: false` and proceed to Step 6 with the original posting.

**2. Run the check. Hard rule: verify against the PR's source-branch tree at `$headSha` only. Never use the `Grep` or `Read` tools - those read the local working copy, which is unrelated to the PR under review.** `Get-PRDiff` has already fetched the source branch, so `$headSha` is in the local object store. Use `git grep` / `git show` / `git ls-tree` with `$headSha` exclusively. Limit each check to <30s.

```powershell
# Examples (PowerShell). Pattern comes BEFORE the rev for `git grep`:
$hits = & git grep -li 'someSymbol' $headSha -- "src" 2>$null      # files at $headSha containing the symbol (case-insensitive)
& git show "${headSha}:src/lib/foo.ts"                              # read a file as-of the source branch
& git ls-tree $headSha -- "src/lib/foo.ts"                         # check existence at the source branch
```

**Domain-specific verification.** If your stack has non-obvious identity formats or reference conventions (e.g. a CMS that stores IDs in two casings, an ORM whose entities are declared away from their usage), a naive grep will produce false positives or misses. Put those normalization rules in `references/verification-recipes.md` and follow them here. That file ships with one worked example (a CMS GUID-casing normalization) you can adapt or delete.

**3. Decide outcome:**

- **Hypothesis CONFIRMS the concern** (e.g., grep finds active consumers, file is client-side, awaits are independent): keep the finding, REWRITE the body to cite concrete evidence ("Verified: `<file>:<line>` references `<symbol>` and would break"), upgrade tone from "verify this" to "this will break at <evidence>."
- **Hypothesis SATISFIES the concern** (e.g., grep finds 0 active references, file is server-only, awaits have data dependency): DROP the finding. Move it to `issuesConsideredAndDropped` with `verifiedBy: "<one-line proof>"`.
- **Hypothesis is INCONCLUSIVE** (results ambiguous, tool errored, too many false matches to scan): keep the finding as-is but mark `verifiable: "inconclusive"` in the return JSON so we can tune later.

**4. Track everything:**

```
$verified = @{
    posted     = @()   # findings whose hypothesis confirmed; rewrite + post as active
    dropped    = @()   # findings whose hypothesis satisfied; do NOT post individually
    inconclusive = @() # post as-is, tone unchanged
    unverifiable = @() # not testable; post as-is
}
```

The `posted` + `inconclusive` + `unverifiable` lists are what gets posted in Step 6. The `dropped` list is recorded in state only (no comment posted) so the same signatures are not re-raised on future passes - see `issuesConsideredAndDropped` in Step 7.

## Step 5.7 - Reconcile open threads (verified-fixed)

This is the ONLY place a finding thread reaches the terminal `fixed` state. A developer saying "good catch" or "I'm fixing it" never closes a thread (the resolver leaves those active) - a thread is closed as fixed only when this re-review proves the issue is actually gone from the code at `$headSha`.

For each open thread in `$openThreads` (built in Step 5):

1. **Is the issue still present?** It is still present if this pass produced a finding matching that thread (it is in the `stillPresent` set from Step 5), OR you can still see the problem in the code at `$headSha`. If still present -> leave the thread exactly as-is (active). Do nothing.
2. **Is the issue gone?** The thread's problem is NOT in this pass's findings AND a quick confirmation at `$headSha` shows the offending code changed/removed (reuse the Step 5.5 hypothesis check - e.g. the inverted condition now reads correctly, the removed export is back, the sequential awaits are now parallel). Only when you have positively confirmed the fix:

```powershell
Add-PRThreadReply -PullRequestId $prId -ThreadId $tid -Content `
    "Verified fixed as of ``$headSha`` - the issue is no longer present. Resolving. _(Auto-verified by Claude reviewer.)_" `
    -DryRun:$dryRun
Set-PRThreadStatus -PullRequestId $prId -ThreadId $tid -Status fixed -DryRun:$dryRun
```

   Add `{ threadId = $tid; signature = <thread.issueSignature> }` to the `resolvedFixed` return list.

3. **Can't tell?** If you cannot positively confirm the fix landed (ambiguous, check errored), leave the thread active. Never close on assumption - a thread staying open one extra cycle is cheap; a real bug closed as fixed is not. Do NOT blacklist a verified-fixed signature: it no longer regenerates, and keeping it un-blacklisted means a regression on a later push would re-flag it.

## Step 6 - Post one thread per finding

Format each thread comment exactly like this so it is unmistakably from the bot AND easy to scan in the ADO UI:

```
**[CATEGORY]** `path/to/file.ts:LINE`

<problem sentence>

**Suggested fix:**
<fix sentence or code block>

---
_Posted by automated review (Claude). Reply with "ignore: <reason>" if this is intentional - I will resolve the thread and not raise this again._
```

(Edit the footer to taste - just keep the "Posted by automated review" marker string, because `resolve-replies.md` uses it to tell the bot's own comments from developer replies.)

Post via:

```powershell
$thread = New-PRThread `
    -PullRequestId $prId `
    -Content $body `
    -FilePath ("/" + $f.filePath) `
    -RightLine $f.rightLine `
    -InitialStatus active `
    -DryRun:$dryRun
```

ADO requires file paths to start with `/`. Lines must be 1-indexed.

## Step 7 - Build the return object

Return EXACTLY (as a single JSON code block in your final message to the caller):

```json
{
  "prId": 1234,
  "headSha": "abc123...",
  "issuesPosted": [
    {
      "threadId": 9876,
      "category": "Bugs",
      "filePath": "src/lib/foo.ts",
      "line": 42,
      "signature": "9f2b...c1a",
      "verifiable": "confirmed"
    }
  ],
  "issuesConsideredAndDropped": [
    {
      "category": "Bugs",
      "filePath": "src/lib/bar.ts",
      "line": 99,
      "signature": "1234...abcd",
      "verifiedBy": "grep found 0 non-deleted consumers"
    }
  ],
  "resolvedFixed": [
    {
      "threadId": 9870,
      "signature": "e2381458fa8fcb83"
    }
  ],
  "summaryThreadId": null,
  "errors": []
}
```

`resolvedFixed` lists open threads this pass verified as fixed in Step 5.7 (status set to `fixed`). Empty array if none. In dry-run mode the status change is skipped but still report which threads you WOULD have resolved.

`verifiable` per posted finding is one of `"confirmed"` (hypothesis confirmed concern, tone upgraded), `"inconclusive"` (check ran but ambiguous), `"unverifiable"` (no testable hypothesis available).

`summaryThreadId` is always `null` - the bot does not post FYI/informational summary threads. In dry-run mode, individual `threadId` values are `-1` (the wrapper returns `-1` for dry-run posts).

## Hard rules

- One finding = one thread. Never bundle multiple categories in a single thread - it makes resolve/reject impossible.
- Anchor every thread to the file and line if the finding has them. Repo-level threads (no `filePath`) are only acceptable for PR-wide observations, which this prompt does not produce.
- Use the Step 3 prompt verbatim. If you find yourself "improving" it mid-run, stop - the prompt is edited deliberately by the repo owner, not live by the bot.
- New finding threads are always created with `status=active` (the wrapper default). The ONLY status change this subagent may make is resolving a previously-open thread to `fixed` in Step 5.7, and only after positively verifying the issue is gone at `$headSha`. All other resolution (false-positive / ignore -> `byDesign`) lives in `resolve-replies.md`. Never set `fixed` on the basis of a developer comment - only on the basis of the code.
- Honor `dryRun`. If `$cfg.behavior.dryRun -eq $true`, all writes go through `-DryRun` and the return JSON still gets populated, just with `threadId: -1`.
