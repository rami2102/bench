#!/usr/bin/env bash
# swebench-e2e-all.sh — Run all 4 agents on SWE-bench with Docker harness validation.
#
# Runs pi, codex, claude sequentially (fast agents), then gemini with higher timeout.
# Uses the official SWE-bench Docker harness for proper test validation.
#
# Usage:
#   ./scripts/swebench-e2e-all.sh [options]
#
# Options:
#   --num-tests <N>        Number of tests (default: 2)
#   --instance-ids <csv>   Specific instance IDs
#   --timeout <sec>        Timeout for fast agents (default: 900)
#   --gemini-timeout <sec> Timeout for gemini (default: 5x timeout, i.e. 4500)
#   --fast-agents <csv>    Fast agents (default: pi,codex,claude)
#   --skip-gemini          Skip gemini run
#   --parallel             Run fast agents in parallel
#   --help, -h             Show this help
#
# Examples:
#   ./scripts/swebench-e2e-all.sh --num-tests 2
#   ./scripts/swebench-e2e-all.sh --instance-ids "django__django-11049,sympy__sympy-20590"
#   ./scripts/swebench-e2e-all.sh --num-tests 5 --parallel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
NUM_TESTS=2
INSTANCE_IDS=""
TIMEOUT=900
GEMINI_TIMEOUT=""
FAST_AGENTS="pi,codex,claude"
SKIP_GEMINI=false
PARALLEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --num-tests|-n)      NUM_TESTS="$2"; shift 2 ;;
    --instance-ids)      INSTANCE_IDS="$2"; shift 2 ;;
    --timeout)           TIMEOUT="$2"; shift 2 ;;
    --gemini-timeout)    GEMINI_TIMEOUT="$2"; shift 2 ;;
    --fast-agents)       FAST_AGENTS="$2"; shift 2 ;;
    --skip-gemini)       SKIP_GEMINI=true; shift ;;
    --parallel)          PARALLEL="--parallel"; shift ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

# Default gemini timeout = 5x normal
[[ -z "$GEMINI_TIMEOUT" ]] && GEMINI_TIMEOUT=$((TIMEOUT * 5))

# Build instance selection args
INSTANCE_ARGS=""
if [[ -n "$INSTANCE_IDS" ]]; then
  INSTANCE_ARGS="--instance-ids $INSTANCE_IDS"
else
  INSTANCE_ARGS="--num-tests $NUM_TESTS"
fi

cd "$BENCH_DIR"

echo "============================================="
echo " SWE-Bench E2E — All Agents"
echo " Fast agents: $FAST_AGENTS (timeout: ${TIMEOUT}s)"
echo " Gemini:      $(${SKIP_GEMINI} && echo 'SKIP' || echo "timeout: ${GEMINI_TIMEOUT}s")"
echo " Tests:       ${INSTANCE_IDS:-$NUM_TESTS from round-robin}"
echo " Started:     $(date)"
echo "============================================="
echo ""

# --- Run 1: Fast agents ---
echo ">>> Phase 1: Running $FAST_AGENTS..."
bash scripts/swebench-run-multi.sh \
  --agents "$FAST_AGENTS" \
  $INSTANCE_ARGS \
  --timeout "$TIMEOUT" \
  $PARALLEL \
  2>&1
FAST_EXIT=$?
echo ""
echo ">>> Phase 1 done (exit: $FAST_EXIT)"

# --- Run 2: Gemini (separate, higher timeout) ---
if ! $SKIP_GEMINI; then
  echo ""
  echo ">>> Phase 2: Running gemini (timeout: ${GEMINI_TIMEOUT}s)..."
  bash scripts/swebench-run-multi.sh \
    --agents gemini \
    $INSTANCE_ARGS \
    --timeout "$GEMINI_TIMEOUT" \
    2>&1
  GEMINI_EXIT=$?
  echo ""
  echo ">>> Phase 2 done (exit: $GEMINI_EXIT)"
fi

echo ""
echo "============================================="
echo " E2E COMPLETE — $(date)"
echo "============================================="
echo ""
echo "Results in: $BENCH_DIR/results/swebench/"
echo "Latest runs:"
ls -dt "$BENCH_DIR/results/swebench/"*-host-run 2>/dev/null | head -3
