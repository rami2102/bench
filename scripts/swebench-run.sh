#!/usr/bin/env bash
# swebench-run.sh — Run SWE-Bench Lite tasks against any agent CLI.
#
# Downloads SWE-Bench Lite dataset, picks tasks, clones repos, sends the
# issue text to the agent, captures the git diff, and evaluates results
# using the SWE-bench harness (if installed) or a basic diff check.
#
# Usage:
#   ./swebench-run.sh --agent <agent> [--model <model>] [--num-tests <n>]
#                     [--results-dir <dir>] [--timeout <sec>] [--instance-ids <id,...>]
#
# Flags:
#   --agent, -a          Required. One of: claude, codex, gemini, pi
#   --model, -m          Optional model override
#   --num-tests, -n      Number of random tasks (default: 2)
#   --results-dir, -r    Output directory (default: ../results/swebench)
#   --timeout            Timeout per task in seconds (default: 600)
#   --instance-ids       Comma-separated specific instance IDs to run
#   --use-harness        Use official SWE-bench Docker harness for evaluation
#   --dataset-cache      Path to cache dataset (default: ../cache/swebench)
#   --help, -h           Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
AGENT=""
MODEL=""
NUM_TESTS=2
RESULTS_DIR="$BENCH_DIR/results/swebench"
TIMEOUT=600
INSTANCE_IDS=""
USE_HARNESS=false
VALIDATE=true
DATASET_CACHE="$BENCH_DIR/cache/swebench"

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent|-a)        AGENT="$2"; shift 2 ;;
    --model|-m)        MODEL="$2"; shift 2 ;;
    --num-tests|-n)    NUM_TESTS="$2"; shift 2 ;;
    --results-dir|-r)  RESULTS_DIR="$2"; shift 2 ;;
    --timeout)         TIMEOUT="$2"; shift 2 ;;
    --instance-ids)    INSTANCE_IDS="$2"; shift 2 ;;
    --use-harness)     USE_HARNESS=true; shift ;;
    --no-validate)     VALIDATE=false; shift ;;
    --dataset-cache)   DATASET_CACHE="$2"; shift 2 ;;
    --help|-h)         usage ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$AGENT" ]] && { echo "ERROR: --agent is required" >&2; usage; }

# --- Step 1: Download/cache SWE-Bench Lite dataset ---
DATASET_FILE="$DATASET_CACHE/swe-bench-lite.jsonl"
mkdir -p "$DATASET_CACHE"

if [[ ! -f "$DATASET_FILE" ]]; then
  echo "[swebench] Downloading SWE-Bench Lite dataset..."
  python3 -c "
from datasets import load_dataset
import json, os
ds = load_dataset('princeton-nlp/SWE-bench_Lite', split='test')
out = '${DATASET_FILE}'
with open(out, 'w') as f:
    for item in ds:
        f.write(json.dumps(dict(item)) + '\n')
print(f'Saved {len(ds)} instances to {out}')
" 2>&1 || {
    echo "[swebench] Fallback: downloading via curl..."
    # Alternative: download pre-built JSONL from HuggingFace
    python3 << 'PYEOF'
import urllib.request, json, os
url = "https://huggingface.co/api/datasets/princeton-nlp/SWE-bench_Lite/parquet/default/test"
print("Fetching dataset metadata...")
try:
    # Try using datasets library
    from datasets import load_dataset
    ds = load_dataset('princeton-nlp/SWE-bench_Lite', split='test')
    out = os.environ.get('DATASET_FILE', '/tmp/swe-bench-lite.jsonl')
    with open(out, 'w') as f:
        for item in ds:
            f.write(json.dumps(dict(item)) + '\n')
    print(f'Saved {len(ds)} instances')
except Exception as e:
    print(f"Error: {e}")
    print("Please install: pip install datasets")
    exit(1)
PYEOF
  }
fi

if [[ ! -f "$DATASET_FILE" ]]; then
  echo "ERROR: Could not download dataset. Install 'datasets': pip install datasets" >&2
  exit 1
fi

