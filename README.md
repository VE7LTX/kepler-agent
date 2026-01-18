# Kepler Agent

A local PowerShell automation agent that plans tasks, validates actions, and executes within a bounded directory with user-visible summaries and logs.

## What it does
- Plans in short iterations and rejects invalid plans (invalid JSON, bad actions, bad paths).
- Shows a brief thinking summary and confidence score before execution.
- Supports `READ_FILE`, `WRITE_FILE`, and `RUN_COMMAND` actions.
- Normalizes and validates paths, keeping all actions inside `C:\agent\`.
- Logs planning attempts, rejections, and model output to `C:\agent\agent-debug.log`.
- Repairs invalid JSON output and retries planning when possible.

## Usage
```powershell
.\agent.ps1
```

## Safety model
- All file actions are restricted to `C:\agent\`.
- Destructive commands are blocked unless they only target `C:\agent\`.
- Plan approval is required; low-confidence plans require an extra confirmation.
- Goals are sanitized to avoid chain-of-thought requests.

## Configuration
Key settings live near the top of `agent.ps1`:
- Models and Ollama endpoints
- Confidence thresholds
- Confirmation toggles
- Debug log path

## Notes
- Uses local Ollama models for planning and writing.
- Review proposed plans and outputs; model output can still be wrong.
