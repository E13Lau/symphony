# GitHub 快速启动清单

这是一份最小端到端清单，用于以 GitHub 作为任务跟踪器启动 Symphony，并完成一次 label 流转演练。

## 1. 导出环境变量

在终端 A 中执行以下命令（先替换占位符）：

```bash
export GITHUB_TOKEN="ghp_xxx_or_installation_token"
export GH_TOKEN="$GITHUB_TOKEN"
export GITHUB_REPOSITORY="owner/repo"

# 可选：当系统没有 gh CLI 时，WORKFLOW.github.md 会回退使用该克隆地址。
export SYMPHONY_SOURCE_REPO="https://github.com/${GITHUB_REPOSITORY}.git"

# 可选：显式指定工作区根目录。
export SYMPHONY_WORKSPACE_ROOT="$HOME/code/symphony-workspaces"
```

快速认证检查：

```bash
gh auth status
gh repo view "$GITHUB_REPOSITORY"
```

## 2. 启动 Symphony

仍在终端 A 中执行：

```bash
cd /path/to/symphony/elixir
/opt/homebrew/bin/mise trust
/opt/homebrew/bin/mise install
/opt/homebrew/bin/mise exec -- mix setup
/opt/homebrew/bin/mise exec -- mix build
/opt/homebrew/bin/mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.github.md --port 4000
```

可选：仪表盘/API 冒烟检查：

```bash
curl -fsS http://127.0.0.1:4000/api/v1/state | head
```

## 3. 一次完整的 issue label 流转演练

打开终端 B，按顺序执行以下步骤。

### 3.1 确保所需 labels 已存在

状态流转所需 labels：

| Label                        | 是否必需 | 说明                                 |
| ---------------------------- | -------- | ------------------------------------ |
| `status:ready-for-ai`        | 是       | 任务已准备好，可被 Symphony 拉取。   |
| `status:ai-in-progress`      | 是       | 已被 Symphony 认领，正在实现中。     |
| `status:rework`              | 是       | 需要返工后再次进入实现。             |
| `status:human-review`        | 是       | AI 交付完成，等待人工评审。          |
| `status:needs-clarification` | 是       | 因需求不清晰或信息不足而阻塞。       |
| `status:done`                | 是       | 已完成并被接受。                     |
| `symphony`                   | 建议     | 标识 issue/PR 属于 Symphony 工作流。 |
| `ai-ready`                   | 建议     | 标识任务对 AI 执行已就绪。           |
| `ai-generated`               | 建议     | 标识内容由 AI 生成。                 |

注意：`closed` 是 GitHub issue 的状态，不是 label。

状态 label 流转与修改者矩阵：

| 起始状态 label          | 目标状态 label               | 修改者                 | 典型触发条件                       |
| ----------------------- | ---------------------------- | ---------------------- | ---------------------------------- |
| `status:ready-for-ai`   | `status:ai-in-progress`      | Symphony agent         | Symphony 认领 issue 并开始实现。   |
| `status:ai-in-progress` | `status:human-review`        | Symphony agent         | PR/检查/验证完成，可进入人工评审。 |
| `status:ai-in-progress` | `status:needs-clarification` | Symphony agent         | 因需求不明确或缺失而无法继续。     |
| `status:human-review`   | `status:rework`              | 人工评审者             | 评审要求修改。                     |
| `status:human-review`   | `status:done`                | 人工评审者或合并自动化 | 评审通过且交付被接受。             |
| `status:rework`         | `status:ai-in-progress`      | Symphony agent         | 进入下一轮 AI 返工。               |

操作规则：

- 同一个 issue 任意时刻仅保留一个 `status:*` label。
- 进入 `status:done` 时，同时关闭 issue（`state: closed`）。
- 从 `status:human-review` 迁出的决策权归人工评审者。

