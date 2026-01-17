# ============================================================
# agent.ps1 (Windows PowerShell 5.1 SAFE)
# Dual-model autonomous agent
#
# Planner : phi3-4k
# Writer  : codellama:7b-instruct
#
# GUARANTEES:
# - JSON-only planning
# - Action schema enforcement
# - Replan-until-correct semantics
# ============================================================

# ------------------ ELEVATION ------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )
    exit
}

$ErrorActionPreference = "Stop"

# ------------------ CONFIG ------------------
$PlannerModel = "phi3-4k"
$WriterModel  = "codellama:7b-instruct"

$PlannerNumCtx   = 4096
$PlannerPredict  = 900
$PlannerTemp     = 0.2

$WriterNumCtx    = 4096
$WriterPredict   = 2400
$WriterTemp      = 0.15

$MaxPlanIterations = 25
$MaxPlanMinutes    = 10
$RequireConfidence = 0.75

$OllamaTagsApi = "http://localhost:11434/api/tags"
$OllamaGenApi  = "http://localhost:11434/api/generate"

# ------------------ GOAL ------------------
$Goal = Read-Host "Enter goal"

# ------------------ OLLAMA WAIT ------------------
function Wait-ForOllama {
    for ($i = 1; $i -le 15; $i++) {
        try {
            Invoke-RestMethod -Method Get -Uri $OllamaTagsApi -TimeoutSec 3 | Out-Null
            return
        } catch {
            Write-Host "[AGENT] Waiting for Ollama API... ($i/15)"
            Start-Sleep -Seconds 1
        }
    }
    throw "Ollama API not reachable"
}
Wait-ForOllama

