# Action Model

The planner can only emit actions from a fixed list. Each action is a single-line string in the plan. Multi-file work uses `FOR_EACH` or `BUILD_REPORT`.

## Core Actions
- `LIST_DIR|<path>`: List entries in a directory (max 200). Stores full paths keyed as `DIR:<path>`.
- `FIND_FILES|<glob>`: Find files by glob (max 200). Stores full paths keyed as `FIND:<glob>`.
- `READ_FILE|<path>`: Load a full file into context.
- `READ_PART|<path>|<start>|<count>`: Load a slice of a file by line number.
- `SEARCH_TEXT|<pattern>|<path>`: Search within a file or path for matches (max 200).
- `WRITE_FILE|<path>|<content>`: Write full file contents. Content must be real text, not a placeholder.
- `APPEND_FILE|<path>|<text>`: Append text to an existing file.
- `WRITE_PATCH|<path>|<diff>`: Apply a unified diff (via `git apply` or `patch`).
- `RUN_COMMAND|<command>`: Run a command. Any paths must stay under `C:\agent\`.
  - Use PowerShell-native commands only. Unix tools (sh, bash, seq, xargs, grep, awk, sed, cut, head, tail) are blocked.
  - Avoid invented cmdlets. Use explicit PowerShell expressions for computation.

## Looping and Batch Actions
- `FOR_EACH|<list_key>|<action_template>`
  - Iterates over a list created by `LIST_DIR` or `FIND_FILES`.
  - `{item}` expands to the full absolute path of each list entry.
  - `{index}` is zero-based. Use `{index:03d}` for zero padding.
  - `list_key` must be `DIR:<path>` or `FIND:<glob>` that already exists in the plan.
  - Do not use `CREATE_DIR` inside `FOR_EACH`; creation must be explicit.
- `REPEAT|<count>|<action_template>`
  - Runs the template a fixed number of times.
  - Use `{index}` or `{index:03d}` in the template for zero-padded numbering.
- `BUILD_REPORT|<glob>|<start>|<count>|<outpath>|<patterns>`
  - Scans files matched by a glob, reads a line slice, and writes a report.

## CRUD and Verification Actions
- `CREATE_DIR|<path>`: Create a directory.
- `DELETE_FILE|<path>`: Delete a file.
- `DELETE_DIR|<path>`: Delete a directory recursively.
- `MOVE_ITEM|<src>|<dest>`: Move a file or directory.
- `COPY_ITEM|<src>|<dest>`: Copy a file or directory.
- `RENAME_ITEM|<src>|<dest>`: Rename (move) a file or directory.
- `VERIFY_PATH|<path>`: Check if a path exists.

## Path Rules
- Paths must be absolute and under `C:\agent\`.
- Unix-style paths are rejected.
- Placeholders like `<path>` or `/path/to` are rejected.

## Context and Lists
- `READ_FILE` and `READ_PART` store content in an internal context map.
- `LIST_DIR` produces `DIR:<path>` lists.
- `FIND_FILES` produces `FIND:<glob>` lists.
- `FOR_EACH` can only reference lists created earlier in the same plan.

## Examples
Create numbered folders:
- `REPEAT|3|CREATE_DIR|C:\agent\new{index:03d}`

Scan scripts and report:
- `BUILD_REPORT|*.ps1|1|40|C:\agent\ps1-report.txt|RUN_COMMAND,Write-File`

Read first 40 lines of each PowerShell file:
- `FOR_EACH|FIND:*.ps1|READ_PART|{item}|1|40`
