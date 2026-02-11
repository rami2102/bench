#!/usr/bin/env bash
# youbencha-run.sh — Run youBencha-style benchmark tasks against any agent CLI.
#
# Instead of requiring the youBencha npm adapter system, this script drives
# agents directly via agent-run.sh and evaluates results with git-diff + an
# optional agentic judge.
#
# Usage:
#   ./youbencha-run.sh --agent <agent> [--model <model>] [--num-tests <n>]
#                      [--tests-dir <dir>] [--results-dir <dir>]
#
# Flags:
#   --agent, -a       Required. One of: claude, codex, gemini, pi
#   --model, -m       Optional model override
#   --num-tests, -n   Limit number of tests to run (default: all)
#   --tests-dir, -t   Directory containing test YAML files (default: ../tests/youbencha)
#   --results-dir, -r Output directory (default: ../results/youbencha)
#   --timeout         Timeout per task in seconds (default: 300)
#   --help, -h        Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
AGENT=""
MODEL=""
NUM_TESTS=0  # 0 = all
TESTS_DIR="$BENCH_DIR/tests/youbencha"
RESULTS_DIR="$BENCH_DIR/results/youbencha"
TIMEOUT=300

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent|-a)   AGENT="$2"; shift 2 ;;
    --model|-m)   MODEL="$2"; shift 2 ;;
    --num-tests|-n) NUM_TESTS="$2"; shift 2 ;;
    --tests-dir|-t) TESTS_DIR="$2"; shift 2 ;;
    --results-dir|-r) RESULTS_DIR="$2"; shift 2 ;;
    --timeout)    TIMEOUT="$2"; shift 2 ;;
    --help|-h)    usage ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$AGENT" ]] && { echo "ERROR: --agent is required" >&2; usage; }

# Validate agent
case "$AGENT" in
  claude|codex|gemini|pi) ;;
  *) echo "ERROR: Unknown agent '$AGENT'" >&2; exit 1 ;;
esac

# Check tests dir
if [[ ! -d "$TESTS_DIR" ]]; then
  echo "ERROR: Tests directory not found: $TESTS_DIR" >&2
  echo "Run: $SCRIPT_DIR/youbencha-init.sh to create sample tests" >&2
  exit 1
fi

