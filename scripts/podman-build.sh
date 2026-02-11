#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"

echo "[podman-build] Building image: $IMAGE_NAME"
podman build -f "$BENCH_DIR/podman/Containerfile" -t "$IMAGE_NAME" "$BENCH_DIR"
echo "[podman-build] Done"
