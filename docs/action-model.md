# Action Model

All actions are single-line strings in the plan. Multi-file tasks use `FOR_EACH` or `BUILD_REPORT`.

## Core Actions
- `LIST_DIR|<path>`: List files under a directory (max 200); stores in context as `DIR:<path>`.
- `FIND_FILES|<glob>`: Find files by glob (max 200); stores as `FIND:<glob>`.
- `READ_FILE|<path>`: Read an entire file into context.
- `READ_PART|<path>|<start>|<count>`: Read a slice of a file by line range.
- `SEARCH_TEXT|<pattern>|<path>`: Search a file or path for matches (max 200).
- `WRITE_FILE|<path>|<content>`: Write full file contents.
- `APPEND_FILE|<path>|<text>`: Append text to a file.
- `WRITE_PATCH|<path>|<diff>`: Apply a unified diff (via `git apply` or `patch`).
- `RUN_COMMAND|<command>`: Run a command (paths must stay under `C:\agent\`).

## Looping and Batch Actions
- `FOR_EACH|<list_key>|<action_template>`: Execute an action for each item in a list.
  - Templates may include `{item}` and `{index}`.
- `REPEAT|<count>|<action_template>`: Execute an action template `count` times.
  - Use `{index}` or `{index:03d}` in the template.
- `BUILD_REPORT|<glob>|<start>|<count>|<outpath>|<patterns>`: Batch scan files and write a report.

## CRUD and Verification Actions
- `CREATE_DIR|<path>`: Create directory.
- `DELETE_FILE|<path>`: Delete a file.
- `DELETE_DIR|<path>`: Delete a directory recursively.
- `MOVE_ITEM|<src>|<dest>`: Move a file or directory.
- `COPY_ITEM|<src>|<dest>`: Copy a file or directory.
- `RENAME_ITEM|<src>|<dest>`: Rename (move) a file or directory.
- `VERIFY_PATH|<path>`: Check if a path exists.

## Examples
- `REPEAT|3|CREATE_DIR|C:\agent\new{index:03d}`
- `BUILD_REPORT|*.ps1|1|40|C:\agent\ps1-report.txt|RUN_COMMAND,Write-File`
- `FOR_EACH|FIND:*.ps1|READ_PART|{item}|1|40`
