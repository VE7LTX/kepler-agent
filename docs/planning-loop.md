# Planning Loop

## JSON Requirements
- Planner output must be wrapped in `<json>...</json>` tags.
- JSON must follow the fixed schema (goal, thinking_summary, reflection, ready, plan).
- Each plan item must have only: `step`, `action`, `expects`.
- Any non-conforming output is rejected and repaired.

## Escalation
- Planner escalates after 2 consecutive rejects:
  `qwen2:7b-instruct` → `mistral:7b-instruct` → `deepseek-coder:6.7b-instruct` → `codellama:13b-instruct`.

## Failure Memory
- Recent failures are injected into the next planning prompt to avoid repeating mistakes.

## Timing
- Planner response time is printed each iteration.
- Each execution step prints elapsed time.
