#!/usr/bin/env bash
# light-test.sh — quick, low-cost benchmark preset for all agents
#
# Runs:
#   1) a small local youBencha suite (2 tasks)
#   2) SWE-Bench Lite in random OR selected mode
#
# Usage:
#   ./scripts/light-test.sh --agent pi
#   ./scripts/light-test.sh --agent claude --model claude-sonnet-4-20250514 --swebench-mode selected
#
# Flags:
#   --agent <name>               Required: claude|codex|gemini|pi
#   --model <model>              Optional model override
#   --youbencha-tests <n>        Number of light youBencha tests (default: 2)
#   --swebench-mode <mode>       random|selected (default: random)
#   --swebench-tests <n>         Number of SWE-Bench tasks in random mode (default: 1)
#   --selected-file <path>       Instance ID file for selected mode
#   --timeout-youbencha <sec>    Per-task timeout for youBencha (default: 180)
#   --timeout-swebench <sec>     Per-task timeout for SWE-Bench (default: 600)
#   -h, --help                   Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

AGENT=""
MODEL=""
YOUBENCHA_TESTS=2
SWEBENCH_MODE="random"
SWEBENCH_TESTS=1
SELECTED_FILE="$ROOT_DIR/configs/swebench/light-selected-instance-ids.txt"
TIMEOUT_YOUBENCHA=180
TIMEOUT_SWEBENCH=600

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --youbencha-tests) YOUBENCHA_TESTS="$2"; shift 2 ;;
    --swebench-mode) SWEBENCH_MODE="$2"; shift 2 ;;
    --swebench-tests) SWEBENCH_TESTS="$2"; shift 2 ;;
    --selected-file) SELECTED_FILE="$2"; shift 2 ;;
    --timeout-youbencha) TIMEOUT_YOUBENCHA="$2"; shift 2 ;;
    --timeout-swebench) TIMEOUT_SWEBENCH="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$AGENT" ]] && { echo "ERROR: --agent is required" >&2; usage; }

EXTRA_ARGS=()
[[ -n "$MODEL" ]] && EXTRA_ARGS+=(--model "$MODEL")
echo "[light-test] Running youBencha light suite (${YOUBENCHA_TESTS} tests)..."
bash "$SCRIPT_DIR/bench.sh" youbencha \
  --agent "$AGENT" \
  --tests-dir "$ROOT_DIR/tests/youbencha-light" \
  --num-tests "$YOUBENCHA_TESTS" \
  --timeout "$TIMEOUT_YOUBENCHA" \
  "${EXTRA_ARGS[@]}"

echo ""
echo "[light-test] Running SWE-Bench Lite (${SWEBENCH_MODE} mode)..."
if [[ "$SWEBENCH_MODE" == "selected" ]]; then
  [[ -f "$SELECTED_FILE" ]] || { echo "ERROR: selected file not found: $SELECTED_FILE" >&2; exit 1; }
  INSTANCE_IDS="$(grep -v '^\s*#' "$SELECTED_FILE" | grep -v '^\s*$' | paste -sd, -)"
  [[ -n "$INSTANCE_IDS" ]] || { echo "ERROR: selected file has no instance IDs" >&2; exit 1; }

  bash "$SCRIPT_DIR/bench.sh" swebench \
    --agent "$AGENT" \
    --instance-ids "$INSTANCE_IDS" \
    --timeout "$TIMEOUT_SWEBENCH" \
    "${EXTRA_ARGS[@]}"
else
  bash "$SCRIPT_DIR/bench.sh" swebench \
    --agent "$AGENT" \
    --num-tests "$SWEBENCH_TESTS" \
    --timeout "$TIMEOUT_SWEBENCH" \
    "${EXTRA_ARGS[@]}"
fi

echo ""
echo "[light-test] Done."
