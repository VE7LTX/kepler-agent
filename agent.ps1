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
      "action": "READ_FILE|<path> or READ_PART|<path>|<start>|<count> or WRITE_FILE|<path>|<spec> or APPEND_FILE|<path>|<text> or WRITE_PATCH|<path>|<diff> or RUN_COMMAND|<command> or LIST_DIR|<path> or FIND_FILES|<glob> or SEARCH_TEXT|<pattern>|<path> or FOR_EACH|<list_key>|<action_template> or BUILD_REPORT|<glob>|<start>|<count>|<outpath>|<patterns> or CREATE_DIR|<path> or DELETE_FILE|<path> or DELETE_DIR|<path> or MOVE_ITEM|<src>|<dest> or COPY_ITEM|<src>|<dest> or RENAME_ITEM|<src>|<dest> or VERIFY_PATH|<path>",
      "expects": "string"
    }
  ]
}

Rules:
- Provide a brief thinking_summary (2-4 short bullets). Do NOT include chain-of-thought.
- Plan should be minimal and ordered.
- Prefer LIST_DIR or FIND_FILES to discover files, then READ_FILE/READ_PART before WRITE_FILE when editing an existing file.
- For multi-file tasks, use FOR_EACH with a list key from LIST_DIR or FIND_FILES.
- Avoid destructive commands.
- Use absolute Windows paths or workspace-relative paths under C:\agent only.
- Do not use placeholders like "<path>" or "/path/to/...".
- Do not use Unix-style paths (e.g., /home/user).
- WRITE_FILE spec must be actual intended file contents or clear instructions, not metadata like "text/plain".
- Actions must be single-line; if content needs newlines, use \n escapes in the spec.
- Output must be valid JSON with no stray text, extra numbers, or trailing commas.
- Do not include raw newlines inside action strings; use \\n escapes only.
- Respect any directory constraints explicitly stated in the goal.
- Allowed actions only: READ_FILE, READ_PART, WRITE_FILE, APPEND_FILE, WRITE_PATCH, RUN_COMMAND, LIST_DIR, FIND_FILES, SEARCH_TEXT, FOR_EACH, BUILD_REPORT, CREATE_DIR, DELETE_FILE, DELETE_DIR, MOVE_ITEM, COPY_ITEM, RENAME_ITEM, VERIFY_PATH. Do not invent new action types.
- Do not invent control flow (GOTO/IF/LOOP). Use FOR_EACH only.
- Only use {item} and {index} placeholders inside FOR_EACH action templates.

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
        if ($p.PSObject.Properties.Name -contains 'action') {
            if ($p.action -match '^WRITE_FILE\|' -and $p.PSObject.Properties.Name -contains 'spec') {
                $parts = $p.action.Split('|',3)
                if ($parts.Length -eq 2 -and $p.spec) {
                    $p.action = $p.action + "|" + $p.spec
                    $normalizedActions = $true
                }
            }
            if ($p.action -match '^WRITE_PATCH\|' -and $p.PSObject.Properties.Name -contains 'patch') {
                $parts = $p.action.Split('|',3)
                if ($parts.Length -eq 2 -and $p.patch) {
                    $p.action = $p.action + "|" + $p.patch
                    $normalizedActions = $true
                }
            }
            if ($p.action -match '^APPEND_FILE\|' -and $p.PSObject.Properties.Name -contains 'text') {
                $parts = $p.action.Split('|',3)
                if ($parts.Length -eq 2 -and $p.text) {
                    $p.action = $p.action + "|" + $p.text
                    $normalizedActions = $true
                }
            }
        }
        if ($p.action -match '^FIND_FILES\|') {
            $glob = $p.action.Split('|',2)[1]
            if ($glob -match '[:\\\\/]') {
                $leaf = Split-Path -Leaf $glob
                if ($leaf) {
                    $p.action = "FIND_FILES|$leaf"
                    $normalizedActions = $true
                }
            }
        }
        if ($p.action -match "[\r\n]") {
            $p.action = ($p.action -replace "(\r\n|\r|\n)", "\\n")
            $normalizedActions = $true
        }
        if ($p.action -match '^(READ_FILE|WRITE_FILE|LIST_DIR|READ_PART|APPEND_FILE|WRITE_PATCH)\|') {
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
        if ($p.action -notmatch '^(READ_FILE|READ_PART|WRITE_FILE|APPEND_FILE|WRITE_PATCH|RUN_COMMAND|LIST_DIR|FIND_FILES|SEARCH_TEXT|FOR_EACH|BUILD_REPORT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
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
        if ($p.action -match '^(READ_FILE|WRITE_FILE|LIST_DIR|READ_PART|APPEND_FILE|WRITE_PATCH|SEARCH_TEXT|BUILD_REPORT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
            $pathIndex = 1
            if ($p.action -match '^SEARCH_TEXT\|') {
                $pathIndex = 2
            }
            if ($p.action -match '^BUILD_REPORT\|') {
                $pathIndex = 4
            }
            $path = $p.action.Split('|',6)[$pathIndex]
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
        if ($p.action -match '^FIND_FILES\|') {
            $glob = $p.action.Split('|',2)[1]
            if ($glob -match '[:\\\\/]') {
                $pathsValid = $false
                break
            }
        }
        if ($p.action -match '^FOR_EACH\|') {
            $parts = $p.action.Split('|',3)
            if ($parts.Length -lt 3) {
                $pathsValid = $false
                break
            }
            $tmpl = $parts[2]
            if ($tmpl -notmatch '^(READ_FILE|READ_PART|WRITE_FILE|APPEND_FILE|WRITE_PATCH|RUN_COMMAND|LIST_DIR|SEARCH_TEXT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
                $pathsValid = $false
                break
            }
            if ($tmpl -notmatch '\{item\}') {
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

# ------------------ VERIFY PATH ------------------
function Verify-Path {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[VERIFY] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[VERIFY] Invalid Unix-style path: $Path"
        return
    }
    if (Test-Path $Path) {
        Write-Host "[VERIFY] Exists: $Path"
    } else {
        Write-Host "[VERIFY] Missing: $Path"
    }
}

# ------------------ CREATE DIR ------------------
function Create-Dir {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[CREATE] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[CREATE] Invalid Unix-style path: $Path"
        return
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Write-Host "[CREATE] Directory: $Path"
}

# ------------------ DELETE FILE ------------------
function Delete-File {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[DELETE] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[DELETE] Invalid Unix-style path: $Path"
        return
    }
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force
        Write-Host "[DELETE] File: $Path"
    } else {
        Write-Host "[DELETE] Missing: $Path"
    }
}

# ------------------ DELETE DIR ------------------
function Delete-Dir {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[DELETE] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[DELETE] Invalid Unix-style path: $Path"
        return
    }
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
        Write-Host "[DELETE] Directory: $Path"
    } else {
        Write-Host "[DELETE] Missing: $Path"
    }
}

