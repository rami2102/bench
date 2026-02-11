#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"
TIMEOUT="${TIMEOUT:-720}"
INSTANCE_IDS="${INSTANCE_IDS:-django__django-11049}"
AGENTS_CSV="${AGENTS:-codex,pi,gemini}"
PARALLEL="${PARALLEL:-false}"

usage() {
  cat <<'EOF'
Usage: podman-swebench-smoke.sh [options]

Options:
  --agents <list>         Comma-separated agents (claude,codex,gemini,pi) or all
  --parallel              Run selected agents concurrently
  --instance-ids <list>   Comma-separated SWE-bench instance IDs (same set for all agents)
  --timeout <sec>         Per-task timeout (default: 720)
  --image-name <name>     Podman image (default: bench-agents:latest)
  --help, -h              Show help

Env overrides:
  IMAGE_NAME, TIMEOUT, INSTANCE_IDS, AGENTS, PARALLEL, GEMINI_MODEL
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)       AGENTS_CSV="$2"; shift 2 ;;
    --parallel)     PARALLEL=true; shift ;;
    --instance-ids) INSTANCE_IDS="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --image-name)   IMAGE_NAME="$2"; shift 2 ;;
    --help|-h)      usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ "$AGENTS_CSV" == "all" ]]; then
  AGENT_LIST=(claude codex gemini pi)
else
  IFS=',' read -ra AGENT_LIST <<< "$AGENTS_CSV"
fi

validate_agent() {
  case "$1" in
    claude|codex|gemini|pi) ;;
    *) echo "ERROR: Unsupported agent '$1'" >&2; exit 1 ;;
  esac
}

for a in "${AGENT_LIST[@]}"; do
  validate_agent "$(echo "$a" | xargs)"
done

# Pre-clone required repos on host (shared safely as read-only mount)
bash "$SCRIPT_DIR/swebench-cache-local.sh" --instance-ids "$INSTANCE_IDS"

MOUNTS=(
  "-v" "$BENCH_DIR:/workspace:Z"
  "-v" "$BENCH_DIR/cache/swebench/repos:/workspace/cache/swebench/repos:ro,Z"
  "-v" "$HOME/.codex:/home/node/.codex:Z"
  "-v" "$HOME/.gemini:/home/node/.gemini:Z"
  "-v" "$HOME/.pi:/home/node/.pi:Z"
  "-v" "$HOME/.gitconfig:/home/node/.gitconfig:Z"
)

# Claude auth locations (if present)
[[ -d "$HOME/.claude" ]] && MOUNTS+=("-v" "$HOME/.claude:/home/node/.claude:Z")
[[ -f "$HOME/.claude.json" ]] && MOUNTS+=("-v" "$HOME/.claude.json:/home/node/.claude.json:Z")

run_one() {
  local agent="$1"
  local model_arg=""

  if [[ "$agent" == "gemini" ]]; then
    model_arg="--model ${GEMINI_MODEL:-gemini-2.5-flash}"
  fi

  echo ""
  echo "[podman-swebench-smoke] Running 1 SWE-bench Lite task for: $agent ${model_arg:+($model_arg)}"

  podman run --rm \
    --userns=keep-id \
    --user "$(id -u):$(id -g)" \
    --network host \
    "${MOUNTS[@]}" \
    -w /workspace \
    "$IMAGE_NAME" \
    bash -lc "./scripts/bench.sh swebench --agent $agent $model_arg --num-tests 1 --instance-ids $INSTANCE_IDS --timeout $TIMEOUT --no-validate"
}

if [[ "$PARALLEL" == "true" ]]; then
  pids=()
  agents_for_pid=()
  for raw in "${AGENT_LIST[@]}"; do
    a="$(echo "$raw" | xargs)"
    run_one "$a" > "$BENCH_DIR/results/swebench/podman-smoke-${a}.log" 2>&1 &
    pids+=("$!")
    agents_for_pid+=("$a")
  done

  failures=0
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    agent="${agents_for_pid[$i]}"
    if wait "$pid"; then
      echo "[podman-swebench-smoke] $agent: OK"
    else
      echo "[podman-swebench-smoke] $agent: FAILED (see results/swebench/podman-smoke-${agent}.log)"
      failures=$((failures+1))
    fi
  done

  [[ $failures -eq 0 ]] || exit 1
else
  for raw in "${AGENT_LIST[@]}"; do
    a="$(echo "$raw" | xargs)"
    run_one "$a"
  done
fi

echo ""
echo "[podman-swebench-smoke] Completed for agents: ${AGENTS_CSV} (parallel=$PARALLEL)"
