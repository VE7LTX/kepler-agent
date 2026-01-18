# Kepler Agent

A local PowerShell automation agent that plans tasks, validates actions, and executes within a bounded directory with user-visible summaries and logs.

## What it does
- Plans in short iterations and rejects invalid plans (invalid JSON, bad actions, bad paths).
- Shows a brief thinking summary and a WHO/WHAT/WHEN/WHERE/WHY goal restatement before execution.
- Uses a restricted action set to operate only inside `C:\agent\`.
- Logs planning attempts, rejections, and model output to `C:\agent\agent-debug.log`.
- Repairs invalid JSON output and retries planning when possible.
- Escalates to stronger planner models after repeated failures.
- Uses a strict JSON template wrapped in `<json>...</json>` tags.
- Prints per-step timing and planner response time to show when larger models take longer.
- Shows a spinner while model calls are running.
- Waits briefly and retries after model call failures.

## Docs
- [Quickstart](docs/quickstart.md): First-time setup (Ollama install, model pulls, run steps).
- [Action Model](docs/action-model.md): Full action reference, validation rules, and examples.
- [Planning Loop](docs/planning-loop.md): Planner schema, JSON requirements, fallbacks, and rejection logic.
- [Configuration](docs/config.md): Configuration knobs and defaults.
- [Troubleshooting](docs/troubleshooting.md): Common failures and fixes.

## Quick start
```powershell
.\agent.ps1
```

## Notes
- Uses local Ollama models for planning and writing.
- Review proposed plans and outputs; model output can still be wrong.
