#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "[swebench-all] Generating test lists..."
bash "$SCRIPT_DIR/swebench-build-test-lists.sh"

echo "[swebench-all] Running host SWE-bench workflow..."
bash "$SCRIPT_DIR/swebench-run-multi.sh" "$@"

echo "[swebench-all] Done"
