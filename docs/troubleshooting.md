# Troubleshooting

## Common Failures
- **Invalid JSON**: Planner output contained stray text. Repair step will try to fix.
- **Invalid action format**: Non-allowed actions or extra keys in plan items.
- **Invalid path**: Paths outside `C:\agent\` or invalid placeholders.
- **Missing list**: `FOR_EACH` uses a list key that wasn’t created via `FIND_FILES` or `LIST_DIR`.

## Tips
- Use `BUILD_REPORT` for scan-and-summarize tasks.
- Use `REPEAT` for fixed-count tasks like creating N folders.
- Keep goals explicit about output paths.
