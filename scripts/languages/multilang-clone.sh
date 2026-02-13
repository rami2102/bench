#!/usr/bin/env bash
# multilang-clone.sh — Pre-clone all GitHub repos referenced in the
# Multi-SWE-bench_mini dataset so they are available offline.
#
# Usage:
#   ./multilang-clone.sh [-h|--help] [--parallel]
#
# Options:
#   --parallel    Clone up to 4 repos concurrently (default: sequential)
#
# Reads: cache/multilang/multi-swe-bench-mini.jsonl
# Clones to: cache/multilang/repos/{org}-{repo}/

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_DIR=$(dirname "$(dirname "$SCRIPT_DIR")")

DATASET_FILE="$BENCH_DIR/cache/multilang/multi-swe-bench-mini.jsonl"
REPOS_DIR="$BENCH_DIR/cache/multilang/repos"
MAX_JOBS=4
PARALLEL=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help] [--parallel]

Pre-clone all GitHub repos referenced in the Multi-SWE-bench_mini dataset.

Options:
  --parallel    Clone up to $MAX_JOBS repos concurrently (default: sequential)
  -h, --help    Show this help message

Requires: $DATASET_FILE
  Run multilang-cache.sh first to download the dataset.

Repos are cloned to: $REPOS_DIR/{org}-{repo}/
Already-cloned repos are skipped.
EOF
  exit 0
}

# Parse args
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --parallel) PARALLEL=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

# Check dataset exists
if [[ ! -f "$DATASET_FILE" ]]; then
  echo "Error: Dataset not found at $DATASET_FILE" >&2
  echo "Run multilang-cache.sh first to download it." >&2
  exit 1
fi

# Extract unique org/repo pairs from the dataset.
# The dataset has separate "org" and "repo" fields.
mapfile -t REPO_SLUGS < <(
  python3 -c "
import json
seen = set()
for line in open('$DATASET_FILE'):
    d = json.loads(line)
    slug = d['org'] + '/' + d['repo']
    if slug not in seen:
        seen.add(slug)
        print(slug)
" | sort -u
)

if [[ ${#REPO_SLUGS[@]} -eq 0 ]]; then
  echo "No repos found in dataset." >&2
  exit 1
fi

echo "Found ${#REPO_SLUGS[@]} unique repos to clone."
mkdir -p "$REPOS_DIR"

clone_repo() {
  local slug="$1"
  local org repo dir_name clone_url target_dir

  org="${slug%%/*}"
  repo="${slug#*/}"
  dir_name="${org}-${repo}"
  clone_url="https://github.com/${slug}.git"
  target_dir="$REPOS_DIR/$dir_name"

  if [[ -d "$target_dir" ]]; then
    echo "  [skip] $slug — already cloned"
    return 0
  fi

  echo "  [clone] $slug -> $dir_name"
  git clone --quiet "$clone_url" "$target_dir"
}

export -f clone_repo
export REPOS_DIR

if $PARALLEL; then
  echo "Cloning in parallel (max $MAX_JOBS concurrent)..."
  printf '%s\n' "${REPO_SLUGS[@]}" | xargs -P "$MAX_JOBS" -I {} bash -c 'clone_repo "$@"' _ {}
else
  echo "Cloning sequentially..."
  for slug in "${REPO_SLUGS[@]}"; do
    clone_repo "$slug"
  done
fi

echo "Done. Repos are in $REPOS_DIR/"
