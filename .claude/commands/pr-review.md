Run exactly ONE pass of the Azure DevOps PR review bot on this repo and stop. Do NOT enter a loop, do NOT schedule a follow-up.

## Steps

1. Load the PAT before sourcing anything else:

   ```powershell
   $env:AZURE_DEVOPS_EXT_PAT = (Get-Content .claude/skills/ado-pr-review/.pat -Raw).Trim()
   ```

   If `.claude/skills/ado-pr-review/.pat` is missing or empty, stop and tell the user how to recreate it (see `.claude/skills/ado-pr-review/README.md` step 3).

2. Read `.claude/skills/ado-pr-review/review-loop.md` and execute its per-tick algorithm exactly once:
   - List active PRs targeting the configured branches
   - For each PR in Lane A (new SHA), dispatch the per-PR review subagent (`.claude/skills/ado-pr-review/review-pr.md`)
   - For each PR in Lane B (new dev replies on bot threads), dispatch the resolver subagent (`.claude/skills/ado-pr-review/resolve-replies.md`)
   - Skip Lane C (nothing to do)
   - Update `.claude/skills/ado-pr-review/state.json` and append a JSON line to today's log file

3. Respect `behavior.dryRun` from `.claude/skills/ado-pr-review/config.json` exactly as the loop would. If `dryRun=true`, no writes to ADO.

4. After the tick completes, print a one-line summary like:

   `Tick @ <iso8601> - scanned N PRs, reviewed K, handled M replies, E errors (<live|DRY-RUN>)`

   Then stop. Do not start a `/loop`. Do not poll. Do not propose a next run.

## Notes

- Same code paths and same state file as the recurring loop - so a manual `/pr-review` between long gaps will catch up correctly (it just compares each PR's current SHA against `state.json.lastReviewedSha`).
- If you want this to run on a schedule instead, use `/loop 10m /pr-review` once and the loop skill will repeat this same command on its own cadence. For zero-token idle polling, use `gate.ps1` (see the skill README).

$ARGUMENTS
