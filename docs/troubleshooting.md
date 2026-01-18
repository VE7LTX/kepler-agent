# Troubleshooting

This section lists common failures, why they happen, and what to check.

## Common Failures
- **Invalid JSON**
  - The planner output included stray text or broken JSON.
  - Fix: check the planner prompt in `C:\agent\agent-debug.log` and confirm the model is respecting `<json>...</json>` tags.

- **Invalid action format**
  - The plan used an unknown action or extra keys in a plan item.
  - Fix: ensure the action is in `docs/action-model.md` and each plan item has only `step`, `action`, `expects`.

- **Invalid path**
  - A path is outside `C:\agent\` or contains placeholders like `<path>`.
  - Fix: use absolute Windows paths under `C:\agent\` only.

- **Missing list**
  - A `FOR_EACH` list key was used before it was created.
  - Fix: add a `LIST_DIR` or `FIND_FILES` step earlier in the plan.

- **Model 500 errors**
  - The Ollama server returned a 500 error (often CUDA/OOM or a crashed runner).
  - Fix: retry, or move to a smaller model in `PlannerFallbacks`.

- **Model switched to smaller**
  - The planner rotates through fallbacks after rejects or errors.
  - Fix: pull the fallback models and ensure they are available.

- **RUN_COMMAND blocked**
  - The plan used Unix shell tools (e.g., `sh`, `seq`, `xargs`).
  - Fix: use PowerShell-native commands instead.

- **Long delays**
  - Larger models can take 30-90 seconds per planning call.
  - Fix: use smaller models or reduce `PlannerPredict` in `agent.ps1`.

## Debugging Tips
- Open `C:\agent\agent-debug.log` and look for:
  - `Reject:` entries
  - `Planner raw:` output
  - `WHY_REJECTED` and `BAD_OUTPUT` sections
- Verify Ollama is running:
  - `curl http://localhost:11434/api/tags`

## Safety Notes
- The agent will not run actions outside `C:\agent\`.
- Destructive commands are blocked unless the path is under the root.
