# Approval Flow

The agent asks for plan approval once per planning cycle and then executes based on the chosen mode.

## Plan approval options
- a: approve all steps (no per-step prompts)
- s: step-by-step approvals (prompt for each action)
- n: cancel the run

## Per-step declines
If a step is declined in step-by-step mode:
- The agent asks for a short reason.
- That feedback is added to the next planning prompt.
- The agent replans and presents an updated plan.

## Low confidence handling
If a plan confidence is below the configured threshold, the agent asks for explicit confirmation before executing.

## Notes
- Declining a step does not end the session; it triggers a replan loop.
- The feedback is included verbatim, so keep it short and specific.
