#!/usr/bin/env bash
# multilang-run.sh — Run Multi-SWE-bench_mini tasks against any agent CLI.
#
# Uses the Multi-SWE-bench_mini dataset (400 tasks, 8 languages: Python,
# JavaScript, TypeScript, Java, C++, Go, Rust, C) to evaluate coding agents
# on real GitHub issue resolution across multiple programming languages.
#
# Usage:
#   ./multilang-run.sh --agent <agent> [--model <model>] [--num-tests <n>]
#                      [--results-dir <dir>] [--timeout <sec>] [--instance-ids <id,...>]
#
# Flags:
#   --agent, -a          Required. One of: claude, codex, gemini, pi
#   --model, -m          Optional model override
#   --num-tests, -n      Number of tasks (default: 8, one per language)
#   --results-dir, -r    Output directory (default: results/multilang)
#   --timeout            Timeout per task in seconds (default: 600)
#   --instance-ids       Comma-separated specific instance IDs to run
#   --test-list-file     Ordered ID list file (default: round-robin-by-language.md)
#   --validate           Enable lightweight validation (apply test_patch + run tests)
#   --dataset-cache      Path to cache dataset (default: cache/multilang)
#   --language, -l       Filter to specific language(s), comma-separated
#   --help, -h           Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

AGENT="" MODEL="" NUM_TESTS=8 TIMEOUT=600
RESULTS_DIR="$BENCH_DIR/results/multilang"
INSTANCE_IDS="" VALIDATE=false LANGUAGE_FILTER=""
DATASET_CACHE="$BENCH_DIR/cache/multilang"
TEST_LIST_FILE="$BENCH_DIR/tests/multilang/round-robin-by-language.md"
DATASET_FILE="" RUN_ID="" RUN_DIR="" PREDICTIONS_FILE="" SELECTED_FILE=""
PASSED=0 FAILED=0 ERRORS=0 TOTAL_DURATION=0
declare -a PREDICTIONS=()
declare -A LANG_PASSED=() LANG_TOTAL=()
EXIT_CODE=0 DURATION=0 PATCH="" STATUS="" RESOLVED=false
INSTANCE_ID="" ORG="" REPO="" LANGUAGE="" DIFFICULTY="" BASE_SHA=""
TASK_DIR="" TASK_WORKSPACE=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent|-a)        AGENT="$2"; shift 2 ;;
      --model|-m)        MODEL="$2"; shift 2 ;;
      --num-tests|-n)    NUM_TESTS="$2"; shift 2 ;;
      --results-dir|-r)  RESULTS_DIR="$2"; shift 2 ;;
      --timeout)         TIMEOUT="$2"; shift 2 ;;
      --instance-ids)    INSTANCE_IDS="$2"; shift 2 ;;
      --test-list-file)  TEST_LIST_FILE="$2"; shift 2 ;;
      --validate)        VALIDATE=true; shift ;;
      --dataset-cache)   DATASET_CACHE="$2"; shift 2 ;;
      --language|-l)     LANGUAGE_FILTER="$2"; shift 2 ;;
      --help|-h)         usage ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
  done
  if [[ -z "$AGENT" ]]; then echo "ERROR: --agent is required" >&2; usage; fi
}

ensure_dataset() {
  DATASET_FILE="$DATASET_CACHE/multi-swe-bench-mini.jsonl"
  mkdir -p "$DATASET_CACHE"
  if [[ ! -f "$DATASET_FILE" ]]; then
    echo "[multilang] Downloading Multi-SWE-bench_mini dataset..."
    local url="https://huggingface.co/datasets/ByteDance-Seed/Multi-SWE-bench_mini"
    curl -L -o "$DATASET_FILE" "$url/resolve/main/multi_swe_bench_mini.jsonl" \
      --max-time 120 2>&1
  fi
  if [[ ! -f "$DATASET_FILE" ]]; then echo "ERROR: Could not download dataset." >&2; exit 1; fi
  echo "[multilang] Dataset: $(wc -l < "$DATASET_FILE") instances across 8 languages"
}

