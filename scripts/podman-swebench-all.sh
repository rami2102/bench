#!/usr/bin/env bash
# podman-swebench-all.sh — One-command isolated SWE-bench smoke workflow.
#
# Steps:
#  1) Build Podman image
#  2) Run SWE-bench smoke runs in Podman (same test IDs for all selected agents)
#
# Usage:
#   ./scripts/podman-swebench-all.sh [options]
#
# Options are forwarded to podman-swebench-smoke.sh, e.g.:
#   --agents codex,pi
#   --agents all
#   --parallel
#   --instance-ids "django__django-11049"
#   --timeout 720

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"

echo "[podman-all] IMAGE_NAME=$IMAGE_NAME"

echo "[podman-all] Building image..."
IMAGE_NAME="$IMAGE_NAME" bash "$SCRIPT_DIR/podman-build.sh"

echo "[podman-all] Running smoke workflow..."
IMAGE_NAME="$IMAGE_NAME" bash "$SCRIPT_DIR/podman-swebench-smoke.sh" "$@"

echo "[podman-all] Done"
