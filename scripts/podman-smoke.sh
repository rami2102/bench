#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"
TIMEOUT="${TIMEOUT:-240}"

# Agents requested by user
AGENTS=(codex pi gemini)

# Auth/cache mounts for non-interactive runs
MOUNTS=(
  "-v" "$BENCH_DIR:/workspace:Z"
  "-v" "$HOME/.codex:/home/node/.codex:Z"
  "-v" "$HOME/.gemini:/home/node/.gemini:Z"
  "-v" "$HOME/.pi:/home/node/.pi:Z"
  "-v" "$HOME/.gitconfig:/home/node/.gitconfig:Z"
)

run_one() {
  local agent="$1"
  echo ""
  echo "[podman-smoke] Running 1 youBencha test for: $agent"

  podman run --rm \
    --userns=keep-id \
    --user "$(id -u):$(id -g)" \
    --network host \
    "${MOUNTS[@]}" \
    -w /workspace \
    "$IMAGE_NAME" \
    bash -lc "./scripts/bench.sh youbencha --agent $agent --num-tests 1 --timeout $TIMEOUT"
}

for a in "${AGENTS[@]}"; do
  run_one "$a"
done

echo ""
echo "[podman-smoke] All smoke runs completed"
