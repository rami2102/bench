#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"
TIMEOUT="${TIMEOUT:-720}"
INSTANCE_ID="${INSTANCE_ID:-django__django-11049}"

AGENTS=(codex pi gemini)

# Pre-clone repo cache on host so container can use read-only cache safely
bash "$SCRIPT_DIR/swebench-cache-local.sh" --instance-ids "$INSTANCE_ID"

MOUNTS=(
  "-v" "$BENCH_DIR:/workspace:Z"
  "-v" "$BENCH_DIR/cache/swebench/repos:/workspace/cache/swebench/repos:ro,Z"
  "-v" "$HOME/.codex:/home/node/.codex:Z"
  "-v" "$HOME/.gemini:/home/node/.gemini:Z"
  "-v" "$HOME/.pi:/home/node/.pi:Z"
  "-v" "$HOME/.gitconfig:/home/node/.gitconfig:Z"
)

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
    bash -lc "./scripts/bench.sh swebench --agent $agent $model_arg --num-tests 1 --instance-ids $INSTANCE_ID --timeout $TIMEOUT --no-validate"
}

for a in "${AGENTS[@]}"; do
  run_one "$a"
done

echo ""
echo "[podman-swebench-smoke] All SWE-bench smoke runs completed"
