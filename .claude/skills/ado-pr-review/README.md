# Azure DevOps PR review bot - setup & operation

Automates a senior code review on Azure DevOps PRs, downstream of PR creation:

1. Polls Azure DevOps every N minutes for active PRs on configured target branches.
2. When a PR is new or has new commits, runs your review prompt over the diff.
3. Pre-verifies each finding against the PR's source tree and drops the ones it can disprove.
4. Posts each surviving finding as its own resolvable PR thread anchored to file/line.
5. When a developer replies, resolves the thread ONLY if they gave a reason it does not apply
   (`ignore: <reason>` or a credible technical justification -> `byDesign`). Agreement, thanks, or
   "I'm fixing it" leaves the thread active - a real bug is closed as `fixed` only when a later
   re-review verifies the issue is actually gone from the code, never on the strength of a comment.

All artifacts live in `.claude/skills/ado-pr-review/`. `config.json`, `state.json`, `logs/`, and
`.pat` are gitignored.

## One-time setup

### 1. (Optional) Install `az` CLI + Azure DevOps extension

The bot itself talks to ADO over REST and does not need `az` at runtime. `az` is only a convenience
for the setup smoke-test and for confirming your org/project names.

```powershell
winget install --id Microsoft.AzureCLI -e
# restart your terminal so PATH picks up `az`
az extension add --name azure-devops
```

### 2. Create a Personal Access Token (PAT)

Open `https://dev.azure.com/<your-org>/_usersSettings/tokens` -> **New Token** (on-prem:
`https://<server>/<collection>/_usersSettings/tokens`).

- **Name:** Claude PR review bot
- **Expiration:** 90 days (or whatever your org policy allows)
- **Scopes (Custom defined) - least privilege:**
  - **Code:** Read _(NOT Write - the bot never pushes commits, opens/closes PRs, or modifies branches)_
  - **Pull Request Threads:** Read & Write _(create, reply, resolve)_

  > If your ADO UI only offers "Read" or "Read & Write" at the top-level Code scope, pick **Read**. The
  > thread write permission comes from the separate "Pull Request Threads" scope, not from Code (Write).
- Click **Create** and copy the token (you only see it once).

### 3. Store config and PAT

```powershell
# from the repo root
Copy-Item .claude/skills/ado-pr-review/config.example.json .claude/skills/ado-pr-review/config.json
# edit config.json: set organization / project / repository / orgUrl (+ apiVersion for on-prem)
Set-Content .claude/skills/ado-pr-review/.pat "<paste-token>" -NoNewline
```

Both `config.json` and `.pat` are gitignored. The bot reads `$env:AZURE_DEVOPS_EXT_PAT`; the
`/pr-review` command and `gate.ps1` load it from `.pat` automatically. For an interactive shell you
can also set it yourself:

```powershell
$env:AZURE_DEVOPS_EXT_PAT = (Get-Content .claude/skills/ado-pr-review/.pat -Raw).Trim()
```

### 4. (Optional) Set `az` defaults

```powershell
az devops configure --defaults `
    organization=https://dev.azure.com/<your-org> `
    project="<your-project>"
az repos pr list --status active --query "[].pullRequestId" -o json | Select-Object -First 5
```

### 5. Smoke-test connectivity

```powershell
$env:AZURE_DEVOPS_EXT_PAT = (Get-Content .claude/skills/ado-pr-review/.pat -Raw).Trim()
. .\.claude\skills\ado-pr-review\lib\ado.ps1
Test-ADOConnectivity
```

Expected: `ok = True, repoId = <guid>, activePRs = <count>`.

## Running the bot

### Option A - on-demand

Start a Claude Code session in this repo and run:

```
/pr-review
```

One tick, then stop. The slash command (`.claude/commands/pr-review.md`) uses the same code paths as
the loop, so manual and loop ticks are interchangeable.

### Option B - recurring loop

```
/loop 10m /pr-review
```

Fires every 10 minutes (matches `polling.intervalMinutes`). Stop with `Ctrl-C` or `/loop stop`. Idle
ticks are cheap - the PowerShell preflight decides there is no work before any model reasoning - but
`/loop` still wakes the model every tick (a few K tokens even when idle). For zero-token idle polling,
use Option C.

### Option C - zero-token gate (recommended for always-on)

`gate.ps1` makes the lane decision in pure PowerShell (ADO REST only, no model) and spawns the review
pass **only** when there is new-commit or new-reply work. Idle polls cost zero AI tokens.

Test the decision path safely (prints instead of spawning Claude):

```powershell
$env:PRBOT_GATE_DRYRUN = '1'; .\.claude\skills\ado-pr-review\gate.ps1; Remove-Item Env:\PRBOT_GATE_DRYRUN
```

Lightweight always-on (foreground, dies when the terminal closes):

```powershell
while ($true) { .\.claude\skills\ado-pr-review\gate.ps1; Start-Sleep -Seconds 600 }
```

Unattended via Windows Task Scheduler (survives sleep/logoff; `-StartWhenAvailable` runs a poll you
missed while asleep):

```powershell
$repo   = (Get-Location).Path   # or hardcode your repo path
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NonInteractive -ExecutionPolicy Bypass -File `"$repo\.claude\skills\ado-pr-review\gate.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration ([TimeSpan]::MaxValue)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'ADO-PRReviewGate' -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Zero-cost poller for the ADO PR review bot'
# remove later: Unregister-ScheduledTask -TaskName 'ADO-PRReviewGate' -Confirm:$false
```

