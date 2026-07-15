# claude-ado-pr-review

An automated senior code reviewer for **Azure DevOps** pull requests, driven by
[Claude Code](https://claude.com/claude-code). It polls active PRs, runs a review prompt over each
diff, **verifies each finding against the PR's actual source tree** to cut false positives, and posts
what survives as resolvable ADO threads - then handles developer replies without nagging.

It is packaged as a Claude Code **skill** plus a companion **slash command**, so you install it into a
repo's `.claude/` and drive it with `/pr-review` (or let it poll on its own for zero idle cost).

> Built because the official Azure DevOps MCP server runs only inside VS Code / Visual Studio, and I
> wanted PR review running unattended, not in my editor. A local polling bot in Claude Code fits that gap.

## What it does

```
poll active PRs  ->  new commits?  ->  review the diff  ->  verify each finding vs the source tree
                                                              ->  post survivors as resolvable threads
new dev reply?   ->  ignore reason? resolve (byDesign)  |  agreement/"fixing it"? leave active
next re-review   ->  issue gone from code? resolve (fixed)
```

- **Findings are pre-verified.** Each candidate finding's hypothesis is checked with `git grep`/
  `git show` at the PR head SHA before posting; disprovable ones are dropped, confirmed ones are
  upgraded with concrete evidence. This is the main precision control.
- **A comment never closes a real bug.** Only an explicit `ignore: <reason>` (or a justification
  proving the finding wrong), or a later re-review that verifies the code changed, resolves a thread.
- **Narrow by design.** Four categories - Bugs, Security, Runtime performance, Data integrity - and an
  explicit skip list. Style/naming/formatting noise is out.

## Install

Copy two things into your repo's `.claude/`:

```bash
git clone https://github.com/harshbaid/claude-ado-pr-review
cp -r claude-ado-pr-review/.claude/skills/ado-pr-review  <your-repo>/.claude/skills/
cp    claude-ado-pr-review/.claude/commands/pr-review.md <your-repo>/.claude/commands/
```

Then the one-time setup (PAT + config) in
[.claude/skills/ado-pr-review/README.md](.claude/skills/ado-pr-review/README.md).

## Quickstart

```powershell
# from your repo root, after copying the skill in:
Copy-Item .claude/skills/ado-pr-review/config.example.json .claude/skills/ado-pr-review/config.json
# edit config.json: organization / project / repository / orgUrl
Set-Content .claude/skills/ado-pr-review/.pat "<your-ADO-PAT>" -NoNewline   # Code:Read + PR Threads:Read&Write

# smoke-test
$env:AZURE_DEVOPS_EXT_PAT = (Get-Content .claude/skills/ado-pr-review/.pat -Raw).Trim()
. .\.claude\skills\ado-pr-review\lib\ado.ps1 ; Test-ADOConnectivity
```

`config.json` ships with `dryRun: true` - run it dry, read the logs, tune the prompt, then go live.

Then, in a Claude Code session in that repo:

```
/pr-review
```

## Run modes

| Mode | How | Idle cost | When |
|---|---|---|---|
| **On-demand** | `/pr-review` | one model tick | Sweep at your own pace |
| **Recurring loop** | `/loop 10m /pr-review` | a few K tokens/tick | Continuous within a session |
| **Zero-token gate** | `gate.ps1` on a schedule / sleep-loop | **zero tokens** | Always-on; spends only on real work |

The gate does the "is there work?" decision in pure PowerShell and invokes the model only when a PR
has a new commit or a new reply. A common always-on setup is one terminal running:

```powershell
while ($true) { .\.claude\skills\ado-pr-review\gate.ps1; Start-Sleep -Seconds 600 }
```

## Cloud vs on-prem

- **Azure DevOps Services (cloud):** works out of the box.
- **Azure DevOps Server (on-prem):** expected to work with config-only changes (`orgUrl` ->
  `https://<server>/<collection>`, possibly a lower `apiVersion`), since the engine is pure REST + PAT
  with no hardcoded host. Unverified - the likely snags are PAT-vs-Windows auth and older API versions.
  If you run it on-prem, a report back (issue/PR) is very welcome.

## Requirements

- Windows PowerShell 5.1+, Git, and Claude Code.
- An ADO PAT with least privilege: **Code: Read** + **Pull Request Threads: Read & Write**. The bot
  never pushes commits or changes branches.

## Safety

- Dry-run by default; no writes until you opt in.
- Least-privilege PAT; `.pat` and `config.json` are gitignored.
- Comments post under your PAT identity with an "automated review" footer. If volume bothers the team,
  use a dedicated service account.

## Complementary: deep manual review

This bot is a fast, always-on net for a few high-value categories - not a substitute for a thorough
review of a gnarly change. For complex or high-risk PRs, pair it with a deep manual pass such as
Matt Pocock's [`code-review` skill](https://github.com/mattpocock/skills/blob/main/skills/engineering/code-review/SKILL.md),
run on demand. The two are complementary: this bot triages the everyday flow so your attention (and a
heavier review skill) is spent where it matters.

## Roadmap

**Multi-CLI - shipped for the gate.** The engine (PowerShell + Azure DevOps REST + the state machine)
is AI-CLI-agnostic, and `gate.ps1` now spawns a **configurable** agent - `config.agent` gives a
`command` + `args` array (with a `{prompt}` placeholder), defaulting to Claude Code when omitted. The
review logic itself lives in plain-Markdown prompt files any capable agent can execute. So the same
bot can drive **Gemini CLI / Google Antigravity**, **GitHub Copilot CLI**, or any headless agent that
runs non-interactively - see
[Using a different agent CLI](.claude/skills/ado-pr-review/README.md#using-a-different-agent-cli).

Still open:

- Only Claude Code is tested end to end - the Gemini and Copilot paths are wired but unproven (exact
  flags, and how well the model follows the verify-before-posting discipline).
- The interactive `/pr-review` and `/loop` modes remain Claude Code-specific; the gate is the portable
  path for other CLIs.
- Broader verification recipes and a lightweight per-PR review-quality signal.

PRs - especially "I ran it on CLI X (or on-prem ADO) and here is what I hit" - are very welcome.

## License

[MIT](LICENSE)
