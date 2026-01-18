# Model Routing

This agent separates goal restatement, planning, and writing to keep responses fast and predictable.

## Goal restatement (fast)
- Model: `qwen2:7b-instruct`
- Purpose: summarize WHO/WHAT/WHEN/WHERE/WHY to keep prompts grounded.

## Planner (best available first, then fallbacks)
- First pass: `codellama:13b-instruct`
- Fallback order:
  1. `codellama:13b-instruct`
  2. `qwen2:7b-instruct`
  3. `mistral:7b-instruct`
  4. `deepseek-coder:6.7b-instruct`

The planner may switch to a smaller model after repeated failures or API errors. The goal is reliability, not always a larger model.

## Writer (small-first, retry on short output)
- Primary: `codellama:7b-instruct`
- Fallback: `codellama:13b-instruct`

## Notes
- Ensure all models are pulled via Ollama before running.
- If a model fails (CUDA/OOM), the agent will switch to the next fallback after a short delay.
