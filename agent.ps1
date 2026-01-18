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

$ConfirmOncePerTask  = $true
$ConfirmRiskyActions = $true
$ConfirmLowConfidence = $true

$OllamaTagsApi = "http://localhost:11434/api/tags"
$OllamaGenApi  = "http://localhost:11434/api/generate"

$DebugLogPath = "C:\agent\agent-debug.log"
$DebugLogMaxChars = 2000
$RootDir = "C:\agent\"

# ------------------ GOAL ------------------
$OriginalGoal = Read-Host "Enter goal"

# ------------------ DEBUG LOG ------------------
function Log-Debug {
    param([string]$Message)
    $ts = (Get-Date).ToString("s")
    Add-Content -Path $DebugLogPath -Value ("[{0}] {1}" -f $ts, $Message)
}

function Log-Debug-Raw {
    param(
        [string]$Label,
        [string]$Text
    )
    if (-not $Text) {
        Log-Debug ("{0}: <empty>" -f $Label)
        return
    }
    $clean = $Text -replace "(\r\n|\r|\n)", "\n"
    if ($clean.Length -gt $DebugLogMaxChars) {
        $clean = $clean.Substring(0, $DebugLogMaxChars) + "...[truncated]"
    }
    Log-Debug ("{0}: {1}" -f $Label, $clean)
}

# ------------------ GOAL SANITIZER ------------------
function Sanitize-Goal {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $Text = $Text -replace '(?i)chain of thought', 'brief reasoning summary (no chain-of-thought)'
    $Text = $Text -replace '(?i)action chain of thought', 'brief reasoning summary (no chain-of-thought)'
    $Text
}

$Goal = Sanitize-Goal -Text $OriginalGoal
if ($Goal -ne $OriginalGoal) {
    Write-Host "[AGENT] Note: sanitized goal to avoid chain-of-thought."
    Log-Debug "Sanitized goal: '$OriginalGoal' -> '$Goal'"
}

$RequireRootPath = $RootDir
Log-Debug "RequireRootPath: $RequireRootPath"

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

# ------------------ JSON REPAIR ------------------
function Repair-Json {
    param([string]$Text)
    if (-not $Text) { return $null }
    $repairPrompt = @"
Fix the following output into valid JSON that matches the required schema.
Return JSON ONLY, no commentary.

INPUT:
$Text
"@
    Invoke-Ollama `
        -Model $PlannerModel `
        -Prompt $repairPrompt `
        -System "Return JSON only." `
        -Options @{
            num_ctx     = $PlannerNumCtx
            num_predict = $PlannerPredict
            temperature = 0.0
        }
}

