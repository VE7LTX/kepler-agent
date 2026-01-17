# Kepler Agent

A local PowerShell automation agent that plans tasks and executes safe, minimal actions with a user-visible summary.

## What it does
- Generates a small plan for each request
- Shows a short thinking summary before executing
- Supports read/write actions and guarded command execution

## Usage
```powershell
.\agent.ps1
```

## Notes
- Uses local Ollama models for planning and writing.
- Review the proposed plan before approving.
