#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./run_github.sh <github-url-or-owner/repo> [options]

Examples:
  ./run_github.sh openai/symphony
  ./run_github.sh https://github.com/openai/symphony.git --port 4001

Options:
  --port <port>               Dashboard/API port. Default: 4000.
  --workflow <path>           Workflow file. Default: elixir/WORKFLOW.github.md.
  --local-agent               Run Codex with local full access instead of workspace sandbox.
  --workspace-root <path>     Workspace root. Default: $HOME/code/symphony-workspaces.
  --source-repo <url>         Clone URL used when gh CLI is unavailable.
  --no-install-runtime        Do not auto-install mise when no Elixir runtime is found.
  --skip-labels               Do not create GitHub labels before starting.
  --skip-build                Do not run mise setup/build before starting.
  -h, --help                  Show this help.

Authentication:
  Uses GITHUB_TOKEN when set. Otherwise, reads a token from the authenticated gh CLI.

Runtime:
  Uses mise when available. Otherwise, falls back to local mix/elixir. If neither exists, installs
  mise with Homebrew unless --no-install-runtime is passed.

Network:
  Uses proxy env vars only when you set them explicitly, such as HTTP_PROXY or HTTPS_PROXY.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[symphony] %s\n' "$*"
}

repo_arg=""
port="4000"
workflow="elixir/WORKFLOW.github.md"
workflow_specified="false"
local_agent="false"
workspace_root="${HOME}/code/symphony-workspaces"
source_repo=""
skip_labels="false"
skip_build="false"
install_runtime="true"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --port)
      [ "$#" -ge 2 ] || die "--port requires a value"
      port="$2"
      shift 2
      ;;
    --workflow)
      [ "$#" -ge 2 ] || die "--workflow requires a value"
      workflow="$2"
      workflow_specified="true"
      shift 2
      ;;
    --local-agent)
      local_agent="true"
      shift
      ;;
    --workspace-root)
      [ "$#" -ge 2 ] || die "--workspace-root requires a value"
      workspace_root="$2"
      shift 2
      ;;
    --source-repo)
      [ "$#" -ge 2 ] || die "--source-repo requires a value"
      source_repo="$2"
      shift 2
      ;;
    --no-install-runtime)
      install_runtime="false"
      shift
      ;;
    --skip-labels)
      skip_labels="true"
      shift
      ;;
    --skip-build)
      skip_build="true"
      shift
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [ -z "$repo_arg" ] || die "only one GitHub repository can be specified"
      repo_arg="$1"
      shift
      ;;
  esac
done

[ -n "$repo_arg" ] || {
  usage
  exit 2
}

if [ "$local_agent" = "true" ]; then
  [ "$workflow_specified" != "true" ] || die "--local-agent cannot be combined with --workflow"
  workflow="elixir/WORKFLOW.github.local.md"
fi

resolve_github_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    return 0
  fi

  if [ -n "${GH_TOKEN:-}" ]; then
    GITHUB_TOKEN="$GH_TOKEN"
    export GITHUB_TOKEN
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
    export GITHUB_TOKEN
  fi

  [ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN is not set and gh CLI is not authenticated"
}

resolve_github_token

require_codex_login() {
  if ! command -v codex >/dev/null 2>&1; then
    die "Codex CLI not found. Install Codex CLI and run 'codex login' before starting Symphony."
  fi

  if ! codex login status >/dev/null 2>&1; then
    die "Codex CLI is not logged in. Run 'codex login' first."
  fi
}

require_codex_login

