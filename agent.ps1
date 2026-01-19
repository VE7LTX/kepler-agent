# ============================================================
# agent.ps1 (Windows PowerShell 5.1 SAFE)
# Dual-model autonomous agent
#
# Planner : codellama:13b-instruct (first pass)
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
$PlannerModel = "qwen2:7b-instruct"
$WriterModel  = "codellama:7b-instruct"

$PlannerNumCtx   = 4096
$PlannerPredict  = 900
$PlannerTemp     = 0.0

$WriterNumCtx    = 4096
$WriterPredict   = 2400
$WriterTemp      = 0.15

$MaxPlanIterations = 0
$MaxPlanMinutes    = 0
$RequireConfidence = 0.75
$PlannerFallbacks = @(
    @{ name = "codellama:13b-instruct"; temp = 0.0 },
    @{ name = "qwen2:7b-instruct"; temp = 0.0 },
    @{ name = "mistral:7b-instruct"; temp = 0.0 },
    @{ name = "deepseek-coder:6.7b-instruct"; temp = 0.0 }
)
$PlannerFallbackIndex = 0
$PlannerRejectStreak = 0
$EscalateAfterRejects = 2
$PlannerFirstPassModel = "codellama:13b-instruct"
$GoalSummaryModel = "qwen2:7b-instruct"
$FailureReflectModel = "phi3:mini"
$StepCheckModel = "phi3:mini"
$EnableFailureReflection = $true
$EnableStepChecks = $true

$EffectiveMaxIterations = $MaxPlanIterations
if ($EffectiveMaxIterations -le 0) { $EffectiveMaxIterations = [int]::MaxValue }

$ConfirmOncePerTask  = $true
$ConfirmRiskyActions = $true
$ConfirmLowConfidence = $true
$ApprovalMode = "step"
$script:ReplanRequested = $false
$script:UserFeedback = $null
$script:RejectedAction = $null

$WriterFallbacks = @(
    "codellama:7b-instruct",
    "codellama:13b-instruct"
)

$OllamaTagsApi = "http://localhost:11434/api/tags"
$OllamaGenApi  = "http://localhost:11434/api/generate"

$DebugLogPath = "C:\agent\agent-debug.log"
$DebugLogMaxChars = 2000
$DebugLogFull = $true
$DebugLogPretty = $true
$DebugVerbose = $true
$RequireJsonTags = $true
$EnableSpinner = $true
$RootDir = "C:\agent\"
$LastModelError = $null
$ModelRetryDelaySeconds = 8
$AgentName = "Kepler"
$AgentBackstory = "Kepler is a local Ollama-powered agent orchestrated by a PowerShell runner. It plans in strict JSON, validates actions, and executes only within C:\\agent\\ with human approval."

if (Test-Path $DebugLogPath) {
    Clear-Content -Path $DebugLogPath
} else {
    "" | Out-File -FilePath $DebugLogPath -Encoding utf8
}

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
    $clean = $Text
    if (-not $DebugLogFull) {
        $flat = $clean -replace "(\r\n|\r|\n)", "\n"
        if ($flat.Length -gt $DebugLogMaxChars) {
            $clean = $flat.Substring(0, $DebugLogMaxChars) + "...[truncated]"
        }
    }
    if ($DebugLogPretty) {
        $ts = (Get-Date).ToString("s")
        Add-Content -Path $DebugLogPath -Value ("[{0}] {1}:" -f $ts, $Label)    
        $lines = ($clean -split "\r\n|\r|\n") | Where-Object { $_ -ne "" }      
        foreach ($line in $lines) {
            Add-Content -Path $DebugLogPath -Value ("  {0}" -f $line)
        }
        return
    }
    $clean = $clean -replace "(\r\n|\r|\n)", "\n"
    Log-Debug ("{0}: {1}" -f $Label, $clean)
}

function Log-Trace {
    param(
        [string]$Where,
        [string]$Message
    )
    if (-not $DebugVerbose) { return }
    if (-not $Message) { $Message = "<empty>" }
    Log-Debug ("TRACE [{0}] {1}" -f $Where, $Message)
}

function Log-PlanDiff {
    param(
        [string[]]$OldActions,
        [string[]]$NewActions,
        [int]$Iteration
    )
    if (-not $OldActions -or -not $NewActions) { return }
    $diff = Compare-Object -ReferenceObject $OldActions -DifferenceObject $NewActions
    if (-not $diff) { return }
    Log-Debug ("Plan diff (iteration {0}):" -f $Iteration)
    foreach ($d in $diff) {
        $kind = if ($d.SideIndicator -eq '=>') { "added" } else { "removed" }
        Log-Debug ("  {0}: {1}" -f $kind, $d.InputObject)
    }
}

# ------------------ GOAL RESTATEMENT ------------------
function Build-GoalRestatement {
    param([string]$Text)
@"
Summarize the goal into WHO/WHAT/WHEN/WHERE/WHY as short bullet points.
Return plain text only, 4-6 bullets, no chain-of-thought.

AGENT IDENTITY:
- Name: $AgentName
- Backstory: $AgentBackstory

GOAL:
$Text
"@
}

function Build-FailureReflectPrompt {
    param(
        [string]$Reason,
        [string]$Detail,
        [string]$BadOutput
    )
@"
You are a strict JSON plan reviewer. Provide a short, concrete diagnostic summary.

Rules:
- No chain-of-thought.
- Use plain text only.
- Only reference REJECT_REASON, REJECT_DETAIL, and BAD_OUTPUT. Do not invent new requirements.
- If REJECT_DETAIL is empty, only cite errors visible in BAD_OUTPUT.
- Do not suggest adding tools, files, or steps unless the BAD_OUTPUT already attempted them.
- Include sections:
  DIAGNOSIS: 2-4 bullets
  FIX_HINTS: 2-4 bullets
  DO_NOT: 1-3 bullets

GOAL:
$Goal

REJECT_REASON:
$Reason

REJECT_DETAIL:
$Detail

BAD_OUTPUT (truncated):
$(Truncate-Text -Text $BadOutput -Max 1200)
"@
}