init_run_dir() {
  RUN_ID="$(date +%Y%m%d-%H%M%S)-${AGENT}"
  RUN_DIR="$RESULTS_DIR/$RUN_ID"
  PREDICTIONS_FILE="$RUN_DIR/predictions.json"
  SELECTED_FILE="$RUN_DIR/selected-instances.jsonl"
  mkdir -p "$RUN_DIR"
}

select_by_instance_ids() {
  python3 - "$INSTANCE_IDS" "$DATASET_FILE" "$SELECTED_FILE" <<'PY'
import json, sys
ids_csv, dataset_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
ids = [i.strip() for i in ids_csv.split(',')]
dataset = {}
for line in open(dataset_path):
    d = json.loads(line); dataset[d['instance_id']] = line.strip()
found = 0
with open(out_path, 'w') as f:
    for iid in ids:
        if iid in dataset: f.write(dataset[iid] + '\n'); found += 1
        else: print(f'WARNING: Instance {iid} not found', file=sys.stderr)
print(f'Selected {found} instances')
PY
}

select_from_test_list() {
  python3 - "$TEST_LIST_FILE" "$LANGUAGE_FILTER" "$NUM_TESTS" \
            "$DATASET_FILE" "$SELECTED_FILE" <<'PY'
import json, re, sys; a = sys.argv
list_path, lang_csv, num, ds_path, out_path = a[1:6]
ids = [re.sub(r'^[-*]\s*','',l.strip()) for l in open(list_path)
       if l.strip() and not l.strip().startswith('#')]
if lang_csv.strip():
    alias = {'javascript':'js','typescript':'ts','cpp':'c++'}
    al = {alias.get(l.strip(),l.strip()) for l in lang_csv.split(',')}
    ds = {json.loads(l)['instance_id']:json.loads(l)['language'] for l in open(ds_path)}
    ids = [i for i in ids if ds.get(i,'') in al]
n = len(ids) if num == 'all' else min(int(num), len(ids))
ds = {json.loads(l)['instance_id']:l.strip() for l in open(ds_path)}
with open(out_path,'w') as f:
    for iid in ids[:n]:
        if iid in ds: f.write(ds[iid]+'\n')
print(f'Selected {n} instances')
PY
}

select_random() {
  python3 - "$NUM_TESTS" "$DATASET_FILE" "$SELECTED_FILE" <<'PY'
import json, random, sys
n, ds_path, out_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = open(ds_path).readlines()
sample = random.sample(lines, min(n, len(lines)))
with open(out_path, 'w') as f:
    for line in sample: f.write(line)
print(f'Selected {len(sample)} instances')
PY
}

select_instances() {
  if [[ -n "$INSTANCE_IDS" ]]; then
    select_by_instance_ids
  elif [[ -f "$TEST_LIST_FILE" ]]; then
    select_from_test_list
  else
    select_random
  fi
  NUM_TESTS=$(wc -l < "$SELECTED_FILE")
}

print_banner() {
  echo "============================================="
  echo " Multi-Language Benchmark Runner"
  echo " Agent:     $AGENT"
  echo " Model:     ${MODEL:-default}"
  echo " Tasks:     $NUM_TESTS"
  echo " Timeout:   ${TIMEOUT}s per task"
  echo " Validate:  $VALIDATE"
  echo " Languages: ${LANGUAGE_FILTER:-all 8}"
  echo " Output:    $RUN_DIR"
  echo "============================================="
}

parse_instance() {
  local line="$1"
  INSTANCE_ID=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['instance_id'])")
  ORG=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['org'])")
  REPO=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['repo'])")
  LANGUAGE=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['language'])")
  DIFFICULTY=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('difficulty','unknown'))")
  BASE_SHA=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['base']['sha'])")
}

build_issue_text() {
  echo "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin); parts = []
if d.get('body'): parts.append(d['body'])
for issue in d.get('resolved_issues', []):
    if issue.get('body'):
        parts.append(f\"### Issue #{issue['number']}: {issue.get('title','')}\n{issue['body']}\")
print('\n\n'.join(parts))
"
}

lang_display() {
  case "$1" in
    js) echo "JavaScript" ;; ts) echo "TypeScript" ;;
    c++) echo "C++" ;; java) echo "Java" ;;
    python) echo "Python" ;; go) echo "Go" ;;
    rust) echo "Rust" ;; c) echo "C" ;; *) echo "$1" ;;
  esac
}

