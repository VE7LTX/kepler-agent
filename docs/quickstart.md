# Quickstart

This guide walks a new user through installing dependencies, pulling models, and running the agent on Windows.

## 0) Prerequisites
- Windows PowerShell 5.1 (default on Windows 10/11).
- Local write access to `C:\agent\`.
- Administrator rights (the script self-elevates).

## 1) Install Ollama
Ollama provides the local model server the agent calls.

- Download and install: https://ollama.com/
- Verify installation:
```powershell
ollama --version
```

## 2) Pull Models
The agent does not download models automatically. Pull the models used for goal restatement, planning, and writing:
```powershell
ollama pull codellama:7b-instruct
ollama pull qwen2:7b-instruct
ollama pull mistral:7b-instruct
ollama pull deepseek-coder:6.7b-instruct
ollama pull codellama:13b-instruct
```

Optional (if available in your Ollama build):
```powershell
ollama pull llama3.1:8b-instruct
```

## 3) Start Ollama
Ollama runs a local HTTP API on `http://localhost:11434`.

Check the API:
```powershell
curl http://localhost:11434/api/tags
```

## 4) Run the Agent
From the agent directory:
```powershell
cd C:\agent
.\agent.ps1
```

The script self-elevates to Administrator and then prompts for a goal.

## 5) First Test
Use a small, deterministic goal:
- "make 3 new folders with the prefix \"new\" then increment from new000 to new002"

This exercises `CREATE_DIR`, plan approval, and path validation.

## 6) Read the Output
The agent prints:
- A proposed plan
- A short thinking summary
- A WHO/WHAT/WHEN/WHERE/WHY goal restatement
- Confidence
- Per-step timing during execution

## 7) Logs
The debug log is written to:
- `C:\agent\agent-debug.log`

It contains full planner prompts and responses when `DebugLogFull` is enabled.

## Common Setup Problems
- **Model missing**: run `ollama pull <model>` first.
- **Ollama not running**: start Ollama and verify `http://localhost:11434/api/tags`.
- **Planning loops**: open `C:\agent\agent-debug.log` and look for rejection reasons.

## Next Steps
- Read `docs/action-model.md` to learn available actions.
- Read `docs/planning-loop.md` to understand validation and retries.
