#!/usr/bin/env bash
# podman-swebench-all.sh — One-command isolated SWE-bench smoke workflow.
#
# Steps:
#  1) Build Podman image
#  2) Pre-clone required local SWE-bench repos
#  3) Run 1 SWE-bench Lite task for codex, pi, gemini in Podman
#
# Usage:
#   ./scripts/podman-swebench-all.sh
#
# Optional env vars:
#   IMAGE_NAME=bench-agents:latest
#   INSTANCE_ID=django__django-11049
#   TIMEOUT=720
#   GEMINI_MODEL=gemini-2.5-flash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"
INSTANCE_ID="${INSTANCE_ID:-django__django-11049}"
TIMEOUT="${TIMEOUT:-720}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-2.5-flash}"

echo "[podman-all] IMAGE_NAME=$IMAGE_NAME"
echo "[podman-all] INSTANCE_ID=$INSTANCE_ID"
echo "[podman-all] TIMEOUT=$TIMEOUT"
echo "[podman-all] GEMINI_MODEL=$GEMINI_MODEL"

bash "$SCRIPT_DIR/podman-build.sh"
bash "$SCRIPT_DIR/swebench-cache-local.sh" --instance-ids "$INSTANCE_ID"

IMAGE_NAME="$IMAGE_NAME" \
INSTANCE_ID="$INSTANCE_ID" \
TIMEOUT="$TIMEOUT" \
GEMINI_MODEL="$GEMINI_MODEL" \
bash "$SCRIPT_DIR/podman-swebench-smoke.sh"

echo "[podman-all] Done"