TOTAL_INSTANCES=$(wc -l < "$DATASET_FILE")
echo "[swebench] Dataset: $TOTAL_INSTANCES instances"

# --- Step 2: Select instances ---
SELECTED_FILE="$DATASET_CACHE/selected-instances.jsonl"

if [[ -n "$INSTANCE_IDS" ]]; then
  # Pick specific instances
  IFS=',' read -ra IDS <<< "$INSTANCE_IDS"
  > "$SELECTED_FILE"
  for id in "${IDS[@]}"; do
    grep "\"instance_id\": \"$id\"" "$DATASET_FILE" >> "$SELECTED_FILE" || \
      echo "WARNING: Instance $id not found" >&2
  done
  NUM_TESTS=$(wc -l < "$SELECTED_FILE")
else
  # Random sample
  python3 -c "
import json, random, sys
lines = open('${DATASET_FILE}').readlines()
n = min(${NUM_TESTS}, len(lines))
sample = random.sample(lines, n)
with open('${SELECTED_FILE}', 'w') as f:
    for line in sample:
        f.write(line)
print(f'Selected {n} instances')
"
fi

# --- Step 3: Run agent on each instance ---
RUN_ID="$(date +%Y%m%d-%H%M%S)-${AGENT}"
RUN_DIR="$RESULTS_DIR/$RUN_ID"
PREDICTIONS_FILE="$RUN_DIR/predictions.json"
mkdir -p "$RUN_DIR"

echo "============================================="
echo " SWE-Bench Lite Runner"
echo " Agent:   $AGENT"
echo " Model:   ${MODEL:-default}"
echo " Tasks:   $NUM_TESTS"
echo " Timeout: ${TIMEOUT}s per task"
echo " Output:  $RUN_DIR"
echo "============================================="

PASSED=0
FAILED=0
ERRORS=0
TOTAL_DURATION=0
PREDICTIONS=()

IDX=0
while IFS= read -r LINE; do
  IDX=$((IDX+1))

  INSTANCE_ID=$(echo "$LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['instance_id'])")
  REPO=$(echo "$LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['repo'])")
  BASE_COMMIT=$(echo "$LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['base_commit'])")
  ISSUE_TEXT=$(echo "$LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['problem_statement'])")
  HINTS=$(echo "$LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hints_text',''))")

  echo ""
  echo "--- [$IDX/$NUM_TESTS] $INSTANCE_ID ---"
  echo "    Repo: $REPO @ $BASE_COMMIT"

  TASK_DIR="$RUN_DIR/task-$(printf '%03d' $IDX)-${INSTANCE_ID//\//-}"
  mkdir -p "$TASK_DIR"

  # Clone and checkout the base commit
  WORKSPACE="$TASK_DIR/workspace"
  REPO_CACHE="$DATASET_CACHE/repos/${REPO//\//-}"

  echo "    Cloning repo..."
  if [[ -d "$REPO_CACHE" ]]; then
    # Use cached repo
    git clone "$REPO_CACHE" "$WORKSPACE" 2>/dev/null
  else
    # Clone from GitHub and cache
    mkdir -p "$(dirname "$REPO_CACHE")"
    git clone "https://github.com/$REPO.git" "$REPO_CACHE" 2>/dev/null || true
    if [[ -d "$REPO_CACHE" ]]; then
      git clone "$REPO_CACHE" "$WORKSPACE" 2>/dev/null
    else
      git clone "https://github.com/$REPO.git" "$WORKSPACE" 2>/dev/null
    fi
  fi

  cd "$WORKSPACE"
  git checkout "$BASE_COMMIT" 2>/dev/null || {
    # If shallow clone, fetch more
    git fetch --unshallow 2>/dev/null || git fetch 2>/dev/null || true
    git checkout "$BASE_COMMIT" 2>/dev/null || {
      echo "    ⚠️ Could not checkout $BASE_COMMIT, skipping"
      ERRORS=$((ERRORS+1))
      continue
    }
  }
  cd "$SCRIPT_DIR"

  # Build prompt
  AGENT_PROMPT="You are a software engineer working on the repository '$REPO'.

