---
tracker:
  kind: github
  api_key: $GITHUB_TOKEN
  repository: $GITHUB_REPOSITORY
  active_states:
    - ready-for-ai
    - ai-in-progress
    - rework
  terminal_states:
    - done
    - closed
  active_labels:
    - status:ready-for-ai
    - status:ai-in-progress
    - status:rework
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    if [ -n "$GITHUB_REPOSITORY" ]; then
      if command -v gh >/dev/null 2>&1; then
        gh repo clone "$GITHUB_REPOSITORY" .
      elif [ -n "$SYMPHONY_SOURCE_REPO" ]; then
        git clone --depth 1 "$SYMPHONY_SOURCE_REPO" .
      else
        echo "gh CLI is missing. Set SYMPHONY_SOURCE_REPO to a clone URL." >&2
        exit 1
      fi
    elif [ -n "$SYMPHONY_SOURCE_REPO" ]; then
      git clone --depth 1 "$SYMPHONY_SOURCE_REPO" .
    else
      echo "Set GITHUB_REPOSITORY or SYMPHONY_SOURCE_REPO before starting Symphony." >&2
      exit 1
    fi

    if command -v mise >/dev/null 2>&1 && [ -d elixir ]; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    if [ -d elixir ] && command -v mise >/dev/null 2>&1; then
      cd elixir && mise exec -- mix workspace.before_remove
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on GitHub issue `{{ issue.identifier }}`.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Execution rules:

1. Work only when the issue state is one of:
   - `ready-for-ai`
   - `ai-in-progress`
   - `rework`
2. Use one persistent issue comment with heading `## Codex Workpad`.
3. Keep that workpad updated with:
   - Plan
   - Acceptance Criteria
   - Validation
   - Notes
   - Confusions
4. If the issue starts in `ready-for-ai`, move it to `ai-in-progress` before implementation.
5. Create or switch to branch `symphony/issue-{{ issue.identifier }}`.
6. Reproduce current behavior before making changes.
7. Make the smallest change that satisfies acceptance criteria.
8. Run targeted validation.
9. Commit and push.
10. Create or update a PR; apply label `symphony` on the PR.
11. Wait until CI/checks are green.
12. Move issue to `human-review` by changing status label when checks and validation pass.
13. If blocked by missing requirements, move issue to `needs-clarification`.

GitHub operations:

- Prefer `github_api` dynamic tool for issue/comment/label state operations.
- You may use `gh` CLI for branch and PR operations.
- Do not close the issue unless state is `done` and merge policy explicitly requires it.

State-label mapping:

- `ready-for-ai` -> `status:ready-for-ai`
- `ai-in-progress` -> `status:ai-in-progress`
- `human-review` -> `status:human-review`
- `rework` -> `status:rework`
- `needs-clarification` -> `status:needs-clarification`
- `done` -> `status:done`
