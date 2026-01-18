# Configuration

Key settings live near the top of `agent.ps1`.

## Models
- `PlannerModel`
- `WriterModel`
- `PlannerFallbacks`
- `PlannerFirstPassModel`
- `GoalSummaryModel`

## Limits
- `MaxPlanIterations` (0 = unlimited)
- `MaxPlanMinutes` (0 = unlimited)

## Safety
- `ConfirmOncePerTask`
- `ConfirmRiskyActions`
- `ConfirmLowConfidence`
- `ApprovalMode` (default, overridden by plan prompt)

## Logging
- `DebugLogPath`
- `DebugLogFull`
- `DebugLogPretty`
- `RequireJsonTags`
- `EnableSpinner`

## Timing / Retry
- `ModelRetryDelaySeconds`
- `EscalateAfterRejects`

## Root
- `RootDir` constrains all file and path actions.