normalize_repo() {
  local value="$1"

  value="${value#https://github.com/}"
  value="${value#http://github.com/}"
  value="${value#github.com/}"
  value="${value#ssh://git@github.com/}"
  value="${value#git@github.com:}"
  value="${value%/}"
  value="${value%.git}"

  case "$value" in
    */*)
      printf '%s\n' "$value" | awk -F/ '{print $1 "/" $2}'
      ;;
    *)
      return 1
      ;;
  esac
}

github_repository="$(normalize_repo "$repo_arg")" || die "expected owner/repo or a github.com URL"
default_source_repo="https://github.com/${github_repository}.git"
if [ -z "$source_repo" ]; then
  source_repo="$default_source_repo"
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elixir_dir="${script_dir}/elixir"

cd "$script_dir"

[ -d "$elixir_dir" ] || die "missing elixir directory at ${elixir_dir}"
[ -f "$workflow" ] || die "workflow file does not exist: $workflow"
workflow_path="$(cd "$(dirname "$workflow")" && pwd)/$(basename "$workflow")"

export GITHUB_REPOSITORY="$github_repository"
export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
export SYMPHONY_SOURCE_REPO="$source_repo"
export SYMPHONY_WORKSPACE_ROOT="$workspace_root"

mise_bin() {
  if command -v mise >/dev/null 2>&1; then
    command -v mise
  elif [ -x /opt/homebrew/bin/mise ]; then
    printf '%s\n' "/opt/homebrew/bin/mise"
  elif [ -x /usr/local/bin/mise ]; then
    printf '%s\n' "/usr/local/bin/mise"
  else
    return 1
  fi
}

brew_bin() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
  elif [ -x /opt/homebrew/bin/brew ]; then
    printf '%s\n' "/opt/homebrew/bin/brew"
  elif [ -x /usr/local/bin/brew ]; then
    printf '%s\n' "/usr/local/bin/brew"
  else
    return 1
  fi
}

install_mise_with_brew() {
  local brew

  if [ "$install_runtime" != "true" ]; then
    die "Elixir runtime not found and runtime auto-install is disabled."
  fi

  brew="$(brew_bin)" || die "Elixir runtime not found and Homebrew is unavailable. Install Homebrew or rerun after installing mise/elixir."

  info "mise and mix not found; installing mise with Homebrew"
  "$brew" install mise
}

ensure_runtime() {
  if mise_bin >/dev/null 2>&1 || command -v mix >/dev/null 2>&1; then
    return 0
  fi

  install_mise_with_brew

  if ! mise_bin >/dev/null 2>&1 && ! command -v mix >/dev/null 2>&1; then
    die "runtime installation completed, but neither mise nor mix is available on PATH"
  fi
}

require_mix() {
  if ! command -v mix >/dev/null 2>&1; then
    die "Elixir runtime not found. Install mise with 'brew install mise', or install Elixir so 'mix' is on PATH."
  fi
}

build_symphony() {
  local mise

  cd "$elixir_dir"
  ensure_runtime

  if mise="$(mise_bin)"; then
    "$mise" trust
    "$mise" install
    "$mise" exec -- mix setup
    "$mise" exec -- mix build
  else
    info "mise not found; using existing local mix/elixir"
    require_mix
    mix setup
    mix build
  fi

  [ -x "./bin/symphony" ] || die "build did not produce elixir/bin/symphony"
  cd "$script_dir"
}

start_symphony() {
  local mise

  cd "$elixir_dir"
  ensure_runtime

  if mise="$(mise_bin)"; then
    "$mise" exec -- ./bin/symphony \
      --i-understand-that-this-will-be-running-without-the-usual-guardrails \
      "$workflow_path" \
      --port "$port"
  else
    require_mix
    [ -x "./bin/symphony" ] || die "missing elixir/bin/symphony. Re-run without --skip-build."
    ./bin/symphony \
      --i-understand-that-this-will-be-running-without-the-usual-guardrails \
      "$workflow_path" \
      --port "$port"
  fi
}

json_string() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

label_path_name() {
  printf '%s' "$1" | sed 's/%/%25/g; s#/#%2F#g; s/:/%3A/g; s/ /%20/g'
}

label_exists_with_gh() {
  local label="$1"
  local encoded_label

  encoded_label="$(label_path_name "$label")"
  gh api --method GET "repos/${github_repository}/labels/${encoded_label}" >/dev/null 2>&1
}

create_label_with_gh() {
  local label="$1"
  local description="$2"
  local color="$3"

  gh api --method POST "repos/${github_repository}/labels" \
    -f "name=${label}" \
    -f "color=${color}" \
    -f "description=${description}" \
    >/dev/null
}

label_exists_with_curl() {
  local label="$1"
  local encoded_label
  local status

  encoded_label="$(label_path_name "$label")"

  status="$(
    curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${github_repository}/labels/${encoded_label}" || true
  )"

  case "$status" in
    200)
      return 0
      ;;
    404)
      return 1
      ;;
    *)
      die "failed to check label '${label}' via GitHub API (HTTP ${status})"
      ;;
  esac
}

create_label_with_curl() {
  local label="$1"
  local description="$2"
  local color="$3"
  local escaped_label
  local escaped_description
  local status

  escaped_label="$(json_string "$label")"
  escaped_description="$(json_string "$description")"

  status="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      -X POST \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${github_repository}/labels" \
      -d "{\"name\":\"${escaped_label}\",\"color\":\"${color}\",\"description\":\"${escaped_description}\"}" || true
  )"

  case "$status" in
    201)
      return 0
      ;;
    *)
      die "failed to create label '${label}' via GitHub API (HTTP ${status})"
      ;;
  esac
}

ensure_label() {
  local label="$1"
  local description="$2"
  local color="${3:-1f6feb}"

  if command -v curl >/dev/null 2>&1; then
    if label_exists_with_curl "$label"; then
      return 0
    fi

    create_label_with_curl "$label" "$description" "$color"
  elif command -v gh >/dev/null 2>&1; then
    if label_exists_with_gh "$label"; then
      return 0
    fi

    if create_label_with_gh "$label" "$description" "$color"; then
      return 0
    fi

    if label_exists_with_gh "$label"; then
      return 0
    fi

    die "failed to create label '${label}' with GitHub REST API"
  else
    die "gh or curl is required to create labels. Re-run with --skip-labels to skip this step."
  fi
}

ensure_labels() {
  info "ensuring GitHub labels exist on ${github_repository}"
  ensure_label "status:needs-clarification" "Blocked because requirements are unclear." "d29922"
  ensure_label "status:ready-for-ai" "Ready for Symphony to pick up." "1f6feb"
  ensure_label "status:ai-in-progress" "Claimed by Symphony and in progress." "fbca04"
  ensure_label "status:human-review" "Ready for human review." "8957e5"
  ensure_label "status:rework" "Needs another AI implementation pass." "bf8700"
  ensure_label "status:merging" "Being merged." "0969da"
  ensure_label "status:done" "Accepted and complete." "0e8a16"
  ensure_label "priority:p0" "Highest priority." "b60205"
  ensure_label "priority:p1" "High priority." "d1242f"
  ensure_label "priority:p2" "Medium priority." "fbca04"
  ensure_label "priority:p3" "Low priority." "6e7781"
  ensure_label "symphony" "Managed by Symphony." "1f6feb"
  ensure_label "ai-ready" "Ready for AI execution." "1f6feb"
  ensure_label "ai-generated" "Generated by AI." "5319e7"
}

if command -v gh >/dev/null 2>&1; then
  info "checking GitHub access for ${github_repository}"
  gh repo view "$github_repository" >/dev/null
fi

if [ "$skip_labels" != "true" ]; then
  ensure_labels
fi

if [ "$skip_build" != "true" ]; then
  info "installing dependencies and building Symphony"
  build_symphony
fi

info "starting Symphony for ${github_repository}"
info "dashboard: http://127.0.0.1:${port}"
info "workspace root: ${SYMPHONY_WORKSPACE_ROOT}"

start_symphony
