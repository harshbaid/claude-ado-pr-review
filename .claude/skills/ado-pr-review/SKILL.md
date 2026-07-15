---
name: ado-pr-review
description: Automated senior-level code review for Azure DevOps pull requests, driven by Claude Code. Polls active PRs, runs a configurable review prompt over each diff, pre-verifies findings against the PR's source tree to cut false positives, and posts each surviving finding as its own resolvable ADO thread. Handles developer pushback (a comment never closes a real bug; only a verified code fix or an explicit "ignore" does). Use when asked to review Azure DevOps PRs, set up automated PR review, run the PR bot, or do a review pass. Triggers: "review the PRs", "run the pr bot", "/pr-review", "check open pull requests".
---

# Azure DevOps PR review bot

Automates a senior code review on Azure DevOps PRs, downstream of PR creation:

1. Polls Azure DevOps every N minutes for active PRs on configured target branches.
2. When a PR is new or has new commits, runs your review prompt over the diff.
3. **Pre-verifies** each finding against the PR's source tree (`git grep`/`git show` at the head SHA) and drops the ones it can disprove - this is the main false-positive control.
4. Posts each surviving finding as its own resolvable PR thread, anchored to file/line.
5. When a developer replies, resolves the thread ONLY if they gave a reason it does not apply (`ignore: <reason>` or a credible justification). Agreement or "I'm fixing it" leaves it active - a real bug is closed only when a later re-review verifies the code actually changed.

Works against **Azure DevOps Services (cloud)** out of the box. **Azure DevOps Server (on-prem)** is expected to work with config-only changes (`orgUrl` -> `https://<server>/<collection>`, possibly a lower `apiVersion`), because the engine is pure REST + PAT with no hardcoded host - but that path is unverified; PAT-vs-Windows-auth and older API versions are the likely snags.

## Install

Copy two things into the target repo's `.claude/`:
- this skill folder -> `.claude/skills/ado-pr-review/`
- `commands/pr-review.md` -> `.claude/commands/pr-review.md`

Then do the one-time setup in [README.md](README.md): install `az` (optional convenience), create a PAT, write `config.json` (from `config.example.json`) and `.pat`.

## Prerequisites

- **Windows PowerShell 5.1+** (the engine is PowerShell; it uses `git` + ADO REST).
- **Git** with the repo cloned and `origin` pointing at the ADO remote (diffs are computed locally).
- A **PAT** with `Code: Read` + `Pull Request Threads: Read & Write` (least privilege - the bot never pushes code).
- For headless/scheduled runs: `claude -p` must run without prompting.

If `.pat` or `config.json` is missing, stop and point the user at README setup.

## Run modes (all share one `state.json`)

| Mode | Command | Cost when idle | Use when |
|---|---|---|---|
| **On-demand** | `/pr-review` | one model tick | You want a sweep at your own pace |
| **Recurring loop** | `/loop 10m /pr-review` | a few K tokens/tick | Continuous polling within a session |
| **Zero-token gate** | `gate.ps1` on a schedule/sleep-loop | **zero tokens** | Unattended polling - spends tokens only when there is real work |

The gate is the recommended always-on mode: it makes the lane decision in pure PowerShell (ADO REST only) and spawns the model **only** when a PR has a new commit or a new reply. A common setup is a foreground loop in its own terminal:

```powershell
while ($true) { .\.claude\skills\ado-pr-review\gate.ps1; Start-Sleep -Seconds 600 }
```

See README for the Windows Task Scheduler version (survives sleep/logoff).

## Start in dry-run

`behavior.dryRun` in `config.json` is `true` by default. It computes and logs everything but posts nothing to ADO. Run dry for a few days on real PRs, read the logs, tune the review prompt (see `references/review-prompt-examples.md`), then flip to `false`.

## The two things worth tuning

1. **The review prompt** (`review-pr.md` Step 3) - names your stack and the categories you care about. This is the brain. See `references/review-prompt-examples.md`.
2. **Verification recipes** (`references/verification-recipes.md`) - stack-specific rules so the pre-verify step doesn't false-positive on your ID/reference conventions.

## Safety model

- **Least-privilege PAT** (read code, write threads only). The bot never pushes commits or changes branches.
- **Dry-run default.** No writes until you opt in.
- **Pushback protocol.** A finding thread has exactly two terminal states: `byDesign` (dev gave an ignore reason - the only reply-driven close) and `fixed` (a later re-review verified the code changed). Agreement/thanks/"fixing it" never closes a thread. The bot counters at most once, then hands off to the human.
- **Comments post under your PAT identity** - so teammates see a human name. The footer marks each as automated. If comment volume bothers the team, consider a dedicated service account.

Full setup, run details, troubleshooting, and maintenance are in [README.md](README.md).