# ------------------ OLLAMA CALL ------------------
function Invoke-Ollama {
    param(
        [string]$Model,
        [string]$Prompt,
        [string]$System,
        [hashtable]$Options
    )

    $body = @{
        model   = $Model
        prompt  = $Prompt
        system  = $System
        options = $Options
        stream  = $false
    }

    (Invoke-RestMethod `
        -Uri $OllamaGenApi `
        -Method Post `
        -ContentType "application/json" `
        -Body ($body | ConvertTo-Json -Depth 10) `
        -TimeoutSec 600
    ).response
}

# ------------------ JSON EXTRACT ------------------
function Extract-Json {
    param([string]$Text)
    $start = $Text.IndexOf("{")
    if ($start -lt 0) { return $null }
    $depth = 0
    for ($i = $start; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "{") { $depth++ }
        elseif ($Text[$i] -eq "}") {
            $depth--
            if ($depth -eq 0) {
                return $Text.Substring($start, $i - $start + 1)
            }
        }
    }
    return $null
}

# ------------------ PLAN PROMPT ------------------
function Build-PlanPrompt {
@"
Return JSON ONLY.
Schema:
{
  "goal": "string",
  "thinking_summary": ["string"],
  "reflection": {
    "issues_found": ["string"],
    "changes_made": ["string"],
    "confidence": 0.0
  },
  "ready": true,
  "plan": [
    {
      "step": 1,
      "action": "READ_FILE|<path> or WRITE_FILE|<path>|<spec> or RUN_COMMAND|<command>",
      "expects": "string"
    }
  ]
}

Rules:
- Provide a brief thinking_summary (2-4 short bullets). Do NOT include chain-of-thought.
- Plan should be minimal and ordered.
- Prefer READ_FILE before WRITE_FILE when editing an existing file.
- Avoid destructive commands.
- Use absolute or workspace-relative paths.

GOAL:
$Goal
"@
}

# ------------------ PLANNING LOOP ------------------
$start = Get-Date
$plan = $null

for ($i = 1; $i -le $MaxPlanIterations; $i++) {

    if ((New-TimeSpan $start (Get-Date)).TotalMinutes -gt $MaxPlanMinutes) {
        throw "Planning timeout"
    }

    Write-Host "`n[AGENT] Planning iteration $i..."

    $raw = Invoke-Ollama `
        -Model $PlannerModel `
        -Prompt (Build-PlanPrompt) `
        -System "Return JSON only." `
        -Options @{
            num_ctx     = $PlannerNumCtx
            num_predict = $PlannerPredict
            temperature = $PlannerTemp
        }

    $json = Extract-Json $raw
    if (-not $json) { continue }

    $candidate = $json | ConvertFrom-Json
    $allActionsValid = $true
    foreach ($p in $candidate.plan) {
        if ($p.action -notmatch '^(READ_FILE|WRITE_FILE|RUN_COMMAND)\|') {
            $allActionsValid = $false
            break
        }
    }
    if (-not $allActionsValid) { continue }
    if ($candidate.reflection.confidence -ge $RequireConfidence -and $candidate.ready) {
        $plan = $candidate
        break
    }
}

if (-not $plan) { throw "No valid plan produced" }

# ------------------ APPROVAL ------------------
Write-Host "`nPROPOSED PLAN:"
$plan.plan | Format-Table step, action, expects

if ($plan.thinking_summary) {
    Write-Host "`nAGENT THINKING (summary):"
    $plan.thinking_summary | ForEach-Object { Write-Host "- $_" }
}

if ((Read-Host "Approve plan? (y/n)") -ne "y") { exit }

# ------------------ WRITE FILE ------------------
function Write-File {
    param([string]$Path, [string]$Spec)

    $contextText = ""
    if ($script:Context.Count -gt 0) {
        $contextText = "`nCONTEXT:`n" + ($script:Context.GetEnumerator() | ForEach-Object {
            $content = $_.Value
            if ($content.Length -gt 4000) {
                $content = $content.Substring(0, 4000) + "`n...[truncated]"
            }
            "FILE: $($_.Key)`n$content"
        } | Out-String)
    }

    $content = Invoke-Ollama `
        -Model $WriterModel `
        -System "Write ONLY raw PowerShell. Follow SPEC precisely. Include examples only when requested." `
        -Prompt @"
GOAL:
$Goal

TARGET FILE:
$Path

SPEC:
$Spec
$contextText
"@ `
        -Options @{
            num_ctx     = $WriterNumCtx
            num_predict = $WriterPredict
            temperature = $WriterTemp
        }

    $clean = $content -replace '^\s*```.*?\n','' -replace '\n```$',''
    $clean | Out-File -FilePath $Path -Encoding utf8 -Force

    Write-Host "[WRITER] Wrote $Path"
}

# ------------------ READ FILE ------------------
function Read-File {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-Host "[READER] Missing: $Path"
        return
    }

    $script:Context[$Path] = Get-Content -Raw -Path $Path
    Write-Host "[READER] Loaded $Path"
}

# ------------------ RUN COMMAND ------------------
function Run-Command {
    param([string]$Command)

    if ($Command -match '(?i)\b(remove-item|del|erase|rm|rd|rmdir|format|diskpart|clear-disk|shutdown|restart-computer|reg\s+add|reg\s+delete|move-item|copy-item|rename-item|set-content|out-file)\b') {
        Write-Host "[RUNNER] Blocked potentially destructive command: $Command"
        return
    }

    Write-Host "[RUNNER] $Command"
    Invoke-Expression $Command
}

# ------------------ EXECUTION ------------------
$script:Context = @{}
foreach ($s in $plan.plan) {
    if ($s.action -match '^READ_FILE\|(.+)$') {
        Read-File -Path $matches[1]
        continue
    }

    if ($s.action -match '^WRITE_FILE\|(.+?)\|(.+)$') {
        Write-File -Path $matches[1] -Spec $matches[2]
        continue
    }

    if ($s.action -match '^RUN_COMMAND\|(.+)$') {
        Run-Command -Command $matches[1]
        continue
    }
}

Write-Host "`n[AGENT] Done."