**Prerequisite for the headless pass:** non-interactive auth - `claude -p "say hi"` must run without
prompting. `gate.ps1` invokes the pass with `--dangerously-skip-permissions` (headless cannot answer
prompts and this is a trusted local bot driving its own repo). Remove that flag and add a
`.claude/settings.json` allowlist if you prefer a tighter scope. Gate activity logs to
`logs/YYYY-MM-DD.gate.log`; the spawned pass also writes `logs/YYYY-MM-DD.gate-claude.log`.

### Dry-run vs live

`behavior.dryRun` in `config.json` controls whether posts actually hit ADO. It ships `true`.
Recommended: run dry for 2-3 days on real PRs, read the logs, tune the review prompt, then set
`"dryRun": false`. Both `/pr-review` and the loop respect the flag identically. State is updated even
in dry-run, so re-runs do not re-post.

## What gets reviewed

Findings are limited to the categories in your review prompt (`review-pr.md` Step 3). The shipped
default is four: **Bugs**, **Security**, **Runtime performance**, **Data integrity** - style, naming,
formatting, and accessibility (unless broken) are explicitly skipped. Tune this to your stack; it is
the single biggest lever on signal. See `references/review-prompt-examples.md`.

Skipped paths are configured in `config.json` -> `review.skipPathGlobs` (lockfiles, minified bundles,
`node_modules`, `dist`, generated files). Add your repo's generated/serialized noise there so it never
enters model context.

## Handling developer pushback

A finding thread has exactly two terminal states, and a developer's words can only reach one:

- **`byDesign` (false positive / won't-fix)** - reached when the dev gives a reason the finding does
  not apply (`ignore: <reason>` or a credible technical justification). The bot resolves the thread and
  records a signature so the same finding is never re-raised on this PR. This is the only outcome
  counted as a false positive.
- **`fixed` (real bug, actually fixed)** - reached ONLY by a later re-review that verifies the issue is
  gone from the code at the new SHA. Never reached by a comment.

Everything else - agreement, "I'm fixing it", thanks, chatter - leaves the thread **active**. The bot
counters at most `maxReplyCounterRounds` times (default 1), then hands off to the human. It never
argues more than once and never closes a real bug on the strength of a comment.

## State and logs

- `state.json` - per-PR review state (SHAs, threads, ignored signatures). Inspect anytime; edit only
  when stopped. Schema is at the top of `lib/state.ps1`.
- `logs/YYYY-MM-DD.log` - one JSON object per tick.

## Stopping the bot

- **All PRs:** set `behavior.dryRun = true`. Existing threads remain; the bot just stops writing.
- **One PR:** delete that PR's entry from `state.json` while stopped, or leave it - it will not re-post
  findings it already posted.
- **Forever:** delete `.claude/skills/ado-pr-review/` and the `.claude/commands/pr-review.md` command.

## Maintenance

- **The review prompt** lives in `review-pr.md` Step 3. It is yours to own and edit - the bot never
  changes it. Keep the `**[CATEGORY]** file:line / problem / fix` output shape or update the Step 4
  parser to match.
- **PAT rotation:** regenerate in Azure DevOps, update `.pat`. No code changes needed.
- **API version** is pinned in `config.json` -> `azureDevOps.apiVersion`. Bump cautiously - ADO REST
  has subtle differences between versions. On-prem (Azure DevOps Server) may need a lower value
  (e.g. `6.0`).

## On-prem (Azure DevOps Server) notes

The engine builds every request from `config.azureDevOps.orgUrl` and authenticates with a PAT Basic
header - there is no hardcoded `dev.azure.com`. So on-prem is *expected* to work by setting
`orgUrl` to `https://<server>/<collection>` and possibly lowering `apiVersion`. Two caveats, unverified
until tried against a real server:

- Your server may require Windows/NTLM auth instead of PATs (PATs must be enabled).
- Older API versions occasionally differ on the threads endpoints; if thread posts fail, drop
  `apiVersion` and retry.
