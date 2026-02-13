#!/usr/bin/env bash
# bench.sh — Unified entry point for all benchmarks
#
# Usage:
#   ./bench.sh <benchmark> --agent <agent> [options]
#
# Benchmarks: youbencha, swebench
# Agents:     claude, codex, gemini, pi
#
# Examples:
#   ./bench.sh youbencha --agent pi --num-tests 2
#   ./bench.sh swebench  --agent claude --num-tests 1
#   ./bench.sh youbencha --agent gemini --model gemini-2.5-pro -n 3
#   ./bench.sh swebench  --agent codex -n 2 --timeout 900

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK="${1:-}"

if [[ -z "$BENCHMARK" || "$BENCHMARK" == "--help" || "$BENCHMARK" == "-h" ]]; then
  echo "Usage: bench.sh <benchmark> --agent <agent> [options]"
  echo ""
  echo "Benchmarks:"
  echo "  youbencha   Custom TDD-style coding tasks (5 built-in tests)"
  echo "  swebench    SWE-Bench Lite real GitHub issues (300 tasks)"
  echo "  multilang   Multi-language coding tasks (400 tasks, 8 languages)"
  echo ""
  echo "Agents:  claude | codex | gemini | pi"
  echo ""
  echo "Options (both benchmarks):"
  echo "  --agent, -a     Agent to test (required)"
  echo "  --model, -m     Model override"
  echo "  --num-tests, -n Number of tests to run (default: all/2)"
  echo "  --timeout       Seconds per task (default: 300/600)"
  echo ""
  echo "Examples:"
  echo "  bench.sh youbencha -a pi -n 2        # Quick pi test, 2 tasks"
  echo "  bench.sh swebench -a claude -n 1     # Single SWE-bench task"
  echo "  bench.sh youbencha -a gemini -n 5    # All 5 youbencha tasks"
  echo "  bench.sh multilang -a pi -n 10       # 10 multi-language tasks"
  exit 0
fi

shift

# Init youbencha tests if needed
if [[ "$BENCHMARK" == "youbencha" && ! -d "$SCRIPT_DIR/../tests/youbencha" ]]; then
  echo "[bench] Initializing youBencha test cases..."
  bash "$SCRIPT_DIR/youbencha-init.sh"
fi

case "$BENCHMARK" in
  youbencha)
    exec bash "$SCRIPT_DIR/youbencha-run.sh" "$@"
    ;;
  swebench)
    exec bash "$SCRIPT_DIR/swebench-run.sh" "$@"
    ;;
  multilang)
    exec bash "$SCRIPT_DIR/languages/multilang-run.sh" "$@"
    ;;
  *)
    echo "ERROR: Unknown benchmark '$BENCHMARK'. Use: youbencha, swebench, multilang" >&2
    exit 1
    ;;
esac
