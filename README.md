# Kepler Agent

A local PowerShell automation agent that plans tasks, validates actions, and executes within a bounded directory with user-visible summaries and logs.

## What it does
- Plans in short iterations and rejects invalid plans (invalid JSON, bad actions, bad paths).
- Shows a brief thinking summary and confidence score before execution.
- Uses a restricted action set to operate only inside `C:\agent\`.
- Logs planning attempts, rejections, and model output to `C:\agent\agent-debug.log`.
- Repairs invalid JSON output and retries planning when possible.

## Action Model
All actions are single-line strings in the plan. Multi-file tasks use `FOR_EACH` or `BUILD_REPORT`.

### Core Actions
- `LIST_DIR|<path>`: List files under a directory (max 200); stores in context as `DIR:<path>`.
- `FIND_FILES|<glob>`: Find files by glob (max 200); stores as `FIND:<glob>`.
- `READ_FILE|<path>`: Read an entire file into context.
- `READ_PART|<path>|<start>|<count>`: Read a slice of a file by line range.
- `SEARCH_TEXT|<pattern>|<path>`: Search a file or path for matches (max 200).
- `WRITE_FILE|<path>|<content>`: Write full file contents.
- `APPEND_FILE|<path>|<text>`: Append text to a file.
- `WRITE_PATCH|<path>|<diff>`: Apply a unified diff (via `git apply` or `patch`).
- `RUN_COMMAND|<command>`: Run a command (paths must stay under `C:\agent\`).

### Looping and Batch Actions
- `FOR_EACH|<list_key>|<action_template>`: Execute an action for each item in a list.
  - Templates may include `{item}` and `{index}`.
  - `list_key` is typically `FIND:<glob>` or `DIR:<path>`.
- `BUILD_REPORT|<glob>|<start>|<count>|<outpath>|<patterns>`: Batch scan files and write a report.
  - `patterns` is a comma-separated list.

### CRUD and Verification Actions
- `CREATE_DIR|<path>`: Create directory.
- `DELETE_FILE|<path>`: Delete a file.
- `DELETE_DIR|<path>`: Delete a directory recursively.
- `MOVE_ITEM|<src>|<dest>`: Move a file or directory.
- `COPY_ITEM|<src>|<dest>`: Copy a file or directory.
- `RENAME_ITEM|<src>|<dest>`: Rename (move) a file or directory.
- `VERIFY_PATH|<path>`: Check if a path exists.

## Safety Model
- All file actions are restricted to `C:\agent\`.
- Destructive operations require explicit confirmation.
- Plan approval is required; low-confidence plans require extra confirmation.
- Goals are sanitized to avoid chain-of-thought requests.
- Invalid JSON or action formats are rejected and logged.

## Debugging
- Logs to `C:\agent\agent-debug.log`.
- Includes raw planner output (truncated) and rejection reasons.

## Usage
```powershell
.\agent.ps1
```

## Configuration
Key settings live near the top of `agent.ps1`:
- Models and Ollama endpoints
- Confirmation toggles
- Debug log path
- Root directory constraint

## Notes
- Uses local Ollama models for planning and writing.
- Review proposed plans and outputs; model output can still be wrong.
