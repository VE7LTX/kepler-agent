# Quickstart

This guide covers first-time setup and running the agent locally on Windows.

## 1) Install Ollama
- Download and install Ollama from: https://ollama.com/
- Verify installation:
```powershell
ollama --version
```

## 2) Pull Models
Pull the planner and writer models used by the agent. Recommended set:
```powershell
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
Ollama runs a local server on `http://localhost:11434`.

Verify the API is up:
```powershell
curl http://localhost:11434/api/tags
```

## 4) Run the Agent
From the agent directory:
```powershell
cd C:\agent
.\agent.ps1
```

## 5) First Test
Try a small task to verify everything works:
- “make 3 new folders with the prefix "new" then increment from new000 to new002”

## 6) Logs
The agent writes logs to:
- `C:\agent\agent-debug.log`

## Troubleshooting
- If model calls hang, confirm Ollama is running and the model names match `agent.ps1`.
- If planning loops, check `C:\agent\agent-debug.log` for invalid JSON or action format rejections.
