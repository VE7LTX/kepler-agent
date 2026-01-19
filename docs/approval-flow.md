# Approval Flow

This agent asks for approval once per plan and then executes according to the selected mode.

## Plan Approval Prompt
You will see a single prompt:
- `a`: approve all steps (no per-step prompts)
- `s`: step-by-step approvals (prompt for each action)
- `n`: cancel the run

Choose `a` when you want a fully automatic run after the plan is printed. Choose `s` when you want to supervise every action.

## Step Declines and Replans
In step-by-step mode, if you answer `n` to any action:
1. The agent asks for a short reason.
2. That reason is injected into the next planning prompt as `USER_FEEDBACK`.
3. The agent replans and shows a new plan.

This lets you refine the goal without restarting the session.

## Low Confidence Handling
If the planner confidence is below the configured threshold, the agent asks for a second confirmation before executing.

## Risky Actions
When `ApprovalMode` is `step` and `ConfirmRiskyActions` is enabled, the agent prompts before actions that write, move, delete, or run commands.
When `ApprovalMode` is `all`, per-step prompts are skipped.

## Why This Exists
- A single plan approval reduces repetitive prompts for safe tasks.
- Step-by-step approval helps when actions are destructive or unclear.
- Replanning keeps the loop going without losing context.

## Tips
- Keep feedback concise and specific (e.g., "Don't delete files" or "Use C:\agent\reports\output.txt instead").
- If you choose `a`, all prompts are skipped unless `ConfirmRiskyActions` is disabled.
