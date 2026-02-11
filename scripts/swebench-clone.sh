#!/usr/bin/env bash
# swebench-clone.sh — Clone/cache a SWE-Bench repo under ./cache/swebench/repos
#
# Usage:
#   ./swebench-clone.sh
#   ./swebench-clone.sh --repo-url <git-url>
#   SWEBENCH_REPO_URL=<git-url> ./swebench-clone.sh
#
# Optional flags:
#   --cache-dir <dir>   Cache root (default: ../cache/swebench)
#   --target-name <n>   Repo cache dir name (default: owner-repo from URL)
#   --force             Re-clone even if cache already exists
#   --help, -h          Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

REPO_URL="${SWEBENCH_REPO_URL:-https://github.com/SWE-bench/SWE-bench.git}"
CACHE_DIR="$BENCH_DIR/cache/swebench"
TARGET_NAME=""
FORCE=false

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)    REPO_URL="$2"; shift 2 ;;
    --cache-dir)   CACHE_DIR="$2"; shift 2 ;;
    --target-name) TARGET_NAME="$2"; shift 2 ;;
    --force)       FORCE=true; shift ;;
    --help|-h)     usage ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$TARGET_NAME" ]]; then
  # Match existing cache naming style: owner-repo (e.g. django-django)
  cleaned="${REPO_URL%.git}"
  cleaned="${cleaned#git@github.com:}"
  cleaned="${cleaned#https://github.com/}"
  TARGET_NAME="${cleaned//\//-}"
  TARGET_NAME="$(echo "$TARGET_NAME" | tr '[:upper:]' '[:lower:]')"
fi

TARGET_DIR="$CACHE_DIR/repos/$TARGET_NAME"
mkdir -p "$(dirname "$TARGET_DIR")"

if [[ -d "$TARGET_DIR/.git" && "$FORCE" == false ]]; then
  echo "[swebench] Cache already exists: $TARGET_DIR"
  echo "[swebench] Skipping clone (use --force to refresh)."
  exit 0
fi

if [[ "$FORCE" == true && -d "$TARGET_DIR" ]]; then
  rm -rf "$TARGET_DIR"
fi

echo "[swebench] Cloning: $REPO_URL"
echo "[swebench] Target:  $TARGET_DIR"
git clone "$REPO_URL" "$TARGET_DIR"

echo "[swebench] Done"