clone_repo() {
  local org="$1" repo="$2" workspace="$3"
  local repo_cache="$DATASET_CACHE/repos/${org}-${repo}"
  if [[ -d "$repo_cache" ]]; then
    git clone "$repo_cache" "$workspace" 2>/dev/null; return
  fi
  mkdir -p "$(dirname "$repo_cache")"
  git clone "https://github.com/$org/$repo.git" "$repo_cache" 2>/dev/null || true
  if [[ -d "$repo_cache" ]]; then
    git clone "$repo_cache" "$workspace" 2>/dev/null
  else
    git clone "https://github.com/$org/$repo.git" "$workspace" 2>/dev/null
  fi
}

checkout_base() {
  local workspace="$1" sha="$2"
  cd "$workspace"
  git checkout "$sha" 2>/dev/null || {
    git fetch --unshallow 2>/dev/null || git fetch 2>/dev/null || true
    git checkout "$sha" 2>/dev/null
  }
  cd "$SCRIPT_DIR"
}

build_prompt() {
  local lang_name="$1" org="$2" repo="$3" issue="$4"
  cat <<EOF
You are a software engineer working on the $lang_name repository '$org/$repo'.

Programming language: $lang_name

Fix the following GitHub issue by modifying the source code. Make only the minimal changes needed.
Do not create commits or branches. Leave all changes uncommitted in the working tree.

## Issue Description

$issue
EOF
}

save_reference_patches() {
  local line="$1" task_dir="$2"
  echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fix_patch',''))" \
    > "$task_dir/gold-patch.diff"
  echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('test_patch',''))" \
    > "$task_dir/test-patch.diff"
}

run_agent() {
  local task_dir="$1" workspace="$2" prompt="$3"
  echo "$prompt" > "$task_dir/prompt.txt"
  local start=$(date +%s)
  set +e
  timeout "$TIMEOUT" bash "$BENCH_DIR/scripts/agent-run.sh" \
    "$AGENT" "$workspace" "$prompt" "$MODEL" \
    < /dev/null > "$task_dir/agent-output.txt" 2>&1
  EXIT_CODE=$?
  set -e
  DURATION=$(( $(date +%s) - start ))
  TOTAL_DURATION=$((TOTAL_DURATION + DURATION))
}

capture_patch() {
  local workspace="$1" task_dir="$2"
  cd "$workspace"
  PATCH="$(git diff 2>/dev/null || true)"
  local new_files="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  if [[ -n "$new_files" ]]; then
    git add $new_files 2>/dev/null || true
    PATCH="$(git diff --cached 2>/dev/null || true)
$PATCH"
  fi
  cd "$SCRIPT_DIR"
  echo "$PATCH" > "$task_dir/patch.diff"
}

evaluate_result() {
  local task_dir="$1" line="$2"
  STATUS="unknown"; RESOLVED=false
  if [[ $EXIT_CODE -eq 124 ]]; then
    STATUS="timeout"; ERRORS=$((ERRORS+1))
    echo "    ⏱️ timeout (${DURATION}s)"
  elif [[ $EXIT_CODE -ne 0 ]]; then
    STATUS="error"; ERRORS=$((ERRORS+1))
    echo "    💥 error exit=$EXIT_CODE (${DURATION}s)"
  elif [[ -z "$PATCH" ]]; then
    STATUS="no_patch"; FAILED=$((FAILED+1))
    echo "    ❌ no patch generated (${DURATION}s)"
  elif $VALIDATE; then
    evaluate_with_tests "$task_dir" "$line"
  else
    evaluate_patch_only
  fi
}

evaluate_with_tests() {
  local task_dir="$1" line="$2"
  local diff_lines=$(echo "$PATCH" | wc -l)
  echo "    🧪 Validating patch..."
  set +e
  bash "$SCRIPT_DIR/multilang-validate.sh" "$task_dir" "$line" \
    > "$task_dir/validation-output.txt" 2>&1
  local vexit=$?; set -e
  if [[ $vexit -eq 0 ]]; then
    STATUS="resolved"; RESOLVED=true; PASSED=$((PASSED+1))
    LANG_PASSED[$LANGUAGE]=$(( ${LANG_PASSED[$LANGUAGE]:-0} + 1 ))
    echo "    ✅ RESOLVED — tests pass (${DURATION}s)"
  else
    handle_validation_failure "$task_dir"
  fi
}