function Get-GoalSummary {
    $promptText = Build-GoalRestatement -Text $Goal
    Log-Debug-Raw -Label "Goal restatement prompt" -Text $promptText
    if (Get-Command Invoke-Ollama-Spinner -ErrorAction SilentlyContinue) {
        $script:LastGoalSummaryModel = $GoalSummaryModel
        $summary = Invoke-Ollama-Spinner `
            -Model $GoalSummaryModel `
            -Prompt $promptText `
            -System "Return plain text only." `
            -Options @{
                num_ctx     = $PlannerNumCtx
                num_predict = 200
                temperature = 0.1
            } `
            -Label "Goal summary"
    } else {
        $script:LastGoalSummaryModel = $GoalSummaryModel
        $body = @{
            model   = $GoalSummaryModel
            prompt  = $promptText
            system  = "Return plain text only."
            options = @{
                num_ctx     = $PlannerNumCtx
                num_predict = 200
                temperature = 0.1
            }
            stream  = $false
        }
        $summary = (Invoke-RestMethod `
            -Uri $OllamaGenApi `
            -Method Post `
            -ContentType "application/json" `
            -Body ($body | ConvertTo-Json -Depth 10) `
            -TimeoutSec 600
        ).response
    }
    Log-Debug-Raw -Label "Goal restatement response" -Text $summary
    $summary
}

function Get-FailureReflection {
    param(
        [string]$Reason,
        [string]$Detail,
        [string]$BadOutput
    )
    if (-not $EnableFailureReflection) { return $null }
    $promptText = Build-FailureReflectPrompt -Reason $Reason -Detail $Detail -BadOutput $BadOutput
    Log-Debug-Raw -Label "Failure reflection prompt" -Text $promptText
    $script:LastFailureReflectionModel = $FailureReflectModel
    $response = Invoke-Ollama-Spinner `
        -Model $FailureReflectModel `
        -Prompt $promptText `
        -System "Return plain text only. No chain-of-thought." `
        -Options @{
            num_ctx     = 2048
            num_predict = 400
            temperature = 0.1
        } `
        -Label "Failure reflection"
    if ($response) {
        Log-Debug-Raw -Label "Failure reflection response" -Text $response
        Write-Host ("[AGENT] Failure reflection (model: {0}):" -f $script:LastFailureReflectionModel)
        $response | ForEach-Object { Write-Host $_ }
        return $response
    }
    return $null
}

function Add-Failure {
    param([string]$Reason)
    if (-not $Reason) { return }
    $FailureMemory.Add($Reason)
    Log-Debug ("Failure: {0}" -f $Reason)
    if ($FailureMemory.Count -gt 8) {
        $FailureMemory.RemoveAt(0)
    }
}

function Set-LastReject {
    param(
        [string]$Reason,
        [string]$BadOutput,
        [string]$Detail
    )
    $script:LastRejectReason = $Reason
    $script:LastBadOutput = $BadOutput
    $script:LastRejectDetail = $Detail
}

function Truncate-Text {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return $Text }
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max) + "...[truncated]"
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
$FailureMemory = New-Object System.Collections.Generic.List[string]
$GoalRestatement = Get-GoalSummary
$LastBadOutput = $null
$LastRejectReason = $null
$LastRejectDetail = $null
$FailureHints = $null

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

# ------------------ MODEL ETA ------------------
function Get-ModelEtaSeconds {
    param(
        [string]$Model,
        [hashtable]$Options
    )
    if (-not $Model) { return 0 }
    $m = $Model.ToLowerInvariant()
    $base = 30
    if ($m -match 'phi3') { $base = 8 }
    elseif ($m -match 'qwen2') { $base = 35 }
    elseif ($m -match 'mistral') { $base = 40 }
    elseif ($m -match 'deepseek') { $base = 55 }
    elseif ($m -match 'codellama:13b') { $base = 120 }
    elseif ($m -match 'codellama:7b') { $base = 45 }
    $predict = 0
    if ($Options -and $Options.ContainsKey("num_predict")) {
        $predict = [int]$Options.num_predict
    }
    if ($predict -gt 0) {
        $base += [int][Math]::Ceiling($predict / 200)
    }
    return $base
}

# ------------------ OLLAMA CALL (SPINNER) ------------------
function Invoke-Ollama-Spinner {
    param(
        [string]$Model,
        [string]$Prompt,
        [string]$System,
        [hashtable]$Options,
        [string]$Label = "Model"
    )
    Log-Trace -Where "Invoke-Ollama-Spinner" -Message ("label='{0}' model='{1}' prompt_len={2} system_len={3} opts='{4}'" -f $Label, $Model, ($Prompt.Length), ($System.Length), ($Options | ConvertTo-Json -Compress))
    $eta = Get-ModelEtaSeconds -Model $Model -Options $Options
    if ($eta -gt 0) {
        Write-Host ("[AGENT] {0} model: {1} (est ~{2}s)" -f $Label, $Model, $eta)
    } else {
        Write-Host ("[AGENT] {0} model: {1}" -f $Label, $Model)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $EnableSpinner) {
        return Invoke-Ollama -Model $Model -Prompt $Prompt -System $System -Options $Options
    }

    $job = Start-Job -ScriptBlock {
        param($uri, $model, $prompt, $system, $options)
        $body = @{
            model   = $model
            prompt  = $prompt
            system  = $system
            options = $options
            stream  = $false
        }
        (Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -ContentType "application/json" `
            -Body ($body | ConvertTo-Json -Depth 10) `
            -TimeoutSec 600
        ).response
    } -ArgumentList $OllamaGenApi, $Model, $Prompt, $System, $Options

    $frames = @("|","/","-","\\")
    $idx = 0
    while ($job.State -eq "Running") {
        Write-Host -NoNewline ("`r[AGENT] {0} {1}" -f $Label, $frames[$idx % $frames.Count])
        Start-Sleep -Milliseconds 200
        $idx++
    }
    Write-Host -NoNewline ("`r[AGENT] {0} done.   " -f $Label)
    Write-Host ""

    try {
        $result = Receive-Job -Job $job -ErrorAction Stop
    } catch {
        Remove-Job -Job $job -Force | Out-Null
        $msg = $_.Exception.Message
        $script:LastModelError = $msg
        $sw.Stop()
        Log-Debug ("{0} response time: {1:N2}s" -f $Label, $sw.Elapsed.TotalSeconds)
        Write-Host "[AGENT] Model call failed: $msg"
        Log-Debug ("Model call failed: {0}" -f $msg)
        return $null
    }
    Remove-Job -Job $job -Force | Out-Null
    $sw.Stop()
    Write-Host ("[AGENT] {0} model: {1}" -f $Label, $Model)
    Write-Host ("[AGENT] {0} response time: {1:N2}s" -f $Label, $sw.Elapsed.TotalSeconds)
    Log-Debug ("{0} response time: {1:N2}s" -f $Label, $sw.Elapsed.TotalSeconds)
    $result
}

