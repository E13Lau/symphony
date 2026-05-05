---
tracker:
  kind: github
  repository: "owner/repo"
  auth:
    mode: token
    token: "$GITHUB_TOKEN"
  state:
    mode: labels
    active:
      - ready-for-ai
      - ai-in-progress
      - rework
      - merging
    terminal:
      - done
    label_prefix: "status:"
  labels:
    symphony: "symphony"
    generated: "ai-generated"

polling:
  interval_ms: 30000

workspace:
  root: "$SYMPHONY_WORKSPACE_ROOT"
  keep_on_success: true
  cleanup_terminal: true

hooks:
  timeout_ms: 120000
  after_create: |
    gh repo clone owner/repo .
    git fetch origin main
  before_run: |
    git status --short
  after_run: |
    git status --short
  before_remove: |
    echo "removing workspace"

agent:
  max_concurrent_agents: 3
  max_turns: 20
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 600000
  turn_timeout_ms: 3600000
  require_checks_success: true

codex:
  mode: app-server
  command: "codex app-server"
  fallback_exec_command: "codex exec --full-auto"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite

workers:
  mode: local
  ssh_hosts: []

database:
  path: "$SYMPHONY_DB_PATH"

server:
  port: 4000
  bind: "127.0.0.1"

logging:
  level: info
  format: text
  file: "$SYMPHONY_LOG_FILE"

github:
  merge:
    enabled: false
---

You are working on GitHub issue {{ issue.identifier }}.

Issue:
Title: {{ issue.title }}
URL: {{ issue.url }}
Current state: {{ issue.state }}
Labels: {{ issue.labels }}

Description:
{{ issue.description }}

Workspace:
{{ workspace.path }}

Instructions:
1. Start by finding or creating one persistent issue comment with header `## Symphony Workpad`.
2. Keep that workpad updated in place throughout the task.
3. Use the workpad sections: Plan, Acceptance Criteria, Validation, Notes, Confusions.
4. Create a branch named `symphony/issue-{{ issue.number }}`.
5. Reproduce or inspect current behavior before changing code.
6. Implement the smallest scoped change that satisfies the issue.
7. Run targeted validation.
8. Commit and push the branch.
9. Create or update a GitHub PR.
10. Add label `symphony` to the PR.
11. Wait for GitHub Actions checks to pass.
12. When complete, move the issue to `status:human-review`.
13. If blocked, update workpad and move issue to `status:needs-clarification`.
