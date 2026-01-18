# Configuration

All settings live near the top of `agent.ps1`. These control model selection, timeouts, safety checks, and logging behavior.

## Models
- `PlannerModel`: Default planner model used after the first pass.
- `PlannerFirstPassModel`: First model used each run (usually the largest available).
- `PlannerFallbacks`: Ordered list of fallback planner models and their temperatures.
- `WriterModel`: Default writer model for `WRITE_FILE` output.
- `WriterFallbacks`: Models used if the writer output is too short.
- `GoalSummaryModel`: Fast model used to generate the WHO/WHAT/WHEN/WHERE/WHY restatement.

## Model Options
- `PlannerNumCtx`, `PlannerPredict`, `PlannerTemp`: Planner token window, output limit, temperature.
- `WriterNumCtx`, `WriterPredict`, `WriterTemp`: Writer token window, output limit, temperature.

## Limits
- `MaxPlanIterations`: Max planning iterations (0 = unlimited).
- `MaxPlanMinutes`: Max planning time (0 = unlimited).

## Safety / Approval
- `ConfirmOncePerTask`: Ask for approval once per plan.
- `ConfirmRiskyActions`: Prompt before actions that write, move, delete, or run commands.
- `ConfirmLowConfidence`: Prompt if planner confidence is below threshold.
- `ApprovalMode`: Default approval mode (`all` or `step`). This is overridden by the plan approval prompt.

## Logging
- `DebugLogPath`: Path to the debug log.
- `DebugLogFull`: If true, log full prompts and outputs.
- `DebugLogPretty`: If true, log in multi-line format.
- `RequireJsonTags`: Reject plans not wrapped in `<json>...</json>` tags.
- `EnableSpinner`: Show a spinner while models are running.

## Timing / Retry
- `ModelRetryDelaySeconds`: Delay before retrying a failed model call.
- `EscalateAfterRejects`: How many rejects before switching planner model.

## Root
- `RootDir`: Root directory constraint. All paths and file operations must stay under this path.