# ------------------ MOVE ITEM ------------------
function Move-ItemSafe {
    param(
        [string]$Source,
        [string]$Dest
    )

    $Source = Normalize-PathString -Path $Source
    $Dest = Normalize-PathString -Path $Dest
    if ($Source -match '<path>|/path/to' -or $Dest -match '<path>|/path/to') {
        Write-Host "[MOVE] Invalid placeholder path"
        return
    }
    if ($Source -match '^(?i)/home/|^/|\\?/' -or $Dest -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[MOVE] Invalid Unix-style path"
        return
    }
    if (-not (Test-Path $Source)) {
        Write-Host "[MOVE] Missing source: $Source"
        return
    }
    Move-Item -Path $Source -Destination $Dest -Force
    Write-Host "[MOVE] $Source -> $Dest"
}

# ------------------ COPY ITEM ------------------
function Copy-ItemSafe {
    param(
        [string]$Source,
        [string]$Dest
    )

    $Source = Normalize-PathString -Path $Source
    $Dest = Normalize-PathString -Path $Dest
    if ($Source -match '<path>|/path/to' -or $Dest -match '<path>|/path/to') {
        Write-Host "[COPY] Invalid placeholder path"
        return
    }
    if ($Source -match '^(?i)/home/|^/|\\?/' -or $Dest -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[COPY] Invalid Unix-style path"
        return
    }
    if (-not (Test-Path $Source)) {
        Write-Host "[COPY] Missing source: $Source"
        return
    }
    Copy-Item -Path $Source -Destination $Dest -Force
    Write-Host "[COPY] $Source -> $Dest"
}

