# gate.ps1 - ZERO-TOKEN poller for the PR review bot.
#
# Run this on a schedule (Windows Task Scheduler, or a sleep-loop). It makes the lane
# decision in pure PowerShell - hitting only the ADO REST API, NO model invocation - and
# spawns the configured review agent ONLY when there is actual Lane A (new SHA) or Lane B
# (new dev reply) work. Idle polls therefore cost zero AI tokens; the agent is invoked
# exclusively when the "AI brain" is genuinely needed.
#
# Which agent it spawns is config-driven (config.agent.reviewCommand, {prompt} substituted
# with config.agent.reviewPrompt). It defaults to Claude Code (`claude -p "/pr-review"`) when
# the agent block is absent, so this is backward compatible. See README "Using a different
# agent CLI" to point it at Gemini CLI / Antigravity, GitHub Copilot CLI, or any headless agent.
#
# Contrast with `/loop 10m /pr-review`: that re-invokes the model every tick (a few K tokens
# even when idle). This gate is free until there is work.
#
# Dry-run: set $env:PRBOT_GATE_DRYRUN=1 to print the resolved command that WOULD be invoked
# instead of spawning it (used to test the decision path safely).

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path           # ...\.claude\skills\ado-pr-review
$repo = (Resolve-Path (Join-Path $here '..\..\..')).Path          # repo root (three levels up from the skill folder)
Set-Location $repo

$logDir = Join-Path $here 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
$gateLog = Join-Path $logDir ((Get-Date).ToString('yyyy-MM-dd') + '.gate.log')
function Write-GateLog([string] $msg) {
    $line = "$([DateTime]::Now.ToString('o')) $msg"
    Add-Content -Path $gateLog -Value $line -Encoding utf8
    Write-Host $line
}

# Single-instance lock so a long review pass cannot overlap the next scheduled poll.
$lock = Join-Path $here '.gate.lock'
if (Test-Path $lock) {
    $age = (Get-Date) - (Get-Item $lock).LastWriteTime
    if ($age.TotalMinutes -lt 30) { Write-GateLog "gate: previous pass still running ($([int]$age.TotalMinutes)m) - skipping poll"; return }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue   # stale lock
}

# Load PAT here - the gate runs outside any /pr-review session.
$patFile = Join-Path $here '.pat'
if (-not (Test-Path $patFile) -or [string]::IsNullOrWhiteSpace((Get-Content $patFile -Raw))) {
    Write-GateLog "gate: .pat missing/empty - cannot poll (see README step 3)"; return
}
$env:AZURE_DEVOPS_EXT_PAT = (Get-Content $patFile -Raw).Trim()

. (Join-Path $here 'lib\ado.ps1')
. (Join-Path $here 'lib\state.ps1')
. (Join-Path $here 'lib\preflight.ps1')

# --- The poll: pure PowerShell, zero model tokens ---
$plan = Get-TickPlan

if (-not $plan.ok) { Write-GateLog "gate: ADO unreachable - $($plan.error)"; return }

$work = (@($plan.laneA).Count + @($plan.laneB).Count)
if ($work -eq 0) {
    Write-GateLog "gate: idle (scanned $($plan.scanned), laneC=$(@($plan.laneC).Count)) - model NOT invoked, 0 tokens"
    return
}

# --- Work exists: NOW (and only now) spend tokens on the AI pass ---
$laneAIds = (@($plan.laneA) | ForEach-Object { $_.id }) -join ','
$laneBIds = (@($plan.laneB) | ForEach-Object { $_.id }) -join ','
Write-GateLog "gate: WORK FOUND (laneA=[$laneAIds] laneB=[$laneBIds]) - invoking review pass"

# Resolve WHICH agent CLI to spawn from config, as an executable + argument array (no shell eval).
# Each arg has {prompt} substituted with config.agent.prompt. Absent agent block -> Claude Code
# default (backward compatible). See README "Using a different agent CLI".
$cfg       = Get-ADOConfig
$agentCmd  = if ($cfg.agent -and $cfg.agent.command) { [string]$cfg.agent.command } else { 'claude' }
$agentArgs = if ($cfg.agent -and $cfg.agent.args)    { @($cfg.agent.args) }         else { @('-p', '{prompt}', '--dangerously-skip-permissions') }
$prompt    = if ($cfg.agent -and $cfg.agent.prompt)  { [string]$cfg.agent.prompt }  else { '/pr-review' }
$resolvedArgs = @($agentArgs | ForEach-Object { ([string]$_).Replace('{prompt}', $prompt) })

if ($env:PRBOT_GATE_DRYRUN -eq '1') {
    Write-GateLog "gate: [DRYRUN] would run: $agentCmd $($resolvedArgs -join ' ')"
    return
}

Set-Content -Path $lock -Value ([DateTime]::Now.ToString('o'))
try {
    $agentLog = Join-Path $logDir ((Get-Date).ToString('yyyy-MM-dd') + '.gate-agent.log')
    # Headless one-shot review pass. The agent writes to ADO + state.json and headless cannot
    # answer permission prompts, so config.agent.args should include the CLI's auto-approve flag
    # (this is a trusted local bot driving its own repo). Called via the call operator with a
    # splatted arg array - flags pass through verbatim, no shell evaluation.
    & $agentCmd @resolvedArgs 2>&1 | Tee-Object -FilePath $agentLog -Append
    Write-GateLog "gate: review pass exited ($LASTEXITCODE)"
}
finally {
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
}
