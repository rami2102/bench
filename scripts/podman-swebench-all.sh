#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"

echo "[podman-all] IMAGE_NAME=$IMAGE_NAME"

echo "[podman-all] Generating test lists..."
bash "$SCRIPT_DIR/swebench-build-test-lists.sh"

echo "[podman-all] Running Podman SWE-bench workflow..."
IMAGE_NAME="$IMAGE_NAME" bash "$SCRIPT_DIR/podman-swebench-run.sh" --build-image "$@"

echo "[podman-all] Done"