# ------------------ RENAME ITEM ------------------
function Rename-ItemSafe {
    param(
        [string]$Source,
        [string]$Dest
    )

    $Source = Normalize-PathString -Path $Source
    $Dest = Normalize-PathString -Path $Dest
    if ($Source -match '<path>|/path/to' -or $Dest -match '<path>|/path/to') {
        Write-Host "[RENAME] Invalid placeholder path"
        return
    }
    if ($Source -match '^(?i)/home/|^/|\\?/' -or $Dest -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[RENAME] Invalid Unix-style path"
        return
    }
    if (-not (Test-Path $Source)) {
        Write-Host "[RENAME] Missing source: $Source"
        return
    }
    Rename-Item -Path $Source -NewName $Dest -Force
    Write-Host "[RENAME] $Source -> $Dest"
}

# ------------------ LIST DIR ------------------
function List-Dir {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[LISTER] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[LISTER] Invalid Unix-style path: $Path"
        return
    }
    if (-not (Test-Path $Path)) {
        Write-Host "[LISTER] Missing: $Path"
        return
    }

    $items = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 200 -ExpandProperty FullName
    $list = $items -join "`n"
    $script:Context["DIR:$Path"] = $list
    Write-Host "[LISTER] Listed $Path (max 200 files)"
}

# ------------------ FIND FILES ------------------
function Find-Files {
    param([string]$Glob)

    if (-not $Glob) {
        Write-Host "[FINDER] Missing glob"
        return
    }

    $items = Get-ChildItem -Path $RootDir -Recurse -File -Filter $Glob -ErrorAction SilentlyContinue | Select-Object -First 200 -ExpandProperty FullName
    $list = $items -join "`n"
    $script:Context["FIND:$Glob"] = $list
    Write-Host "[FINDER] Found files for '$Glob' (max 200)"
}

# ------------------ SEARCH TEXT ------------------
function Search-Text {
    param(
        [string]$Pattern,
        [string]$Path
    )

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[SEARCH] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[SEARCH] Invalid Unix-style path: $Path"
        return
    }
    if (-not (Test-Path $Path)) {
        Write-Host "[SEARCH] Missing: $Path"
        return
    }

    $results = Select-String -Path $Path -Pattern $Pattern -AllMatches -ErrorAction SilentlyContinue | Select-Object -First 200 | ForEach-Object {
        "{0}:{1}:{2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()
    }
    $list = $results -join "`n"
    $script:Context["SEARCH:$Pattern|$Path"] = $list
    Write-Host "[SEARCH] Searched $Path (max 200 matches)"
}

# ------------------ READ PART ------------------
function Read-Part {
    param(
        [string]$Path,
        [int]$Start,
        [int]$Count
    )

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

    if ($Start -lt 1) { $Start = 1 }
    if ($Count -lt 1) { $Count = 50 }
    $skip = $Start - 1
    $lines = Get-Content -Path $Path | Select-Object -Skip $skip -First $Count
    $text = $lines -join "`n"
    $key = "PART:{0}:{1}:{2}" -f $Path, $Start, $Count
    $script:Context[$key] = $text
    Write-Host "[READER] Read part of $Path (lines $Start-$($Start + $Count - 1))"
}

