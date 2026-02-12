#!/usr/bin/env bash
# swebench-pull-images.sh — Pre-pull SWE-bench Docker images for faster evaluation.
#
# Usage:
#   ./swebench-pull-images.sh [--instance-ids <csv>]
#
# Without args, pulls common base/env images for popular repos.
# With --instance-ids, pulls specific instance images.

set -euo pipefail

INSTANCE_IDS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-ids) INSTANCE_IDS="$2"; shift 2 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

echo "[pull] Pre-pulling SWE-bench Docker images..."

if [[ -n "$INSTANCE_IDS" ]]; then
  # Pull specific instance images
  IFS=',' read -ra IDS <<< "$INSTANCE_IDS"
  for id in "${IDS[@]}"; do
    # SWE-bench image naming: swebench/sweb.eval.<instance_id>:latest
    # But actually the harness builds these on demand from env images
    # The env images follow: swebench/sweb.env.<repo_slug>.<version>:latest
    echo "[pull] Instance $id will be handled by harness on first run"
  done
fi

# Pull common base images that the harness needs
COMMON_IMAGES=(
  "swebench/sweb.base:latest"
)

for img in "${COMMON_IMAGES[@]}"; do
  echo "[pull] Pulling $img..."
  docker pull "$img" 2>&1 || echo "[pull] $img not available (will be built by harness)"
done

echo "[pull] Done. The harness will build env/instance images on first use (cached after)."
