# TODO

## Planning / JSON
- Enforce strict <json>...</json> output with no extra text or markdown fences.
- Strip/repair malformed JSON and feed rejected output + reason into the next prompt.
- Require plan items to include only step/action/expects keys.

## Actions / Validation
- Treat REPEAT count as non-path; allow {index} and {index:NNd} placeholders in path validation.
- Allow {item} placeholders only inside FOR_EACH templates; reject elsewhere.
- Ensure FOR_EACH list keys exist (LIST_DIR/FIND_FILES must appear before use).
- Normalize LIST_DIR with globs into FIND_FILES (e.g., LIST_DIR|C:\agent\*.ps1).
- Reject unknown actions (CREATE_FILE, READ_FIRST_LINES, WRITE_REPORT).
- Ensure WRITE_FILE specs include real content (length + not placeholder).

## Loops / Templates
- REPEAT should allow fixed-count tasks with templated paths (new{index:03d}).
- FOR_EACH should work on DIR: or FIND: lists with clean item values.

## Paths
- Paths must be absolute under C:\agent\; no unix paths.
- Ensure list outputs (DIR/FIND) are consistent (full paths vs names) to build correct file paths.

## Logging / UX
- Keep debug log readable (no blank lines between every line).
- Log planner prompts/responses and repair inputs/outputs when DebugLogFull is enabled.
- Show model/time status for long-running planner/writer calls.

## Example Plan (for reference)
- CREATE_DIR|C:\agent\new000
- CREATE_DIR|C:\agent\new001
- CREATE_DIR|C:\agent\new002
- WRITE_FILE|C:\agent\new000\new000.txt|This is new000.txt
- WRITE_FILE|C:\agent\new001\new001.txt|This is new001.txt
- WRITE_FILE|C:\agent\new002\new002.txt|This is new002.txt
