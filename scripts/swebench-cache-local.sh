#!/usr/bin/env bash
# swebench-cache-local.sh — Pre-clone SWE-bench task repositories into local cache.
#
# Usage:
#   ./swebench-cache-local.sh --instance-ids "django__django-11049"
#   ./swebench-cache-local.sh --repos "django/django,sympy/sympy"
#
# Optional flags:
#   --dataset-cache <dir>  (default: ../cache/swebench)
#   --instance-ids <ids>   Comma-separated SWE-bench instance IDs
#   --repos <repos>        Comma-separated GitHub repos (owner/name)
#   --force                Refresh repo cache folders

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

DATASET_CACHE="$BENCH_DIR/cache/swebench"
INSTANCE_IDS=""
REPOS=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset-cache) DATASET_CACHE="$2"; shift 2 ;;
    --instance-ids)  INSTANCE_IDS="$2"; shift 2 ;;
    --repos)         REPOS="$2"; shift 2 ;;
    --force)         FORCE=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

DATASET_FILE="$DATASET_CACHE/swe-bench-lite.jsonl"
REPO_CACHE_ROOT="$DATASET_CACHE/repos"
mkdir -p "$REPO_CACHE_ROOT"

if [[ -z "$REPOS" ]]; then
  [[ -f "$DATASET_FILE" ]] || { echo "ERROR: Missing dataset file: $DATASET_FILE" >&2; exit 1; }
  [[ -n "$INSTANCE_IDS" ]] || { echo "ERROR: Pass --repos or --instance-ids" >&2; exit 1; }

  REPOS=$(python3 - << PY
import json
ids = set("$INSTANCE_IDS".split(','))
repos = []
with open("$DATASET_FILE") as f:
    for line in f:
        item = json.loads(line)
        if item.get("instance_id") in ids:
            repos.append(item.get("repo"))
seen = []
for r in repos:
    if r and r not in seen:
        seen.append(r)
print(','.join(seen))
PY
)
fi

[[ -n "$REPOS" ]] || { echo "ERROR: No repos resolved" >&2; exit 1; }

IFS=',' read -ra REPO_LIST <<< "$REPOS"
for repo in "${REPO_LIST[@]}"; do
  repo="$(echo "$repo" | xargs)"
  [[ -n "$repo" ]] || continue

  cache_dir="$REPO_CACHE_ROOT/${repo//\//-}"
  if [[ -d "$cache_dir/.git" && "$FORCE" == false ]]; then
    echo "[cache-local] Exists: $cache_dir"
    continue
  fi

  if [[ "$FORCE" == true && -d "$cache_dir" ]]; then
    rm -rf "$cache_dir"
  fi

  echo "[cache-local] Cloning https://github.com/$repo.git -> $cache_dir"
  git clone "https://github.com/$repo.git" "$cache_dir"
done

echo "[cache-local] Done"