# ------------------ APPEND FILE ------------------
function Append-File {
    param(
        [string]$Path,
        [string]$Text
    )

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[APPEND] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[APPEND] Invalid Unix-style path: $Path"
        return
    }

    $Text = $Text -replace "\\n", "`n"
    Add-Content -Path $Path -Value $Text -Encoding utf8
    Write-Host "[APPEND] Appended to $Path"
}

# ------------------ WRITE PATCH ------------------
function Write-Patch {
    param(
        [string]$Path,
        [string]$Diff
    )

    $Path = Normalize-PathString -Path $Path
    if ($Path -match '<path>|/path/to') {
        Write-Host "[PATCH] Invalid placeholder path: $Path"
        return
    }
    if ($Path -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[PATCH] Invalid Unix-style path: $Path"
        return
    }
    if (-not (Test-Path $Path)) {
        Write-Host "[PATCH] Missing: $Path"
        return
    }

    $Diff = $Diff -replace "\\n", "`n"
    $tmp = Join-Path $RootDir "_tmp_patch.diff"
    Set-Content -Path $tmp -Value $Diff -Encoding utf8

    if (Get-Command git -ErrorAction SilentlyContinue) {
        git apply -- "$tmp" | Out-Null
        Write-Host "[PATCH] Applied via git"
    } elseif (Get-Command patch -ErrorAction SilentlyContinue) {
        patch -p0 --input "$tmp" | Out-Null
        Write-Host "[PATCH] Applied via patch"
    } else {
        Write-Host "[PATCH] No patch tool available"
    }
}

# ------------------ BUILD REPORT ------------------
function Build-Report {
    param(
        [string]$Glob,
        [int]$Start,
        [int]$Count,
        [string]$OutPath,
        [string]$Patterns
    )

    $OutPath = Normalize-PathString -Path $OutPath
    if ($OutPath -match '<path>|/path/to') {
        Write-Host "[REPORT] Invalid placeholder path: $OutPath"
        return
    }
    if ($OutPath -match '^(?i)/home/|^/|\\?/') {
        Write-Host "[REPORT] Invalid Unix-style path: $OutPath"
        return
    }

    if ($Start -lt 1) { $Start = 1 }
    if ($Count -lt 1) { $Count = 50 }
    $patternsList = @()
    if ($Patterns) {
        $patternsList = $Patterns.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    $report = @()
    $files = Get-ChildItem -Path $RootDir -Recurse -File -Filter $Glob -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $lines = Get-Content -Path $f.FullName | Select-Object -Skip ($Start - 1) -First $Count
        $text = $lines -join "`n"
        $found = @()
        foreach ($pat in $patternsList) {
            if ($text -match [regex]::Escape($pat)) {
                $found += $pat
            }
        }
        $report += "File: $($f.FullName)"
        $report += "Lines: $Start-$($Start + $Count - 1)"
        if ($found.Count -gt 0) {
            $report += ("Found: " + ($found -join ", "))
        } else {
            $report += "Found: none"
        }
        $report += ""
    }

    $content = $report -join "`n"
    Set-Content -Path $OutPath -Value $content -Encoding utf8
    Write-Host "[REPORT] Wrote $OutPath"
}

# ------------------ FOR EACH ------------------
function Invoke-ForEachAction {
    param(
        [string]$ListKey,
        [string]$Template
    )

    $listText = $null
    foreach ($k in @($ListKey, "FIND:$ListKey", "DIR:$ListKey")) {
        if ($script:Context.ContainsKey($k)) {
            $listText = $script:Context[$k]
            break
        }
    }

    if (-not $listText) {
        Write-Host "[FOREACH] Missing list: $ListKey"
        return
    }

    $items = $listText -split "`n" | Where-Object { $_ -and $_.Trim() -ne "" }
    $idx = 1
    foreach ($item in $items) {
        $action = $Template.Replace("{item}", $item).Replace("{index}", $idx)
        Execute-Action -Action $action
        $idx++
    }
}