# ------------------ JSON EXTRACT ------------------
function Extract-Json {
    param([string]$Text)
    if (-not $Text) { return $null }
    $tagMatch = [regex]::Match($Text, "<json>(.*?)</json>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($tagMatch.Success) {
        $inner = $tagMatch.Groups[1].Value
        $inner = $inner.Trim()
        if ($inner.StartsWith("{") -and $inner.EndsWith("}")) {
            return $inner
        }
    }
    if ($RequireJsonTags) { return $null }
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
    $fallbackIndex = $PlannerFallbackIndex
    if ($fallbackIndex -lt ($PlannerFallbacks.Count - 1)) {
        $fallbackIndex++
    }
    $repairModel = $PlannerFallbacks[$fallbackIndex].name
    $repairPrompt = @"
Fix the following output into valid JSON that matches the required schema.
Rules:
- Output JSON only, no commentary, no markdown.
- Do not add any extra keys beyond the schema.
- Ensure all strings are double-quoted.
- Do not include stray numbers or trailing commas.
- Wrap the JSON in <json>...</json> tags.

SCHEMA:
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
      "action": "string",
      "expects": "string"
    }
  ]
}

INPUT:
$Text
"@
    Log-Debug-Raw -Label "Repair prompt" -Text $repairPrompt
    Invoke-Ollama-Spinner `
        -Model $repairModel `
        -Prompt $repairPrompt `
        -System "Return ONLY <json>...</json>. Any other text is invalid." `
        -Options @{
            num_ctx     = $PlannerNumCtx
            num_predict = $PlannerPredict
            temperature = 0.0
        } `
        -Label "Repair"
}

# ------------------ PATH NORMALIZE ------------------
function Normalize-PathString {
    param([string]$Path)

    if (-not $Path) { return $Path }
    Log-Trace -Where "Normalize-PathString" -Message ("in='{0}'" -f $Path)
    $p = $Path -replace '/', '\'
    if ($p -match '^[A-Za-z]:\\\\+') {
        $p = $p -replace '^[A-Za-z]:\\\\+', { param($m) $m.Value.Substring(0,3) }
    } elseif ($p -match '^\\\\\\\\') {
        $p = $p -replace '^\\\\\\\\+', '\\\\'
    }
    $p
}

# ------------------ JSON FENCE STRIP ------------------
function Strip-JsonFences {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = $Text.Trim()
    if ($t -match '^```') {
        $t = [regex]::Replace($t, '^```[a-zA-Z]*\s*', '', 'Singleline')
        $t = [regex]::Replace($t, '```$', '', 'Singleline')
        return $t.Trim()
    }
    $Text
}

# ------------------ PLAN PROMPT ------------------
function Build-PlanPrompt {
    function Get-ActionNamesFromText {
        param([string]$Text)
        if (-not $Text) { return @() }
        $matches = [regex]::Matches($Text, '"action"\s*:\s*"(.*?)"')
        $names = New-Object System.Collections.Generic.HashSet[string]
        foreach ($m in $matches) {
            $action = $m.Groups[1].Value
            $m2 = [regex]::Match($action, '^([A-Z_]+)\|')
            if ($m2.Success) {
                $names.Add($m2.Groups[1].Value) | Out-Null
            }
        }
        return @($names)
    }

    $failureNotes = ""
    if ($FailureMemory.Count -gt 0) {
        $failureNotes = "Recent failures to avoid:`n- " + ($FailureMemory -join "`n- ")
    }
    $badOutputNotes = ""
    if ($script:LastBadOutput) {
        $detail = ""
        if ($script:LastRejectDetail) {
            $detail = "`nDETAIL:`n" + $script:LastRejectDetail
        }
        $badOutputNotes = "BAD_OUTPUT:`n" + (Truncate-Text -Text $script:LastBadOutput -Max 2000) + "`nWHY_REJECTED:`n" + $script:LastRejectReason + $detail
    }
    $hintNotes = ""
    if ($FailureHints) {
        $hintNotes = "RETRY_HINTS:`n" + $FailureHints
    }
    $goalNotes = ""
    if ($GoalRestatement) {
        $goalNotes = ($GoalRestatement -join "`n")
    }
    $userNotes = ""
    if ($script:UserFeedback) {
        $userNotes = "USER_FEEDBACK:`n" + $script:UserFeedback
    }

    $coreRules = @(
        "Provide a brief thinking_summary (2-4 short bullets). Do NOT include chain-of-thought.",
        "Plan should be minimal and ordered.",
        "Use absolute Windows paths or workspace-relative paths under C:\\agent only.",
        "Do not use Unix-style paths (e.g., /home/user).",
        "Do not use placeholders like <path> or /path/to/... .",
        "Do NOT use parent traversal (e.g., {item}\\.. or ..) in any path.",
        "Actions must be single-line; if content needs newlines, use \\n escapes in the spec.",
        "Each plan item must have only: step, action, expects.",
        "Allowed actions only: READ_FILE, READ_PART, WRITE_FILE, APPEND_FILE, WRITE_PATCH, RUN_COMMAND, LIST_DIR, FIND_FILES, SEARCH_TEXT, FOR_EACH, REPEAT, BUILD_REPORT, CREATE_DIR, DELETE_FILE, DELETE_DIR, MOVE_ITEM, COPY_ITEM, RENAME_ITEM, VERIFY_PATH.",
        "Do NOT use unknown actions (e.g., CREATE_FILE, READ_FIRST_LINES, READ_LINES, WRITE_REPORT, WRITE_TEXT, EXTRACT_COMMANDS, ANALYZE_CONTENT, IMPROVE_CODE).",
        "RUN_COMMAND must include a command after the pipe (RUN_COMMAND|<command>)."
    )

    $actionRules = @()
    $lastActions = Get-ActionNamesFromText -Text $script:LastBadOutput
    if ($lastActions.Count -eq 0) {
        $lastActions = @("RUN_COMMAND","WRITE_FILE","READ_FILE","FOR_EACH","REPEAT","LIST_DIR","FIND_FILES")
    }
    if ($lastActions -contains "RUN_COMMAND") {
        $actionRules += "Use PowerShell-native commands only; avoid sh, bash, seq, xargs, grep, awk, sed, cut, head, tail."
        $actionRules += "Do NOT invent cmdlets. If you need computation, write explicit PowerShell expressions inside RUN_COMMAND."
        $actionRules += "PowerShell variables must start with $. Do not omit $ in assignments or loops."
    }
    if ($lastActions -contains "FOR_EACH") {
        $actionRules += "FOR_EACH may only operate on existing files or directories discovered earlier in the plan."
        $actionRules += "Do NOT use FOR_EACH to create new directories or files."
        $actionRules += "{item} expands to a full absolute path from LIST_DIR/FIND_FILES. Do not treat it as a basename."
    }
    if ($lastActions -contains "REPEAT") {
        $actionRules += "REPEAT index is zero-based. Use {index} or {index:03d} for padding."
    }
    if ($lastActions -contains "WRITE_FILE") {
        $actionRules += "WRITE_FILE spec must be real content, not metadata or placeholders."
        $actionRules += "WRITE_FILE content must be in the action string after the second pipe; expects is not used to write files."
        $actionRules += "Example: WRITE_FILE|C:\\agent\\notes.txt|Hello from Kepler"
        $actionRules += "To create an empty file, use WRITE_FILE|<path>|EMPTY_FILE."
    }
    if ($lastActions -contains "LIST_DIR" -or $lastActions -contains "FIND_FILES") {
        $actionRules += "Do NOT combine discovery (FIND_FILES/LIST_DIR) with creation of new entities in the same step."
    }
    if ($lastActions -contains "READ_FILE") {
        $fileMentioned = ($Goal -match '(?i)\bfile\b|\\\w+\.txt|\.\w{2,4}')
        if (-not $fileMentioned) {
            $actionRules += "Do NOT use READ_FILE unless the goal mentions a file or a prior step created it."
        }
    }
    $rulesText = ($coreRules + $actionRules) -join "`n- "

@"
Return JSON ONLY inside <json>...</json> tags. Do not output anything outside the tags.
Use the exact template and fill in values. Do not add keys.

TEMPLATE:
<json>
{
  "goal": "",
  "thinking_summary": ["", ""],
  "reflection": {
    "issues_found": [""],
    "changes_made": [""],
    "confidence": 0.0
  },
  "ready": true,
  "plan": [
    {
      "step": 1,
      "action": "",
      "expects": ""
    }
  ]
}
</json>

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
      "action": "READ_FILE|<path> or READ_PART|<path>|<start>|<count> or WRITE_FILE|<path>|<spec> or APPEND_FILE|<path>|<text> or WRITE_PATCH|<path>|<diff> or RUN_COMMAND|<command> or LIST_DIR|<path> or FIND_FILES|<glob> or SEARCH_TEXT|<pattern>|<path> or FOR_EACH|<list_key>|<action_template> or REPEAT|<count>|<action_template> or BUILD_REPORT|<glob>|<start>|<count>|<outpath>|<patterns> or CREATE_DIR|<path> or DELETE_FILE|<path> or DELETE_DIR|<path> or MOVE_ITEM|<src>|<dest> or COPY_ITEM|<src>|<dest> or RENAME_ITEM|<src>|<dest> or VERIFY_PATH|<path>",
      "expects": "string"
    }
  ]
}

