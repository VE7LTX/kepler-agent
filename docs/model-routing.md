# Model Routing

This agent splits the work into three model roles: goal restatement, planning, and writing. The goal is to keep planning reliable while keeping output fast enough for interactive use.

## Goal Restatement (fast)
- Model: `qwen2:7b-instruct`
- Output: WHO/WHAT/WHEN/WHERE/WHY summary
- Why: a short, consistent summary keeps the planner aligned with user intent.

## Planner (best available first, then fallbacks)
- First pass: `codellama:13b-instruct`
- Fallback order:
  1. `codellama:13b-instruct`
  2. `qwen2:7b-instruct`
  3. `mistral:7b-instruct`
  4. `deepseek-coder:6.7b-instruct`

The planner may switch to smaller models after repeated rejects or API errors. This is intentional: a smaller model that follows the schema is better than a larger model that fails repeatedly.

## Writer (small-first, retry on short output)
- Primary: `codellama:7b-instruct`
- Fallback: `codellama:13b-instruct`

The writer only needs to produce file content. A small model is usually enough and is faster.

## Failure Handling
- If a model call fails, the agent waits briefly and tries the next fallback.
- CUDA or out-of-memory errors are common on larger models. Smaller fallbacks are more reliable on limited GPUs.

## Pulling Models
The agent does not pull models automatically. Ensure these are installed:
```powershell
ollama pull codellama:7b-instruct
ollama pull qwen2:7b-instruct
ollama pull mistral:7b-instruct
ollama pull deepseek-coder:6.7b-instruct
ollama pull codellama:13b-instruct
```

## Adjusting the Order
You can reorder `PlannerFallbacks` and `PlannerFirstPassModel` in `agent.ps1` to match your hardware. If a larger model consistently fails, move it later in the list.
