#!/usr/bin/env bash
# multilang-cache.sh — Download the Multi-SWE-bench_mini dataset JSONL file.
#
# Downloads from HuggingFace and caches locally so subsequent runs are free.
#
# Usage:
#   ./multilang-cache.sh [-h|--help]
#
# The dataset is saved to: cache/multilang/multi-swe-bench-mini.jsonl

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BENCH_DIR=$(dirname "$(dirname "$SCRIPT_DIR")")

DATASET_URL="https://huggingface.co/datasets/ByteDance-Seed/Multi-SWE-bench_mini/resolve/main/multi_swe_bench_mini.jsonl"
CACHE_DIR="$BENCH_DIR/cache/multilang"
OUTPUT_FILE="$CACHE_DIR/multi-swe-bench-mini.jsonl"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-h|--help]

Download the Multi-SWE-bench_mini dataset from HuggingFace.

The JSONL file is saved to:
  $OUTPUT_FILE

If the file already exists, the download is skipped.
EOF
  exit 0
}

download_dataset() {
  if [[ -f "$OUTPUT_FILE" ]]; then
    echo "Dataset already cached at $OUTPUT_FILE — skipping download."
    return 0
  fi
  echo "Downloading Multi-SWE-bench_mini dataset..."
  mkdir -p "$CACHE_DIR"
  curl -fSL --progress-bar -o "$OUTPUT_FILE" "$DATASET_URL"
  echo "Saved to $OUTPUT_FILE"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage ;;
      *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
  done
  download_dataset
}

main "$@"