Rules:
- $rulesText

$failureNotes
$badOutputNotes
$hintNotes
$userNotes

AGENT IDENTITY:
Name: $AgentName
Backstory: $AgentBackstory

GOAL_RESTATEMENT:
$goalNotes

GOAL:
$Goal
"@
}

# ------------------ PLANNING LOOP ------------------
while ($true) {
    $start = Get-Date
    $plan = $null
    $script:ReplanRequested = $false
    $script:RejectedAction = $null
    $lastPlanActions = $null

    for ($i = 1; $i -le $EffectiveMaxIterations; $i++) {

    if ($MaxPlanMinutes -gt 0 -and (New-TimeSpan $start (Get-Date)).TotalMinutes -gt $MaxPlanMinutes) {
        throw "Planning timeout"
    }

    Write-Host "`n[AGENT] Planning iteration $i..."
    Log-Debug "Planning iteration $i"
    Log-Debug "-----"
    if ($script:LastRejectReason) {
        Write-Host ("[AGENT] Last failure: {0}" -f $script:LastRejectReason)
        if ($script:LastRejectDetail) {
            Write-Host ("[AGENT] Last failure detail: {0}" -f $script:LastRejectDetail)
        }
        if ($FailureHints) {
            Write-Host "[AGENT] Last failure hints:"
            $FailureHints | ForEach-Object { Write-Host $_ }
        }
    }

    if ($i -eq 1 -and $PlannerFirstPassModel) {
        $PlannerModel = $PlannerFirstPassModel
        Write-Host "[AGENT] Planner first-pass model: $PlannerModel"
        Log-Debug "Planner first-pass model: $PlannerModel"
    } elseif ($PlannerRejectStreak -ge $EscalateAfterRejects -and $PlannerFallbackIndex -lt ($PlannerFallbacks.Count - 1)) {
        $PlannerFallbackIndex++
        $PlannerRejectStreak = 0
        $PlannerModel = $PlannerFallbacks[$PlannerFallbackIndex].name
        $PlannerTemp = $PlannerFallbacks[$PlannerFallbackIndex].temp
        Write-Host "[AGENT] Switching planner model to $PlannerModel"
        Log-Debug "Switching planner model to $PlannerModel"
    }

    $planPrompt = Build-PlanPrompt
    Log-Debug-Raw -Label "Planner prompt" -Text $planPrompt
    $planSw = [Diagnostics.Stopwatch]::StartNew()
    $raw = Invoke-Ollama-Spinner `
        -Model $PlannerModel `
        -Prompt $planPrompt `
        -System "Return ONLY <json>...</json>. Any other text is invalid." `
        -Options @{
            num_ctx     = $PlannerNumCtx
            num_predict = $PlannerPredict
            temperature = $PlannerTemp
        } `
        -Label "Planner"
    $planSw.Stop()
    Log-Debug ("Planner response time: {0:N2}s" -f $planSw.Elapsed.TotalSeconds)
    if (-not $raw) {
        Write-Host "[AGENT] Reject: planner call failed"
        Log-Debug "Reject: planner call failed"
        Add-Failure "Planner call failed"
        Set-LastReject -Reason "Planner call failed" -BadOutput "" -Detail "Model returned empty response."
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
        Write-Host "[AGENT] Waiting $ModelRetryDelaySeconds seconds before retry..."
        Start-Sleep -Seconds $ModelRetryDelaySeconds
        if ($PlannerFallbackIndex -lt ($PlannerFallbacks.Count - 1)) {
            $PlannerFallbackIndex++
            $PlannerModel = $PlannerFallbacks[$PlannerFallbackIndex].name
            $PlannerTemp = $PlannerFallbacks[$PlannerFallbackIndex].temp
            Write-Host "[AGENT] Switching planner model after error to $PlannerModel"
            Log-Debug "Switching planner model after error to $PlannerModel"
        }
        continue
    }
    Log-Debug-Raw -Label "Planner raw" -Text $raw

    $rawClean = Strip-JsonFences -Text $raw
    if ($rawClean -ne $raw) {
        Log-Debug "Stripped JSON fences"
    }
    $json = Extract-Json $rawClean
    if (-not $json) {
        Write-Host "[AGENT] Reject: no JSON detected"
        Log-Debug "Reject: no JSON detected"
        Add-Failure "No JSON detected"
        Set-LastReject -Reason "No JSON detected" -BadOutput $rawClean -Detail "No <json>...</json> block found."
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
        continue
    }

    try {
        $candidate = $json | ConvertFrom-Json
    } catch {
        Write-Host "[AGENT] Reject: invalid JSON"
        Log-Debug "Reject: invalid JSON"
        Add-Failure "Invalid JSON"
        Set-LastReject -Reason "Invalid JSON" -BadOutput $rawClean -Detail "ConvertFrom-Json failed."
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
        $repaired = Repair-Json -Text $rawClean
        Log-Debug-Raw -Label "Planner repaired" -Text $repaired
        if ($repaired) {
            $repairedJson = Extract-Json $repaired
            if ($repairedJson) {
                try {
                    $candidate = $repairedJson | ConvertFrom-Json
                    Write-Host "[AGENT] Recovered: JSON repaired"
                    Log-Debug "Recovered: JSON repaired"
                    $PlannerRejectStreak = 0
                } catch {
                    $PlannerRejectStreak++
                    continue
                }
            } else {
                $PlannerRejectStreak++
                continue
            }
        } else {
            $PlannerRejectStreak++
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
            if ($glob -match '\s') {
                $glob = $glob.Split(' ')[0]
                if ($glob) {
                    $p.action = "FIND_FILES|$glob"
                    $normalizedActions = $true
                }
            }
            if ($glob -match '[:\\\\/]') {
                $leaf = Split-Path -Leaf $glob
                if ($leaf) {
                    $p.action = "FIND_FILES|$leaf"
                    $normalizedActions = $true
                }
            }
        }
        if ($p.action -match '^LIST_DIR\|.+\\\*\.[A-Za-z0-9]+$') {
            $glob = Split-Path -Leaf ($p.action.Split('|',2)[1])
            if ($glob) {
                $p.action = "FIND_FILES|$glob"
                $normalizedActions = $true
            }
        }
        if ($p.action -match '^FOR_EACH\|list_key=') {
            $p.action = $p.action -replace '^FOR_EACH\|list_key=', 'FOR_EACH|'
            $normalizedActions = $true
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

    $currentActions = $candidate.plan | ForEach-Object { $_.action }
    Log-PlanDiff -OldActions $lastPlanActions -NewActions $currentActions -Iteration $i
    $lastPlanActions = $currentActions

    $allActionsValid = $true
    $actionRejectDetail = $null
    foreach ($p in $candidate.plan) {
        $allowedKeys = @("step","action","expects")
        foreach ($name in $p.PSObject.Properties.Name) {
            if ($allowedKeys -notcontains $name) {
                $allActionsValid = $false
                $actionRejectDetail = "EXTRA_FIELDS: unexpected key '$name'."
                break
            }
        }
        if (-not $allActionsValid) { break }
        if (-not $p.PSObject.Properties.Name -contains "action") {
            $allActionsValid = $false
            $actionRejectDetail = "MISSING_ACTION: plan item missing action."
            break
        }
        if (-not $p.expects) {
            $p | Add-Member -NotePropertyName expects -NotePropertyValue "string" -Force
            $normalizedActions = $true
        }
        if ($p.action -notmatch '^FOR_EACH\|' -and $p.action -match '\{item\}') {
            $allActionsValid = $false
            $actionRejectDetail = "PLACEHOLDER_MISUSE: {item} used outside FOR_EACH."
            break
        }
        if ($p.action -match '^RUN_COMMAND$') {
            $allActionsValid = $false
            $actionRejectDetail = "RUN_COMMAND_MISSING: action must be RUN_COMMAND|<command>."
            break
        }
        if ($p.action -notmatch '^(READ_FILE|READ_PART|WRITE_FILE|APPEND_FILE|WRITE_PATCH|RUN_COMMAND|LIST_DIR|FIND_FILES|SEARCH_TEXT|FOR_EACH|REPEAT|BUILD_REPORT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
            $allActionsValid = $false
            $actionRejectDetail = "UNKNOWN_ACTION: '$($p.action)'."
            break
        }
        if ($p.action -match "[\r\n]") {
            $allActionsValid = $false
            $actionRejectDetail = "MULTILINE_ACTION: action must be single-line."
            break
        }
    }
    if (-not $allActionsValid) {
        Write-Host "[AGENT] Reject: invalid action format"
        $candidate.plan | ForEach-Object { Write-Host " - $($_.action)" }       
        Log-Debug "Reject: invalid action format"
        if ($actionRejectDetail) {
            Log-Debug ("Reject detail: {0}" -f $actionRejectDetail)
        }
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        Add-Failure "Invalid action format or extra fields"
        Set-LastReject -Reason "Invalid action format or extra fields" -BadOutput $rawClean -Detail $actionRejectDetail
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
        continue
    }
    $pathsValid = $true
    $pathRejectDetail = $null
    $findGlobs = New-Object System.Collections.Generic.HashSet[string]
    $dirLists = New-Object System.Collections.Generic.HashSet[string]
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
            if ($path -match '\.\.' ) {
                $pathsValid = $false
                $pathRejectDetail = "PATH_TRAVERSAL: '..' not allowed in path."
                break
            }
            if ($path -match '<path>|/path/to' -or $path -match '^(?i)/home/|^/|\\?/') {
                $pathsValid = $false
                $pathRejectDetail = "PLACEHOLDER_OR_UNIX_PATH: invalid placeholder or Unix-style path."
                break
            }
            if ($path -notmatch '^(?i)[A-Za-z]:\\|^\\\\|^\\.|^\\.\\') {
                $pathsValid = $false
                $pathRejectDetail = "NOT_ABSOLUTE: path is not absolute."
                break
            }
            if ($RequireRootPath -and ($path -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
                $pathsValid = $false
                $pathRejectDetail = "OUTSIDE_ROOT: path must stay under $RequireRootPath."
                break
            }
        }
        if ($p.action -match '^FIND_FILES\|') {
            $glob = $p.action.Split('|',2)[1]
            if ($glob -match '[:\\\\/]') {
                $pathsValid = $false
                $pathRejectDetail = "INVALID_GLOB: FIND_FILES glob must not include paths."
                break
            }
            $findGlobs.Add($glob) | Out-Null
        }
        if ($p.action -match '^LIST_DIR\|') {
            $dirPath = $p.action.Split('|',2)[1]
            $dirLists.Add($dirPath) | Out-Null
        }
        if ($p.action -match '^FOR_EACH\|') {
            $parts = $p.action.Split('|',3)
            if ($parts.Length -lt 3) {
                $pathsValid = $false
                break
            }
            $tmpl = $parts[2]
            $listKey = $parts[1]
            if ($listKey -notmatch '^(FIND:|DIR:)') {
                $pathsValid = $false
                $pathRejectDetail = "LIST_KEY_FORMAT: list key must be FIND:<glob> or DIR:<path>."
                break
            }
            if ($listKey -match '\s') {
                $pathsValid = $false
                $pathRejectDetail = "LIST_KEY_SPACES: list key must not contain spaces."
                break
            }
            if ($tmpl -notmatch '^(READ_FILE|READ_PART|WRITE_FILE|APPEND_FILE|WRITE_PATCH|RUN_COMMAND|LIST_DIR|SEARCH_TEXT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
                $pathsValid = $false
                $pathRejectDetail = "TEMPLATE_ACTION_INVALID: FOR_EACH template action is not allowed."
                break
            }
            if ($tmpl -match '^CREATE_DIR\|') {
                $pathsValid = $false
                $pathRejectDetail = "FOR_EACH_CREATE: creation must be explicit; do not create directories inside FOR_EACH."
                break
            }
            if ($tmpl -notmatch '\{item\}') {
                $pathsValid = $false
                $pathRejectDetail = "TEMPLATE_MISSING_ITEM: FOR_EACH template must include {item}."
                break
            }
            if ($listKey -match '^FIND:(.+)$') {
                $glob = $matches[1]
                if (-not $findGlobs.Contains($glob)) {
                    $pathsValid = $false
                    $pathRejectDetail = "MISSING_LIST: FIND list was not created earlier."
                    break
                }
            }
            if ($listKey -match '^DIR:(.+)$') {
                $dir = $matches[1]
                if (-not $dirLists.Contains($dir)) {
                    $pathsValid = $false
                    $pathRejectDetail = "MISSING_LIST: DIR list was not created earlier."
                    break
                }
            }
        }
        if ($p.action -match '^REPEAT\|') {
            $parts = $p.action.Split('|',3)
            if ($parts.Length -lt 3) {
                $pathsValid = $false
                break
            }
            $count = $parts[1]
            if ($count -notmatch '^\d+$') {
                $pathsValid = $false
                $pathRejectDetail = "REPEAT_COUNT: count must be an integer."
                break
            }
            $tmpl = $parts[2]
            if ($tmpl -notmatch '^(READ_FILE|READ_PART|WRITE_FILE|APPEND_FILE|WRITE_PATCH|RUN_COMMAND|LIST_DIR|SEARCH_TEXT|CREATE_DIR|DELETE_FILE|DELETE_DIR|MOVE_ITEM|COPY_ITEM|RENAME_ITEM|VERIFY_PATH)\|') {
                $pathsValid = $false
                $pathRejectDetail = "REPEAT_TEMPLATE_ACTION_INVALID: template action is not allowed."
                break
            }
            if ($tmpl -notmatch '\{index(:0+\d+d)?\}') {
                $pathsValid = $false
                $pathRejectDetail = "REPEAT_TEMPLATE_MISSING_INDEX: template must include {index}."
                break
            }
            $tmplParts = $tmpl.Split('|',4)
            $tmplAction = $tmplParts[0]
            $pathIdx = 1
            if ($tmplAction -eq "SEARCH_TEXT") { $pathIdx = 2 }
            if ($tmplParts.Length -gt $pathIdx) {
                $tmplPath = $tmplParts[$pathIdx]
                $tmplPath = [regex]::Replace($tmplPath, "\{index(:0+\d+d)?\}", "0")
                if ($tmplPath -match '<path>|/path/to' -or $tmplPath -match '^(?i)/home/|^/|\\?/') {
                    $pathsValid = $false
                    $pathRejectDetail = "PLACEHOLDER_OR_UNIX_PATH: invalid placeholder or Unix-style path."
                    break
                }
                if ($tmplPath -notmatch '^(?i)[A-Za-z]:\\|^\\\\|^\\.|^\\.\\') {
                    $pathsValid = $false
                    $pathRejectDetail = "NOT_ABSOLUTE: path is not absolute."
                    break
                }
                if ($RequireRootPath -and ($tmplPath -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
                    $pathsValid = $false
                    $pathRejectDetail = "OUTSIDE_ROOT: path must stay under $RequireRootPath."
                    break
                }
            }
        }
        if ($p.action -match '^RUN_COMMAND\|') {
            $cmd = $p.action.Substring("RUN_COMMAND|".Length)
            if ($cmd -match '(?i)\b(sh|bash|zsh|seq|xargs|grep|awk|sed|cut|head|tail)\b') {
                $pathsValid = $false
                $pathRejectDetail = "RUN_COMMAND_UNSUPPORTED: use PowerShell-native commands only."
                break
            }
            if ($cmd -match '(^|;)\s*[A-Za-z_]\w*\s*=') {
                $pathsValid = $false
                $pathRejectDetail = "RUN_COMMAND_MISSING_DOLLAR: PowerShell variables must start with '$'."
                break
            }
            $firstToken = ($cmd -split '\s+')[0]
            if ($firstToken -match '^[A-Za-z]+-[A-Za-z]') {
                $cmdInfo = Get-Command -Name $firstToken -ErrorAction SilentlyContinue
                if (-not $cmdInfo) {
                    $pathsValid = $false
                    $pathRejectDetail = "RUN_COMMAND_UNKNOWN_CMDLET: '$firstToken' is not a known PowerShell cmdlet."
                    break
                }
            }
            $absPaths = [regex]::Matches($cmd, '[A-Za-z]:\\[^"\\s]+')
            foreach ($m in $absPaths) {
                $candidatePath = $m.Value.TrimEnd(')',']','}',';',',','.')
                if ($RequireRootPath -and ($candidatePath -notmatch ('^(?i)' + [regex]::Escape($RequireRootPath)))) {
                    $pathsValid = $false
                    $pathRejectDetail = "RUN_COMMAND_OUTSIDE_ROOT: absolute path must stay under $RequireRootPath."
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
        if ($pathRejectDetail) {
            Log-Debug ("Reject detail: {0}" -f $pathRejectDetail)
        }
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        Add-Failure "Invalid path"
        Set-LastReject -Reason "Invalid path" -BadOutput $rawClean -Detail $pathRejectDetail
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
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
            $specTrim = $spec.Trim("'`"")
            if ($specTrim -ieq "EMPTY_FILE") { continue }
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
        Log-Debug "Reject detail: WRITE_FILE spec too short or contains placeholders."
        $candidate.plan | ForEach-Object { Log-Debug ("Action: {0}" -f $_.action) }
        Add-Failure "Invalid WRITE_FILE spec"
        Set-LastReject -Reason "Invalid WRITE_FILE spec" -BadOutput $rawClean -Detail "WRITE_FILE spec is too short or contains placeholders."
        $FailureHints = Get-FailureReflection -Reason $LastRejectReason -Detail $LastRejectDetail -BadOutput $LastBadOutput
        $PlannerRejectStreak++
        continue
    }
    if ($candidate.ready) {
        $PlannerRejectStreak = 0
        $plan = $candidate
        $FailureHints = $null
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

Write-Host "`nGOAL RESTATEMENT:"
$goalModelLabel = if ($script:LastGoalSummaryModel) { $script:LastGoalSummaryModel } else { "unknown" }
Write-Host ("[AGENT] Goal restatement model: {0}" -f $goalModelLabel)
$GoalRestatement | ForEach-Object { Write-Host $_ }

if ($plan.reflection -and $plan.reflection.confidence -ne $null) {
    Write-Host "`nCONFIDENCE: $($plan.reflection.confidence)"
}

    if ($ConfirmOncePerTask) {
        $resp = Read-Host "Approve plan? (a=all steps, s=step-by-step, n=cancel)"
        if ($resp -eq "a") {
            $ApprovalMode = "all"
        } elseif ($resp -eq "s") {
            $ApprovalMode = "step"
        } else {
            $script:RejectedAction = "Plan approval declined"
            $reason = Read-Host "Why decline the plan? (optional)"
            if ($reason) {
                $script:UserFeedback = $reason
                Log-Debug ("User feedback: {0}" -f $reason)
            }
            $script:ReplanRequested = $true
        }
    }

    if ($script:ReplanRequested) {
        $note = "User declined plan"
        Add-Failure $note
        Write-Host "[AGENT] Replanning based on user feedback..."
        continue
    }

    if ($ConfirmLowConfidence -and $plan.reflection -and $plan.reflection.confidence -lt $RequireConfidence) {
        $script:RejectedAction = "Low confidence"
        $script:UserFeedback = "Increase confidence: plan too uncertain."
        Log-Debug "User feedback: Increase confidence: plan too uncertain."
        $script:ReplanRequested = $true
        $note = "Low confidence: replanning"
        Add-Failure $note
        Write-Host "[AGENT] Low confidence. Replanning..."
        continue
    }

# ------------------ WRITE FILE ------------------
function Write-File {
    param([string]$Path, [string]$Spec)

    $Path = Normalize-PathString -Path $Path
    Log-Trace -Where "Write-File" -Message ("path='{0}' spec_len={1}" -f $Path, $Spec.Length)
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
    $specTrim = $Spec.Trim()
    if ($specTrim -ieq "EMPTY_FILE") {
        Log-Trace -Where "Write-File" -Message "EMPTY_FILE spec detected; writing empty file."
        New-Item -ItemType File -Path $Path -Force | Out-Null
        Write-Host "[AGENT] Writer model: none (EMPTY_FILE)"
        return
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

    $content = $null
    $script:LastWriterModel = $null
    foreach ($wm in $WriterFallbacks) {
        $content = Invoke-Ollama-Spinner `
            -Model $wm `
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
            } `
            -Label "Writer"

        if ($content -and $content.Trim().Length -ge 10) {
            $script:LastWriterModel = $wm
            break
        }
    }

    $clean = $content -replace '^\s*```.*?\n','' -replace '\n```$',''
    $clean | Out-File -FilePath $Path -Encoding utf8 -Force

    if ($script:LastWriterModel) {
        Write-Host ("[AGENT] Writer model: {0}" -f $script:LastWriterModel)
    }
    Write-Host "[WRITER] Wrote $Path"
}

# ------------------ READ FILE ------------------
function Read-File {
    param([string]$Path)

    $Path = Normalize-PathString -Path $Path
    Log-Trace -Where "Read-File" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Verify-Path" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Create-Dir" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Delete-File" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Delete-Dir" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Move-ItemSafe" -Message ("src='{0}' dest='{1}'" -f $Source, $Dest)
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
    Log-Trace -Where "Copy-ItemSafe" -Message ("src='{0}' dest='{1}'" -f $Source, $Dest)
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
    Log-Trace -Where "Rename-ItemSafe" -Message ("src='{0}' dest='{1}'" -f $Source, $Dest)
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
    Log-Trace -Where "List-Dir" -Message ("path='{0}'" -f $Path)
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
    Log-Trace -Where "Find-Files" -Message ("glob='{0}'" -f $Glob)

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
    Log-Trace -Where "Search-Text" -Message ("pattern='{0}' path='{1}'" -f $Pattern, $Path)
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
    Log-Trace -Where "Read-Part" -Message ("path='{0}' start={1} count={2}" -f $Path, $Start, $Count)
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
    Log-Trace -Where "Append-File" -Message ("path='{0}' text_len={1}" -f $Path, $Text.Length)
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
    Log-Trace -Where "Write-Patch" -Message ("path='{0}' diff_len={1}" -f $Path, $Diff.Length)
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
    Log-Trace -Where "Build-Report" -Message ("glob='{0}' start={1} count={2} out='{3}' patterns='{4}'" -f $Glob, $Start, $Count, $OutPath, $Patterns)
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
    Log-Trace -Where "Invoke-ForEachAction" -Message ("list='{0}' template='{1}'" -f $ListKey, $Template)

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
    $idx = 0
    foreach ($item in $items) {
        $action = $Template.Replace("{item}", $item).Replace("{index}", $idx)
        $action = [regex]::Replace($action, "\{index:0+(\d+)d\}", {
            param($m)
            $width = [int]$m.Groups[1].Value
            $idx.ToString(("D{0}" -f $width))
        })
        Execute-Action -Action $action
        $idx++
    }
}

function Invoke-RepeatAction {
    param(
        [int]$Count,
        [string]$Template
    )
    Log-Trace -Where "Invoke-RepeatAction" -Message ("count={0} template='{1}'" -f $Count, $Template)
    for ($idx = 0; $idx -lt $Count; $idx++) {
        $action = $Template.Replace("{index}", $idx)
        $action = [regex]::Replace($action, "\{index:0+(\d+)d\}", {
            param($m)
            $width = [int]$m.Groups[1].Value
            $idx.ToString(("D{0}" -f $width))
        })
        Execute-Action -Action $action
    }
}

# ------------------ EXECUTE ACTION ------------------
function Execute-Action {
    param([string]$Action)

    Log-Trace -Where "Execute-Action" -Message ("action='{0}'" -f $Action)
    if ($EnableStepChecks) {
        $checkPrompt = @"
Provide a short, visible pre-step check.

Rules:
- No chain-of-thought.
- Plain text only.
- Include sections:
  CHECKLIST: 2-4 bullets
  WATCH_FOR: 1-3 bullets

GOAL:
$Goal

NEXT_ACTION:
$Action
"@
        Log-Debug-Raw -Label "Step check prompt" -Text $checkPrompt
        $script:LastStepCheckModel = $StepCheckModel
        $check = Invoke-Ollama-Spinner `
            -Model $StepCheckModel `
            -Prompt $checkPrompt `
            -System "Return plain text only. No chain-of-thought." `
            -Options @{
                num_ctx     = 2048
                num_predict = 300
                temperature = 0.1
            } `
            -Label "Step check"
        if ($check) {
            Log-Debug-Raw -Label "Step check response" -Text $check
            Write-Host ("[AGENT] Step check (model: {0}):" -f $script:LastStepCheckModel)
            $check | ForEach-Object { Write-Host $_ }
        }
    }

    Write-Host "[EXEC] Action: $Action"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($Action -match '^READ_FILE\|(.+)$') {
        Read-File -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^READ_PART\|(.+?)\|(\d+)\|(\d+)$') {
        Read-Part -Path $matches[1] -Start ([int]$matches[2]) -Count ([int]$matches[3])
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^LIST_DIR\|(.+)$') {
        List-Dir -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^FIND_FILES\|(.+)$') {
        Find-Files -Glob $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^SEARCH_TEXT\|(.+?)\|(.+)$') {
        Search-Text -Pattern $matches[1] -Path $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '(?s)^WRITE_FILE\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "WRITE_FILE" -Detail $matches[1])) { return $false }
        Write-File -Path $matches[1] -Spec $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '(?s)^APPEND_FILE\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "APPEND_FILE" -Detail $matches[1])) { return $false }
        Append-File -Path $matches[1] -Text $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '(?s)^WRITE_PATCH\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "WRITE_PATCH" -Detail $matches[1])) { return $false }
        Write-Patch -Path $matches[1] -Diff $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '(?s)^RUN_COMMAND\|(.+)$') {
        if (-not (Confirm-Action -Kind "RUN_COMMAND" -Detail $matches[1])) { return $false }
        Run-Command -Command $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^FOR_EACH\|(.+?)\|(.+)$') {
        Invoke-ForEachAction -ListKey $matches[1] -Template $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^REPEAT\|(\d+)\|(.+)$') {
        Invoke-RepeatAction -Count ([int]$matches[1]) -Template $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^BUILD_REPORT\|([^|]+)\|(\d+)\|(\d+)\|([^|]+)\|(.+)$') {
        if (-not (Confirm-Action -Kind "BUILD_REPORT" -Detail $matches[4])) { return $false }
        Build-Report -Glob $matches[1] -Start ([int]$matches[2]) -Count ([int]$matches[3]) -OutPath $matches[4] -Patterns $matches[5]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^CREATE_DIR\|(.+)$') {
        if (-not (Confirm-Action -Kind "CREATE_DIR" -Detail $matches[1])) { return $false }
        Create-Dir -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^DELETE_FILE\|(.+)$') {
        if (-not (Confirm-Action -Kind "DELETE_FILE" -Detail $matches[1])) { return $false }
        Delete-File -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^DELETE_DIR\|(.+)$') {
        if (-not (Confirm-Action -Kind "DELETE_DIR" -Detail $matches[1])) { return $false }
        Delete-Dir -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^MOVE_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "MOVE_ITEM" -Detail $matches[1])) { return $false }
        Move-ItemSafe -Source $matches[1] -Dest $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^COPY_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "COPY_ITEM" -Detail $matches[1])) { return $false }
        Copy-ItemSafe -Source $matches[1] -Dest $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^RENAME_ITEM\|(.+?)\|(.+)$') {
        if (-not (Confirm-Action -Kind "RENAME_ITEM" -Detail $matches[1])) { return $false }
        Rename-ItemSafe -Source $matches[1] -Dest $matches[2]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    if ($Action -match '^VERIFY_PATH\|(.+)$') {
        Verify-Path -Path $matches[1]
        $sw.Stop()
        Write-Host ("[EXEC] Done in {0:N2}s" -f $sw.Elapsed.TotalSeconds)
        return
    }

    Write-Host "[EXEC] Unhandled action: $Action"
}

