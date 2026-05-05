# GitHub Setup

## 1. Repository labels

Create these labels in your repository:

- `status:needs-clarification`
- `status:ready-for-ai`
- `status:ai-in-progress`
- `status:human-review`
- `status:rework`
- `status:merging`
- `status:done`
- `priority:p0`
- `priority:p1`
- `priority:p2`
- `priority:p3`
- `symphony`
- `ai-generated`

## 2. Authentication

Token mode (implemented):

- Export `GITHUB_TOKEN`.
- Optionally export `GH_TOKEN=$GITHUB_TOKEN` for CLI tooling.
- Use least-privilege scopes needed for issue/PR/check operations.

GitHub App mode:

- Config structure is reserved.
- Token mode is currently the production-ready path.

## 3. Required permissions

For PAT/classic or fine-grained token, grant minimal access:

- Issues: read/write
- Pull requests: read/write
- Checks / Actions metadata: read
- Contents: read/write (for branch push and PR flows)

## 4. Repository configuration

- Ensure default branch is `main` or adjust hook logic.
- Ensure Actions/Checks are enabled for your branch policy.
- Ensure bot user can push branches and create PRs.

## 5. Validation

Run:

```bash
./symphonyd doctor --workflow ./WORKFLOW.md
```

The doctor checks workflow parsing, token presence, workspace/db permissions, and command availability (`git`, `gh`, `codex`, `ssh`).