handle_validation_failure() {
  local task_dir="$1"
  local verdict="not_resolved"
  if [[ -f "$task_dir/validation-result.json" ]]; then
    verdict=$(python3 -c \
      "import json; print(json.load(open('${task_dir}/validation-result.json'))['verdict'])" \
      2>/dev/null || echo "not_resolved")
  fi
  STATUS="$verdict"; FAILED=$((FAILED+1))
  case "$verdict" in
    partially_resolved) echo "    ⚠️ PARTIAL (${DURATION}s)" ;;
    tests_not_runnable) echo "    🔧 SKIP — tests couldn't run (${DURATION}s)" ;;
    *) echo "    ❌ NOT RESOLVED (${DURATION}s)" ;;
  esac
}

evaluate_patch_only() {
  local diff_lines=$(echo "$PATCH" | wc -l)
  STATUS="patch_generated"; PASSED=$((PASSED+1))
  LANG_PASSED[$LANGUAGE]=$(( ${LANG_PASSED[$LANGUAGE]:-0} + 1 ))
  echo "    📝 patch: ${diff_lines} lines (no validation) (${DURATION}s)"
}

save_prediction() {
  local task_dir="$1" instance_id="$2"
  PREDICTIONS+=($(python3 -c "
import json
patch = open('${task_dir}/patch.diff').read()
print(json.dumps({'instance_id':'${instance_id}',
  'model_patch':patch,'model_name_or_path':'${AGENT}-${MODEL:-default}'}))
"))
}

save_task_result() {
  local task_dir="$1"
  local patch_lines=0
  [[ -n "$PATCH" ]] && patch_lines=$(echo "$PATCH" | wc -l)
  cat > "$task_dir/result.json" <<ENDJSON
{
  "instance_id": "$INSTANCE_ID", "org": "$ORG", "repo": "$REPO",
  "language": "$LANGUAGE", "difficulty": "$DIFFICULTY",
  "agent": "$AGENT", "model": "${MODEL:-default}",
  "status": "$STATUS", "resolved": $RESOLVED,
  "exit_code": $EXIT_CODE, "duration_seconds": $DURATION,
  "patch_lines": $patch_lines
}
ENDJSON
}

setup_task() {
  local idx="$1" line="$2"
  parse_instance "$line"
  echo ""
  echo "--- [$idx/$NUM_TESTS] $INSTANCE_ID [$LANGUAGE] ($DIFFICULTY) ---"
  echo "    Repo: $ORG/$REPO @ $BASE_SHA"
  TASK_DIR="$RUN_DIR/task-$(printf '%03d' $idx)-${INSTANCE_ID//\//-}"
  mkdir -p "$TASK_DIR"
  LANG_TOTAL[$LANGUAGE]=$(( ${LANG_TOTAL[$LANGUAGE]:-0} + 1 ))
  TASK_WORKSPACE="$TASK_DIR/workspace"
  echo "    Cloning repo..."
  clone_repo "$ORG" "$REPO" "$TASK_WORKSPACE"
}

process_task() {
  local idx="$1" line="$2"
  setup_task "$idx" "$line"
  if [[ ! -d "$TASK_WORKSPACE/.git" ]]; then
    echo "    ⚠️ Failed to clone, skipping"; ERRORS=$((ERRORS+1)); return
  fi
  checkout_base "$TASK_WORKSPACE" "$BASE_SHA" || {
    echo "    ⚠️ Could not checkout, skipping"; ERRORS=$((ERRORS+1)); return
  }
  local issue; issue=$(build_issue_text "$line")
  local prompt; prompt=$(build_prompt "$(lang_display "$LANGUAGE")" "$ORG" "$REPO" "$issue")
  save_reference_patches "$line" "$TASK_DIR"
  run_agent "$TASK_DIR" "$TASK_WORKSPACE" "$prompt"
  capture_patch "$TASK_WORKSPACE" "$TASK_DIR"
  evaluate_result "$TASK_DIR" "$line"
  save_prediction "$TASK_DIR" "$INSTANCE_ID"
  save_task_result "$TASK_DIR"
}

run_all_tasks() {
  local idx=0
  while IFS= read -r line; do
    idx=$((idx+1))
    process_task "$idx" "$line"
  done < "$SELECTED_FILE"
}

write_predictions_file() {
  echo "[" > "$PREDICTIONS_FILE"
  for i in "${!PREDICTIONS[@]}"; do
    echo "${PREDICTIONS[$i]}" >> "$PREDICTIONS_FILE"
    [[ $i -lt $((${#PREDICTIONS[@]}-1)) ]] && echo "," >> "$PREDICTIONS_FILE"
  done
  echo "]" >> "$PREDICTIONS_FILE"
}

print_per_language() {
  for lang in python js ts java c++ go rust c; do
    local total=${LANG_TOTAL[$lang]:-0}
    local passed=${LANG_PASSED[$lang]:-0}
    local pct=0; [[ $total -gt 0 ]] && pct=$((passed * 100 / total))
    printf "   %-12s %d/%d (%d%%)\n" "$lang" "$passed" "$total" "$pct"
  done
}

print_summary() {
  echo ""
  echo "============================================="
  echo " MULTI-LANGUAGE BENCHMARK RESULTS"
  echo "============================================="
  local label="Patches made"; $VALIDATE && label="Resolved"
  echo " Agent:           $AGENT (${MODEL:-default})"
  echo " Total tasks:     $NUM_TESTS"
  echo " ${label}:    $PASSED ✅"
  echo " Failed:          $FAILED ❌"
  echo " Errors/timeouts: $ERRORS 💥"
  echo " Validation:      $($VALIDATE && echo 'Lightweight local' || echo 'DISABLED (patch-only)')"
  echo " Total duration:  ${TOTAL_DURATION}s"
  echo ""; echo " Per-language results:"
  print_per_language
  echo ""
  echo " Predictions:     $PREDICTIONS_FILE"
  echo " Results dir:     $RUN_DIR"
  echo "============================================="
}

build_lang_json() {
  local j="{"
  for lang in python js ts java c++ go rust c; do
    [[ "$j" != "{" ]] && j+=","
    j+="\"$lang\":{\"total\":${LANG_TOTAL[$lang]:-0},\"passed\":${LANG_PASSED[$lang]:-0}}"
  done
  echo "$j}"
}

write_summary_json() {
  local lang_json; lang_json=$(build_lang_json)
  python3 - "$RUN_DIR/summary.json" "$RUN_ID" "$AGENT" "${MODEL:-default}" \
    "$NUM_TESTS" "$PASSED" "$FAILED" "$ERRORS" "$TOTAL_DURATION" \
    "$PREDICTIONS_FILE" "$lang_json" "$($VALIDATE && echo T || echo F)" <<'PY'
import json, sys; a = sys.argv
out, rid, ag, mdl = a[1:5]
t, r, f, e, d = [int(x) for x in a[5:10]]
pf, lj, v = a[10], a[11], a[12]=='T'
from datetime import datetime, timezone as tz
s = {'run_id':rid,'benchmark':'multi-swe-bench-mini','agent':ag,'model':mdl,
  'total_tasks':t,'validated':v,'resolved':r,'failed':f,'errors':e,
  'total_duration_seconds':d,'per_language':json.loads(lj),
  'predictions_file':pf,'timestamp':datetime.now(tz.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}
with open(out,'w') as fp: json.dump(s,fp,indent=2)
PY
}

print_harness_hint() {
  echo ""
  echo "To evaluate with Multi-SWE-bench harness (requires Docker + multi-swe-bench-env):"
  echo "  pip install -e /path/to/multi-swe-bench-env"
  echo "  python -m swebench.harness.run_evaluation \\"
  echo "    --dataset_name ByteDance-Seed/Multi-SWE-bench_mini \\"
  echo "    --predictions_path $PREDICTIONS_FILE \\"
  echo "    --max_workers 4 --run_id $RUN_ID"
}

main() {
  parse_args "$@"
  ensure_dataset
  init_run_dir
  select_instances
  print_banner
  run_all_tasks
  write_predictions_file
  print_summary
  write_summary_json
  print_harness_hint
}

main "$@"