# ------------------ RUN COMMAND ------------------
function Run-Command {
    param([string]$Command)

    Log-Trace -Where "Run-Command" -Message ("command='{0}'" -f $Command)
    if ($Command -match '(?i)\b(sh|bash|zsh|seq|xargs|grep|awk|sed|cut|head|tail)\b') {
        Write-Host "[RUNNER] Blocked non-PowerShell command: $Command"
        return
    }

    $firstToken = ($Command -split '\s+')[0]
    if ($firstToken -match '^[A-Za-z]+-[A-Za-z]') {
        $cmd = Get-Command -Name $firstToken -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $msg = "Unknown cmdlet: $firstToken"
            Write-Host "[RUNNER] $msg"
            Log-Debug ("RUN_COMMAND failed: {0}" -f $msg)
            $script:UserFeedback = $msg + ". Use explicit PowerShell expressions inside RUN_COMMAND."
            $script:ReplanRequested = $true
            return
        }
    }

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
    try {
        Invoke-Expression $Command
    } catch {
        $msg = $_.Exception.Message
        Write-Host "[RUNNER] Command failed: $msg"
        Log-Debug ("RUN_COMMAND failed: {0}" -f $msg)
        $script:UserFeedback = "RUN_COMMAND failed: $msg"
        $script:ReplanRequested = $true
    }
}

# ------------------ CONFIRM ACTION ------------------
function Confirm-Action {
    param(
        [string]$Kind,
        [string]$Detail
    )

    Log-Trace -Where "Confirm-Action" -Message ("kind='{0}' detail='{1}'" -f $Kind, $Detail)
    if ($ApprovalMode -eq "all") { return $true }
    if (-not $ConfirmRiskyActions) { return $true }
    $resp = Read-Host "Approve $Kind? $Detail (y/n)"
    if ($resp -ne "y") {
        $script:RejectedAction = "$Kind $Detail"
        $reason = Read-Host "Why skip this step? (optional)"
        if ($reason) {
            $script:UserFeedback = $reason
            Log-Debug ("User feedback: {0}" -f $reason)
        }
        $script:ReplanRequested = $true
        return $false
    }
    return $true
}

# ------------------ EXECUTION ------------------
$script:Context = @{}
foreach ($s in $plan.plan) {
    $ok = Execute-Action -Action $s.action
    if ($ok -eq $false) { break }
}

if ($script:ReplanRequested) {
    $note = "User declined action: $($script:RejectedAction)"
    Add-Failure $note
    Write-Host "[AGENT] Replanning based on user feedback..."
    continue
}

break
}
Write-Host "`n[AGENT] Done."