Fix the following GitHub issue by modifying the source code. Make only the minimal changes needed.

## Issue Description

$ISSUE_TEXT"

  [[ -n "$HINTS" ]] && AGENT_PROMPT+="

## Hints

$HINTS"

  # Save prompt
  echo "$AGENT_PROMPT" > "$TASK_DIR/prompt.txt"

  # Run agent
  START_TIME=$(date +%s)
  set +e
  timeout "$TIMEOUT" bash "$SCRIPT_DIR/agent-run.sh" \
    "$AGENT" "$WORKSPACE" "$AGENT_PROMPT" "$MODEL" \
    > "$TASK_DIR/agent-output.txt" 2>&1
  EXIT_CODE=$?
  set -e
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  TOTAL_DURATION=$((TOTAL_DURATION + DURATION))

  # Capture patch
  cd "$WORKSPACE"
  PATCH="$(git diff 2>/dev/null || true)"
  NEW_FILES="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  # Add new files to diff
  if [[ -n "$NEW_FILES" ]]; then
    git add $NEW_FILES 2>/dev/null || true
    PATCH="$(git diff --cached 2>/dev/null || true)
$PATCH"
  fi
  cd "$SCRIPT_DIR"

  echo "$PATCH" > "$TASK_DIR/patch.diff"

  # Evaluate — Level 1: basic checks
  STATUS="unknown"
  RESOLVED=false
  if [[ $EXIT_CODE -eq 124 ]]; then
    STATUS="timeout"
    ERRORS=$((ERRORS+1))
    echo "    ⏱️ timeout (${DURATION}s)"
  elif [[ $EXIT_CODE -ne 0 ]]; then
    STATUS="error"
    ERRORS=$((ERRORS+1))
    echo "    💥 error exit=$EXIT_CODE (${DURATION}s)"
  elif [[ -z "$PATCH" ]]; then
    STATUS="no_patch"
    FAILED=$((FAILED+1))
    echo "    ❌ no patch generated (${DURATION}s)"
  else
    DIFF_LINES=$(echo "$PATCH" | wc -l)
    echo "    📝 patch: ${DIFF_LINES} lines (${DURATION}s)"

    # Evaluate — Level 2: run actual tests (unless --no-validate)
    if $VALIDATE; then
      echo "    🧪 Validating patch with project tests..."
      set +e
      bash "$SCRIPT_DIR/swebench-validate.sh" "$TASK_DIR" "$LINE" \
        > "$TASK_DIR/validation-output.txt" 2>&1
      VALIDATE_EXIT=$?
      set -e

      if [[ $VALIDATE_EXIT -eq 0 ]]; then
        STATUS="resolved"
        RESOLVED=true
        PASSED=$((PASSED+1))
        echo "    ✅ RESOLVED — tests pass (${DURATION}s)"
      else
        # Parse validation result for details
        VERDICT="not_resolved"
        if [[ -f "$TASK_DIR/validation-result.json" ]]; then
          VERDICT=$(python3 -c "import json; print(json.load(open('${TASK_DIR}/validation-result.json'))['verdict'])" 2>/dev/null || echo "not_resolved")
        fi
        STATUS="$VERDICT"
        FAILED=$((FAILED+1))

        case "$VERDICT" in
          partially_resolved)
            echo "    ⚠️ PARTIAL — some tests pass (${DURATION}s)"
            ;;
          tests_not_runnable)
            echo "    🔧 SKIP — tests could not run (deps issue) (${DURATION}s)"
            ;;
          *)
            echo "    ❌ NOT RESOLVED — tests still fail (${DURATION}s)"
            ;;
        esac

        # Show failing test details
        if [[ -f "$TASK_DIR/validation-output.txt" ]]; then
          grep -E "^\[validate\]|FAIL:|PASS:|REGRESSION:" "$TASK_DIR/validation-output.txt" | tail -10 | sed 's/^/    /'
        fi
      fi
    else
      STATUS="patch_generated"
      PASSED=$((PASSED+1))
      echo "    📝 patch generated (no validation) (${DURATION}s)"
    fi
  fi

  # Build prediction entry (SWE-bench format)
  PREDICTION=$(python3 -c "
import json, sys
patch = open('${TASK_DIR}/patch.diff').read()
pred = {
    'instance_id': '${INSTANCE_ID}',
    'model_patch': patch,
    'model_name_or_path': '${AGENT}-${MODEL:-default}'
}
print(json.dumps(pred))
")
  PREDICTIONS+=("$PREDICTION")

  # Save task result
  PATCH_LINES=0
  [[ -n "$PATCH" ]] && PATCH_LINES=$(echo "$PATCH" | wc -l)
  cat > "$TASK_DIR/result.json" << ENDJSON
{
  "instance_id": "$INSTANCE_ID",
  "repo": "$REPO",
  "agent": "$AGENT",
  "model": "${MODEL:-default}",
  "status": "$STATUS",
  "resolved": $RESOLVED,
  "exit_code": $EXIT_CODE,
  "duration_seconds": $DURATION,
  "patch_lines": $PATCH_LINES
}
ENDJSON

done < "$SELECTED_FILE"

# --- Step 4: Write predictions file ---
echo "[" > "$PREDICTIONS_FILE"
for i in "${!PREDICTIONS[@]}"; do
  echo "${PREDICTIONS[$i]}" >> "$PREDICTIONS_FILE"
  [[ $i -lt $((${#PREDICTIONS[@]}-1)) ]] && echo "," >> "$PREDICTIONS_FILE"
done
echo "]" >> "$PREDICTIONS_FILE"

# --- Step 5: Run SWE-bench harness (if requested and available) ---
if $USE_HARNESS; then
  echo ""
  echo "[swebench] Running official evaluation harness..."
  if python3 -c "import swebench" 2>/dev/null; then
    cd "$RUN_DIR"
    python3 -m swebench.harness.run_evaluation \
      --dataset_name princeton-nlp/SWE-bench_Lite \
      --predictions_path "$PREDICTIONS_FILE" \
      --max_workers 2 \
      --run_id "$RUN_ID" 2>&1 | tee "$RUN_DIR/harness-output.txt"
  else
    echo "WARNING: swebench package not installed. Skipping harness evaluation."
    echo "Install with: cd ~/git/SWE-bench && pip install -e ."
  fi
fi

# --- Summary ---
echo ""
echo "============================================="
echo " SWE-BENCH LITE RESULTS"
echo "============================================="
VALIDATED_LABEL="Resolved"
$VALIDATE || VALIDATED_LABEL="Patches made"
echo " Agent:           $AGENT (${MODEL:-default})"
echo " Total tasks:     $NUM_TESTS"
echo " ${VALIDATED_LABEL}:    $PASSED ✅"
echo " Failed:          $FAILED ❌"
echo " Errors/timeouts: $ERRORS 💥"
echo " Validation:      $($VALIDATE && echo 'ENABLED (tests run)' || echo 'DISABLED (patch-only)')"
echo " Total duration:  ${TOTAL_DURATION}s"
echo " Predictions:     $PREDICTIONS_FILE"
echo " Results dir:     $RUN_DIR"
echo "============================================="

cat > "$RUN_DIR/summary.json" << ENDJSON
{
  "run_id": "$RUN_ID",
  "benchmark": "swe-bench-lite",
  "agent": "$AGENT",
  "model": "${MODEL:-default}",
  "total_tasks": $NUM_TESTS,
  "validated": $VALIDATE,
  "resolved": $PASSED,
  "failed": $FAILED,
  "errors": $ERRORS,
  "total_duration_seconds": $TOTAL_DURATION,
  "predictions_file": "$PREDICTIONS_FILE",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
ENDJSON

echo ""
echo "To evaluate with official SWE-bench harness:"
echo "  cd ~/git/SWE-bench && source .venv/bin/activate"
echo "  python -m swebench.harness.run_evaluation \\"
echo "    --dataset_name princeton-nlp/SWE-bench_Lite \\"
echo "    --predictions_path $PREDICTIONS_FILE \\"
echo "    --max_workers 4 --run_id $RUN_ID"
