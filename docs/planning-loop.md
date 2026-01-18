# Planning Loop

This section describes how the planner generates a plan, how the agent validates it, and how failures are handled.

## 1) Goal Restatement (fast)
A fast model summarizes the goal into WHO/WHAT/WHEN/WHERE/WHY. This summary is injected into the planner prompt to keep the model aligned with the user intent.

## 2) Planner Prompt
The planner receives a strict JSON template and a fixed action schema. The prompt includes:
- The required `<json>...</json>` wrapper
- The allowed actions list
- Recent rejection reasons
- The last rejected output (truncated)
- User feedback from any declined step
- Agent identity (name and backstory) to anchor WHO/WHAT/WHY

## 3) Planner Output Requirements
- Output must be valid JSON inside `<json>...</json>` tags.
- Only these keys are allowed: `goal`, `thinking_summary`, `reflection`, `ready`, `plan`.
- Each plan item must contain only `step`, `action`, and `expects`.
- Actions must be single-line strings with no raw newlines.
- `{item}` is treated as a full absolute path (not a basename).
- `REPEAT` index is zero-based; use `{index:03d}` for padding.

## 4) Validation and Repair
The agent validates:
- JSON format and schema
- Allowed actions only
- Path safety (must remain under `C:\agent\`)
- `WRITE_FILE` content must be real text (not placeholders)
- `FOR_EACH` list keys must already exist
- `FOR_EACH` may not use `CREATE_DIR` (creation must be explicit)
- `RUN_COMMAND` must be PowerShell-native and cannot rely on invented cmdlets

If JSON is invalid, the agent attempts a repair pass and retries.

## 5) Planner Routing
The planner tries a strong model first, then falls back after repeated rejects:
- First pass: `codellama:13b-instruct`
- Fallback chain: `codellama:13b-instruct` ? `qwen2:7b-instruct` ? `mistral:7b-instruct` ? `deepseek-coder:6.7b-instruct`

A smaller model is used when reliability is better than raw size.

## 6) Failure Memory
Recent failures are fed back into the next prompt. The last rejected output and the rejection reason are included to help the planner avoid repeating the same mistake.

## 6a) Failure Reflection (fast model)
After a rejection, a fast model generates a short diagnostic with concrete fix hints. These hints are injected into the next planner prompt as `RETRY_HINTS` and are shown to the user.

## 7) Approval and Execution
Once a plan passes validation, the agent shows:
- The plan steps
- A short thinking summary
- The WHO/WHAT/WHEN/WHERE/WHY restatement
- Confidence

The user approves once for the whole plan and chooses:
- all steps
- step-by-step
- cancel

If a step is declined, the agent asks why, saves the feedback, and replans.

Between steps, a fast pre-check summary is shown to the user so issues can be spotted early.

## 8) Timing and Logs
- Planner response time is printed each iteration.
- Each action prints elapsed time.
- Full prompts and outputs are logged to `C:\agent\agent-debug.log`.
- Plan diffs between iterations are logged to show what changed.
