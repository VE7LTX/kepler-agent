# Configuration

Key settings live near the top of `agent.ps1`.

## Models
- `PlannerModel`
- `WriterModel`
- `PlannerFallbacks`

## Limits
- `MaxPlanIterations` (0 = unlimited)
- `MaxPlanMinutes` (0 = unlimited)

## Safety
- `ConfirmOncePerTask`
- `ConfirmRiskyActions`
- `ConfirmLowConfidence`

## Logging
- `DebugLogPath`
- `DebugLogFull`
- `DebugLogPretty`
- `RequireJsonTags`
- `EnableSpinner`

## Root
- `RootDir` constrains all file and path actions.
