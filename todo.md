# TODO

- Allow {index} and {index:NNd} placeholders in path validation for REPEAT/FOREACH.
- Enforce LIST_DIR uses directories (auto-convert glob to FIND_FILES).
- Auto-reject invalid action names (CREATE_FILE, READ_FIRST_LINES).
- Ensure FOR_EACH list keys are created before use (FIND_FILES/LIST_DIR).
- Keep JSON output strictly inside <json> tags with no extra text.
- Improve REPEAT guidance in planner prompt with explicit examples.