# ------------------ PATH NORMALIZE ------------------
function Normalize-PathString {
    param([string]$Path)

    if (-not $Path) { return $Path }
    $p = $Path -replace '/', '\'
    if ($p -match '^[A-Za-z]:\\\\+') {
        $p = $p -replace '^[A-Za-z]:\\\\+', { param($m) $m.Value.Substring(0,3) }
    } elseif ($p -match '^\\\\\\\\') {
        $p = $p -replace '^\\\\\\\\+', '\\\\'
    }
    $p
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
- Use absolute Windows paths or workspace-relative paths under C:\agent only.
- Do not use placeholders like "<path>" or "/path/to/...".
- Do not use Unix-style paths (e.g., /home/user).
- WRITE_FILE spec must be actual intended file contents or clear instructions, not metadata like "text/plain".
- Actions must be single-line; if content needs newlines, use \n escapes in the spec.
- Output must be valid JSON with no stray text, extra numbers, or trailing commas.
- Do not include raw newlines inside action strings; use \\n escapes only.
- Respect any directory constraints explicitly stated in the goal.
- Allowed actions only: READ_FILE, WRITE_FILE, RUN_COMMAND. Do not invent new action types.

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
    Log-Debug "Planning iteration $i"

    $raw = Invoke-Ollama `
        -Model $PlannerModel `
        -Prompt (Build-PlanPrompt) `
        -System "Return JSON only." `
        -Options @{
            num_ctx     = $PlannerNumCtx
            num_predict = $PlannerPredict
            temperature = $PlannerTemp
        }
    Log-Debug-Raw -Label "Planner raw" -Text $raw

    $json = Extract-Json $raw
    if (-not $json) {
        Write-Host "[AGENT] Reject: no JSON detected"
        Log-Debug "Reject: no JSON detected"
        continue
    }

    try {
        $candidate = $json | ConvertFrom-Json
    } catch {
        Write-Host "[AGENT] Reject: invalid JSON"
        Log-Debug "Reject: invalid JSON"
        $repaired = Repair-Json -Text $raw
        Log-Debug-Raw -Label "Planner repaired" -Text $repaired
        if ($repaired) {
            $repairedJson = Extract-Json $repaired
            if ($repairedJson) {
                try {
                    $candidate = $repairedJson | ConvertFrom-Json
                    Write-Host "[AGENT] Recovered: JSON repaired"
                    Log-Debug "Recovered: JSON repaired"
                } catch {
                    continue
                }
            } else {
                continue
            }
        } else {
            continue
        }
    }
    $normalizedActions = $false
    foreach ($p in $candidate.plan) {
        if ($p.action -match "[\r\n]") {
            $p.action = ($p.action -replace "(\r\n|\r|\n)", "\\n")
            $normalizedActions = $true
        }
        if ($p.action -match '^(READ_FILE|WRITE_FILE)\|') {
            $parts = $p.action.Split('|',3)
            if ($parts.Length -ge 2) {
                $norm = Normalize-PathString -Path $parts[1]
                if ($norm -ne $parts[1]) {
                    $parts[1] = $norm
                    $p.action = ($parts -join '|')
                    $normalizedActions = $true
                }
            }
        }
    }
    if ($normalizedActions) {
        Write-Host "[AGENT] Normalized action(s)"
        Log-Debug "Normalized action(s)"
    }

    $allActionsValid = $true
    foreach ($p in $candidate.plan) {
        if ($p.action -notmatch '^(READ_FILE|WRITE_FILE|RUN_COMMAND)\|') {
            $allActionsValid = $false
            break
        }
        if ($p.action -match "[\r\n]") {
            $allActionsValid = $false
            break
        }
    }
    if (-not $allActionsValid) {
        Write-Host "[AGENT] Reject: invalid action format"
        $candidate.plan | ForEach-Object { Write-Host " - $($_.action)" }
        Log-Debug "Reject: invalid action format"
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        continue
    }
    $pathsValid = $true
    foreach ($p in $candidate.plan) {
        if ($p.action -match '^(READ_FILE|WRITE_FILE)\|') {
            $path = $p.action.Split('|',3)[1]
            if ($path -match '<path>|/path/to' -or $path -match '^(?i)/home/|^/|\\?/') {
                $pathsValid = $false
                break
            }
            if ($path -notmatch '^(?i)[A-Za-z]:\\|^\\\\|^\\.|^\\.\\') {
                $pathsValid = $false
                break
            }
            if ($RequireRootPath -and ($path -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
                $pathsValid = $false
                break
            }
        }
        if ($p.action -match '^RUN_COMMAND\|') {
            $cmd = $p.action.Substring("RUN_COMMAND|".Length)
            $absPaths = [regex]::Matches($cmd, '[A-Za-z]:\\[^"\\s]+')
            foreach ($m in $absPaths) {
                if ($RequireRootPath -and ($m.Value -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
                    $pathsValid = $false
                    break
                }
            }
            if (-not $pathsValid) { break }
        }
    }
    if (-not $pathsValid) {
        Write-Host "[AGENT] Reject: invalid path"
        $candidate.plan | ForEach-Object { Write-Host " - $($_.action)" }
        Log-Debug "Reject: invalid path"
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        continue
    }
    $writeSpecsValid = $true
    foreach ($p in $candidate.plan) {
        if ($p.action -match '^WRITE_FILE\|') {
            $parts = $p.action.Split('|',3)
            if ($parts.Length -lt 3) {
                $writeSpecsValid = $false
                break
            }
            $spec = $parts[2].Trim()
            if ($spec.Length -lt 10 -or $spec -match '(?i)\btext/plain\b|<spec>|<content>|<file>') {
                $writeSpecsValid = $false
                break
            }
        }
    }
    if (-not $writeSpecsValid) {
        Write-Host "[AGENT] Reject: invalid WRITE_FILE spec"
        $candidate.plan | ForEach-Object { Write-Host " - $($_.action)" }
        Log-Debug "Reject: invalid WRITE_FILE spec"
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        continue
    }
    if ($candidate.ready) {
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

if ($plan.reflection -and $plan.reflection.confidence -ne $null) {
    Write-Host "`nCONFIDENCE: $($plan.reflection.confidence)"
}

if ($ConfirmOncePerTask) {
    if ((Read-Host "Approve plan? (y/n)") -ne "y") { exit }
}

if ($ConfirmLowConfidence -and $plan.reflection -and $plan.reflection.confidence -lt $RequireConfidence) {
    if ((Read-Host "Low confidence. Continue anyway? (y/n)") -ne "y") { exit }
}

# ------------------ WRITE FILE ------------------
function Write-File {
    param([string]$Path, [string]$Spec)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[WRITER] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[WRITER] Invalid Unix-style path: $Path"
        return
    }

    if ($Spec.Length -ge 2) {
        if ($Spec.StartsWith("'") -and $Spec.EndsWith("'")) {
            $Spec = $Spec.Substring(1, $Spec.Length - 2)
        } elseif ($Spec.StartsWith('"') -and $Spec.EndsWith('"')) {
            $Spec = $Spec.Substring(1, $Spec.Length - 2)
        }
    }

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
        -System "Write ONLY the file contents described in SPEC. Do not output commands, prompts, markdown fences, or explanations." `
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

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[READER] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[READER] Invalid Unix-style path: $Path"
        return
    }

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

    $absPaths = [regex]::Matches($Command, '[A-Za-z]:\\[^"\\s]+')
    foreach ($m in $absPaths) {
        if ($RequireRootPath -and ($m.Value -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
            Write-Host "[RUNNER] Blocked command with external path: $Command"
            return
        }
    }

    if ($Command -match '(?i)\b(remove-item|del|erase|rm|rd|rmdir|format|diskpart|clear-disk|shutdown|restart-computer|reg\s+add|reg\s+delete|move-item|copy-item|rename-item|set-content|out-file)\b') {
        if ($RequireRootPath -and $Command -notmatch ('(?i)' + [regex]::Escape($RequireRootPath))) {
            Write-Host "[RUNNER] Blocked potentially destructive command: $Command"
            return
        }
    }

    Write-Host "[RUNNER] $Command"
    Invoke-Expression $Command
}

# ------------------ CONFIRM ACTION ------------------
function Confirm-Action {
    param(
        [string]$Kind,
        [string]$Detail
    )

    if (-not $ConfirmRiskyActions) { return $true }
    $resp = Read-Host "Approve $Kind? $Detail (y/n)"
    return ($resp -eq "y")
}

# ------------------ EXECUTION ------------------
$script:Context = @{}
foreach ($s in $plan.plan) {
    Write-Host "[EXEC] Action: $($s.action)"
    if ($s.action -match '^READ_FILE\|(.+)$') {
        Read-File -Path $matches[1]
        continue
    }

    if ($s.action -match '(?s)^WRITE_FILE\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "WRITE_FILE" -Detail $matches[1])) { exit }
        Write-File -Path $matches[1] -Spec $matches[2]
        continue
    }

    if ($s.action -match '(?s)^RUN_COMMAND\|(.+)$') {
        if (-not (Confirm-Action -Kind "RUN_COMMAND" -Detail $matches[1])) { exit }
        Run-Command -Command $matches[1]
        continue
    }

    Write-Host "[EXEC] Unhandled action: $($s.action)"
}

Write-Host "`n[AGENT] Done."