# Collect test files
mapfile -t TEST_FILES < <(find "$TESTS_DIR" -name '*.yaml' -o -name '*.yml' | sort)
TOTAL=${#TEST_FILES[@]}

if [[ $TOTAL -eq 0 ]]; then
  echo "ERROR: No test YAML files found in $TESTS_DIR" >&2
  exit 1
fi

# Limit if requested
if [[ $NUM_TESTS -gt 0 && $NUM_TESTS -lt $TOTAL ]]; then
  TEST_FILES=("${TEST_FILES[@]:0:$NUM_TESTS}")
  echo "[youbencha] Limiting to $NUM_TESTS of $TOTAL tests"
fi

RUN_TOTAL=${#TEST_FILES[@]}
RUN_ID="$(date +%Y%m%d-%H%M%S)-${AGENT}"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

echo "============================================="
echo " youBencha Benchmark Runner"
echo " Agent:   $AGENT"
echo " Model:   ${MODEL:-default}"
echo " Tests:   $RUN_TOTAL / $TOTAL"
echo " Timeout: ${TIMEOUT}s per task"
echo " Output:  $RUN_DIR"
echo "============================================="

PASSED=0
FAILED=0
ERRORS=0
TOTAL_DURATION=0

# Simple YAML parser (key: value on separate lines)
yaml_get() {
  local file="$1" key="$2"
  grep "^${key}:" "$file" 2>/dev/null | sed "s/^${key}:[[:space:]]*//" | sed 's/^["'\'']\(.*\)["'\'']$/\1/'
}

for i in "${!TEST_FILES[@]}"; do
  TEST_FILE="${TEST_FILES[$i]}"
  TEST_NAME="$(yaml_get "$TEST_FILE" "name")"
  TEST_DESC="$(yaml_get "$TEST_FILE" "description")"
  TEST_REPO="$(yaml_get "$TEST_FILE" "repo")"
  TEST_BRANCH="$(yaml_get "$TEST_FILE" "branch")"
  PROMPT="$(yaml_get "$TEST_FILE" "prompt")"
  EXPECTED_FILE="$(yaml_get "$TEST_FILE" "expected_file")"
  EXPECTED_PATTERN="$(yaml_get "$TEST_FILE" "expected_pattern")"

  TEST_ID="$(printf "%03d" $((i+1)))"
  TASK_DIR="$RUN_DIR/task-${TEST_ID}"
  mkdir -p "$TASK_DIR"

  echo ""
  echo "--- [$TEST_ID/$RUN_TOTAL] $TEST_NAME ---"
  echo "    $TEST_DESC"

  # Clone repo into workspace
  WORKSPACE="$TASK_DIR/workspace"
  if [[ -n "$TEST_REPO" && "$TEST_REPO" != "local" ]]; then
    BRANCH_FLAG=""
    [[ -n "$TEST_BRANCH" ]] && BRANCH_FLAG="--branch $TEST_BRANCH"
    git clone --depth 1 $BRANCH_FLAG "$TEST_REPO" "$WORKSPACE" 2>/dev/null
  else
    # Local test — copy tests dir as workspace
    WORKSPACE="$TASK_DIR/workspace"
    LOCAL_SRC="$(yaml_get "$TEST_FILE" "local_src")"
    if [[ -n "$LOCAL_SRC" ]]; then
      cp -r "$LOCAL_SRC" "$WORKSPACE"
    else
      mkdir -p "$WORKSPACE"
      echo "# Test workspace" > "$WORKSPACE/README.md"
    fi
  fi

  # Run agent
  START_TIME=$(date +%s)
  set +e
  timeout "$TIMEOUT" bash "$SCRIPT_DIR/agent-run.sh" \
    "$AGENT" "$WORKSPACE" "$PROMPT" "$MODEL" \
    > "$TASK_DIR/agent-output.txt" 2>&1
  EXIT_CODE=$?
  set -e
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  TOTAL_DURATION=$((TOTAL_DURATION + DURATION))

  # Evaluate results
  STATUS="unknown"
  EVAL_NOTES=""

  if [[ $EXIT_CODE -eq 124 ]]; then
    STATUS="timeout"
    EVAL_NOTES="Agent timed out after ${TIMEOUT}s"
    ERRORS=$((ERRORS+1))
  elif [[ $EXIT_CODE -ne 0 ]]; then
    STATUS="error"
    EVAL_NOTES="Agent exited with code $EXIT_CODE"
    ERRORS=$((ERRORS+1))
  else
    # Check 1: Did files change? (git diff)
    if [[ -d "$WORKSPACE/.git" ]]; then
      DIFF="$(cd "$WORKSPACE" && git diff 2>/dev/null || true)"
      UNTRACKED="$(cd "$WORKSPACE" && git ls-files --others --exclude-standard 2>/dev/null || true)"
    else
      DIFF=""
      UNTRACKED=""
    fi

    # Check 2: Expected file exists? (case-insensitive search)
    FILE_OK=true
    ACTUAL_FILE=""
    if [[ -n "$EXPECTED_FILE" ]]; then
      if [[ -f "$WORKSPACE/$EXPECTED_FILE" ]]; then
        ACTUAL_FILE="$WORKSPACE/$EXPECTED_FILE"
        FILE_OK=true
      else
        # Case-insensitive fallback — find largest matching file (not empty git artifacts)
        ACTUAL_FILE="$(find "$WORKSPACE" -maxdepth 3 -iname "$(basename "$EXPECTED_FILE")" -not -empty -print -quit 2>/dev/null || true)"
        if [[ -n "$ACTUAL_FILE" && -f "$ACTUAL_FILE" ]]; then
          FILE_OK=true
        else
          FILE_OK=false
        fi
      fi
    fi

    # Check 3: Expected pattern in file?
    PATTERN_OK=true
    if [[ -n "$EXPECTED_PATTERN" && -n "$ACTUAL_FILE" && -f "$ACTUAL_FILE" ]]; then
      if grep -qE "$EXPECTED_PATTERN" "$ACTUAL_FILE" 2>/dev/null; then
        PATTERN_OK=true
      else
        PATTERN_OK=false
      fi
    elif [[ -n "$EXPECTED_PATTERN" && -z "$ACTUAL_FILE" ]]; then
      PATTERN_OK=false
    fi

    # Determine pass/fail
    if [[ -n "$DIFF" || -n "$UNTRACKED" ]] && $FILE_OK && $PATTERN_OK; then
      STATUS="pass"
      PASSED=$((PASSED+1))
    else
      STATUS="fail"
      FAILED=$((FAILED+1))
      [[ -z "$DIFF" && -z "$UNTRACKED" ]] && EVAL_NOTES="No file changes detected. "
      $FILE_OK || EVAL_NOTES+="Expected file '$EXPECTED_FILE' not found. "
      $PATTERN_OK || EVAL_NOTES+="Pattern '$EXPECTED_PATTERN' not matched. "
    fi

    # Save diff
    echo "$DIFF" > "$TASK_DIR/git-diff.patch"
    echo "$UNTRACKED" > "$TASK_DIR/untracked-files.txt"
  fi

  # Write task result JSON
  cat > "$TASK_DIR/result.json" << ENDJSON
{
  "test_id": "$TEST_ID",
  "test_name": "$TEST_NAME",
  "agent": "$AGENT",
  "model": "${MODEL:-default}",
  "status": "$STATUS",
  "exit_code": $EXIT_CODE,
  "duration_seconds": $DURATION,
  "notes": "$EVAL_NOTES",
  "test_file": "$TEST_FILE"
}
ENDJSON

  # Print result
  case "$STATUS" in
    pass)    ICON="✅" ;;
    fail)    ICON="❌" ;;
    timeout) ICON="⏱️" ;;
    error)   ICON="💥" ;;
    *)       ICON="❓" ;;
  esac
  echo "    $ICON $STATUS (${DURATION}s) ${EVAL_NOTES}"
done

# Summary
echo ""
echo "============================================="
echo " RESULTS SUMMARY"
echo "============================================="
echo " Agent:    $AGENT (${MODEL:-default})"
echo " Total:    $RUN_TOTAL"
echo " Passed:   $PASSED ✅"
echo " Failed:   $FAILED ❌"
echo " Errors:   $ERRORS 💥"
echo " Duration: ${TOTAL_DURATION}s"
echo " Results:  $RUN_DIR"
echo "============================================="

# Write summary JSON
cat > "$RUN_DIR/summary.json" << ENDJSON
{
  "run_id": "$RUN_ID",
  "agent": "$AGENT",
  "model": "${MODEL:-default}",
  "total_tests": $RUN_TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "errors": $ERRORS,
  "total_duration_seconds": $TOTAL_DURATION,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

# Exit with failure if any test failed
[[ $FAILED -eq 0 && $ERRORS -eq 0 ]] && exit 0 || exit 1