```bash
export GITHUB_REPOSITORY="owner/repo"

for label in \
  status:needs-clarification \
  status:ready-for-ai \
  status:ai-in-progress \
  status:human-review \
  status:rework \
  status:done \
  symphony \
  ai-ready \
  ai-generated; do
  case "$label" in
    status:ready-for-ai)
      description="任务已准备好，可被 Symphony 拉取。"
      ;;
    status:ai-in-progress)
      description="已被 Symphony 认领，正在实现中。"
      ;;
    status:rework)
      description="需要返工后再次进入实现。"
      ;;
    status:human-review)
      description="AI 交付完成，等待人工评审。"
      ;;
    status:needs-clarification)
      description="因需求不清晰或信息不足而阻塞。"
      ;;
    status:done)
      description="已完成并被接受。"
      ;;
    symphony)
      description="标识 issue/PR 属于 Symphony 工作流。"
      ;;
    ai-ready)
      description="标识任务对 AI 执行已就绪。"
      ;;
    ai-generated)
      description="标识内容由 AI 生成。"
      ;;
  esac

  gh label create "$label" \
    --repo "$GITHUB_REPOSITORY" \
    --color "1f6feb" \
    --description "$description" \
    >/dev/null 2>&1 || true
done
```

### 3.2 创建一个 ready-for-ai 的演练 issue

```bash
ISSUE_URL="$(gh issue create \
  --repo "$GITHUB_REPOSITORY" \
  --title "Symphony 演练：label 流转" \
  --body $'## 背景\n该 issue 用于 Symphony GitHub 流程演练。\n\n## 目标\n验证 label 能按预期流转。\n\n## 验收标准\n- [ ] Issue 进入 status:ai-in-progress\n- [ ] Issue 后续进入 status:human-review\n\n## 验证\n- [ ] Symphony 仪表盘可看到状态推进' \
  --label status:ready-for-ai \
  --label ai-ready \
  --label symphony)"

ISSUE_NUMBER="${ISSUE_URL##*/}"
echo "已创建 issue: #$ISSUE_NUMBER ($ISSUE_URL)"
```

### 3.3 观察 label 的辅助函数

```bash
issue_state_json() {
  gh issue view "$1" --repo "$GITHUB_REPOSITORY" --json state,labels --jq '{state:.state, labels:[.labels[].name]}'
}

wait_for_label() {
  local issue_number="$1"
  local target_label="$2"
  local timeout_seconds="${3:-1800}"
  local started_at
  started_at="$(date +%s)"

  while true; do
    labels="$(gh issue view "$issue_number" --repo "$GITHUB_REPOSITORY" --json labels --jq '.labels[].name' | tr '\n' ' ')"
    echo "labels=$labels"

    if echo "$labels" | grep -q "${target_label}"; then
      echo "已到达标签: ${target_label}"
      return 0
    fi

    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$timeout_seconds" ]; then
      echo "等待 ${target_label} 超时" >&2
      return 1
    fi

    sleep 10
  done
}
```

### 3.4 验证 status:ready-for-ai -> status:ai-in-progress

```bash
issue_state_json "$ISSUE_NUMBER"
wait_for_label "$ISSUE_NUMBER" "status:ai-in-progress" 1200
issue_state_json "$ISSUE_NUMBER"
```

### 3.5 验证进入 status:human-review

这一步依赖 agent 执行、PR 创建与 checks 通过。

```bash
wait_for_label "$ISSUE_NUMBER" "status:human-review" 3600
issue_state_json "$ISSUE_NUMBER"
```

### 3.6 完成演练闭环（人工收口）

如果你的合并自动化尚未接通，可以手动闭环：

```bash
gh issue edit "$ISSUE_NUMBER" \
  --repo "$GITHUB_REPOSITORY" \
  --remove-label status:human-review \
  --add-label status:done \
  --state closed

issue_state_json "$ISSUE_NUMBER"
```

演练结束时的期望状态：

- `state` 为 `CLOSED`
- labels 包含 `status:done`

## 4. 停止 Symphony

在终端 A 中按 Ctrl+C。