# ------------------ EXECUTE ACTION ------------------
function Execute-Action {
    param([string]$Action)

    Write-Host "[EXEC] Action: $Action"
    if ($Action -match '^READ_FILE\|(.+)$') {
        Read-File -Path $matches[1]
        return
    }

    if ($Action -match '^READ_PART\|(.+?)\|(\d+)\|(\d+)$') {
        Read-Part -Path $matches[1] -Start ([int]$matches[2]) -Count ([int]$matches[3])
        return
    }

    if ($Action -match '^LIST_DIR\|(.+)$') {
        List-Dir -Path $matches[1]
        return
    }

    if ($Action -match '^FIND_FILES\|(.+)$') {
        Find-Files -Glob $matches[1]
        return
    }

    if ($Action -match '^SEARCH_TEXT\|(.+?)\|(.+)$') {
        Search-Text -Pattern $matches[1] -Path $matches[2]
        return
    }

    if ($Action -match '(?s)^WRITE_FILE\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "WRITE_FILE" -Detail $matches[1])) { exit }
        Write-File -Path $matches[1] -Spec $matches[2]
        return
    }

    if ($Action -match '(?s)^APPEND_FILE\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "APPEND_FILE" -Detail $matches[1])) { exit }
        Append-File -Path $matches[1] -Text $matches[2]
        return
    }

    if ($Action -match '(?s)^WRITE_PATCH\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "WRITE_PATCH" -Detail $matches[1])) { exit }
        Write-Patch -Path $matches[1] -Diff $matches[2]
        return
    }

    if ($Action -match '(?s)^RUN_COMMAND\|(.+)$') {
        if (-not (Confirm-Action -Kind "RUN_COMMAND" -Detail $matches[1])) { exit }
        Run-Command -Command $matches[1]
        return
    }

    if ($Action -match '^FOR_EACH\|(.+?)\|(.+)$') {
        Invoke-ForEachAction -ListKey $matches[1] -Template $matches[2]
        return
    }

    if ($Action -match '^BUILD_REPORT\|([^|]+)\|(\d+)\|(\d+)\|([^|]+)\|(.+)$') {
        if (-not (Confirm-Action -Kind "BUILD_REPORT" -Detail $matches[4])) { exit }
        Build-Report -Glob $matches[1] -Start ([int]$matches[2]) -Count ([int]$matches[3]) -OutPath $matches[4] -Patterns $matches[5]
        return
    }

    if ($Action -match '^CREATE_DIR\|(.+)$') {
        if (-not (Confirm-Action -Kind "CREATE_DIR" -Detail $matches[1])) { exit }
        Create-Dir -Path $matches[1]
        return
    }

    if ($Action -match '^DELETE_FILE\|(.+)$') {
        if (-not (Confirm-Action -Kind "DELETE_FILE" -Detail $matches[1])) { exit }
        Delete-File -Path $matches[1]
        return
    }

    if ($Action -match '^DELETE_DIR\|(.+)$') {
        if (-not (Confirm-Action -Kind "DELETE_DIR" -Detail $matches[1])) { exit }
        Delete-Dir -Path $matches[1]
        return
    }

    if ($Action -match '^MOVE_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "MOVE_ITEM" -Detail $matches[1])) { exit }
        Move-ItemSafe -Source $matches[1] -Dest $matches[2]
        return
    }

    if ($Action -match '^COPY_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "COPY_ITEM" -Detail $matches[1])) { exit }
        Copy-ItemSafe -Source $matches[1] -Dest $matches[2]
        return
    }

    if ($Action -match '^RENAME_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "RENAME_ITEM" -Detail $matches[1])) { exit }
        Rename-ItemSafe -Source $matches[1] -Dest $matches[2]
        return
    }

    if ($Action -match '^VERIFY_PATH\|(.+)$') {
        Verify-Path -Path $matches[1]
        return
    }

    Write-Host "[EXEC] Unhandled action: $Action"
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
    Execute-Action -Action $s.action
}

Write-Host "`n[AGENT] Done."


