#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

AGENTS_CSV="${AGENTS:-codex,pi,gemini}"
PARALLEL="${PARALLEL:-false}"
NUM_TESTS="${NUM_TESTS:-1}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
TEST_LIST_FILE="${TEST_LIST_FILE:-$BENCH_DIR/tests/swebench/round-robin-by-repo.md}"
TIMEOUT="${TIMEOUT:-900}"
VALIDATE=true
USE_HARNESS=true
IMAGE_NAME="${IMAGE_NAME:-}"
BUILD_IMAGE=false

RUN_TAG="$(date +%Y%m%d-%H%M%S)-host-run"
RESULT_BASE="$BENCH_DIR/results/swebench/$RUN_TAG"
LOG_DIR="$RESULT_BASE/logs"

usage() {
  cat <<'EOF'
Usage: swebench-run-multi.sh [options]
  --agents <list|all>        e.g. codex,pi or all
  --parallel                 Run selected agents concurrently
  --num-tests <N|all>        Number of tests (default: 1)
  --instance-ids <csv>       Explicit SWE-bench instance IDs
  --test-list-file <path>    Ordered ID list file (default: round-robin)
  --timeout <sec>            Per-task timeout (default: 900)
  --no-validate              Disable validation (default: validate on)
  --build-image              Ignored in host mode (compat)
  --image-name <name>        Ignored in host mode (compat)
  --help, -h                 Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents) AGENTS_CSV="$2"; shift 2 ;;
      --parallel) PARALLEL=true; shift ;;
      --num-tests) NUM_TESTS="$2"; shift 2 ;;
      --instance-ids) INSTANCE_IDS="$2"; shift 2 ;;
      --test-list-file) TEST_LIST_FILE="$2"; shift 2 ;;
      --timeout) TIMEOUT="$2"; shift 2 ;;
      --no-validate) VALIDATE=false; USE_HARNESS=false; shift ;;
      --no-harness) USE_HARNESS=false; shift ;;
      --build-image) BUILD_IMAGE=true; shift ;;
      --image-name) IMAGE_NAME="$2"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
  done
}

parse_agents() {
  if [[ "$AGENTS_CSV" == "all" ]]; then
    AGENTS=(claude codex gemini pi)
    return
  fi
  IFS=',' read -ra AGENTS <<< "$AGENTS_CSV"
}

validate_agents() {
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"
    case "$a" in claude|codex|gemini|pi) ;; *)
      echo "ERROR: Unsupported agent '$a'" >&2; exit 1 ;;
    esac
  done
}

warn_compat_flags() {
  if [[ "$BUILD_IMAGE" == "true" ]]; then
    echo "[host-run] --build-image ignored (host mode)"
  fi
  if [[ -n "$IMAGE_NAME" ]]; then
    echo "[host-run] --image-name ignored (host mode)"
  fi
}

ensure_test_lists() {
  if [[ -f "$TEST_LIST_FILE" ]]; then
    return
  fi
  bash "$SCRIPT_DIR/swebench-build-test-lists.sh"
  [[ -f "$TEST_LIST_FILE" ]] || { echo "Missing test list: $TEST_LIST_FILE" >&2; exit 1; }
}

ids_from_file() {
  python3 - "$1" "$2" <<'PY'
import re, sys
path, n = sys.argv[1], sys.argv[2]
ids=[]
for line in open(path):
    s=line.strip()
    if not s or s.startswith('#'): continue
    ids.append(re.sub(r'^[-*]\s*', '', s))
print(','.join(ids if n=='all' else ids[:max(0,int(n))]))
PY
}

ids_all_dataset() {
  python3 - "$1" <<'PY'
import json, sys
print(','.join(json.loads(l)['instance_id'] for l in open(sys.argv[1])))
PY
}

resolve_instance_ids() {
  local dataset="$BENCH_DIR/cache/swebench/swe-bench-lite.jsonl"
  if [[ -n "$INSTANCE_IDS" ]]; then SELECTED_IDS_CSV="$INSTANCE_IDS"; return; fi
  if [[ "$NUM_TESTS" == "all" && ! -f "$TEST_LIST_FILE" ]]; then
    SELECTED_IDS_CSV="$(ids_all_dataset "$dataset")"; return
  fi
  ensure_test_lists
  SELECTED_IDS_CSV="$(ids_from_file "$TEST_LIST_FILE" "$NUM_TESTS")"
  [[ -n "$SELECTED_IDS_CSV" ]] || { echo "No instance IDs selected" >&2; exit 1; }
}

model_arg_for() {
  [[ "$1" == "gemini" ]] && echo "--model ${GEMINI_MODEL:-gemini-2.5-flash}" || true
}

validate_flag() {
  if ! $VALIDATE; then
    echo "--no-validate"
  elif ! $USE_HARNESS; then
    echo "--no-harness"
  else
    # Harness validation — agent run is patch-only, harness validates after
    echo ""
  fi
}

run_agent() {
  local agent="$1" model="$(model_arg_for "$1")" no_val="$(validate_flag)"
  local log="$LOG_DIR/${agent}.log" results="$RESULT_BASE/$agent"
  mkdir -p "$results" "$LOG_DIR"
  bash "$SCRIPT_DIR/bench.sh" swebench --agent "$agent" $model \
    --instance-ids "$SELECTED_IDS_CSV" --timeout "$TIMEOUT" \
    --results-dir "$results" $no_val > "$log" 2>&1
}

run_parallel() {
  pids=(); names=(); FAILURES=0
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"; run_agent "$a" &
    pids+=("$!"); names+=("$a")
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || FAILURES=$((FAILURES+1))
  done
}

run_sequential() {
  FAILURES=0
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"
    run_agent "$a" || FAILURES=$((FAILURES+1))
  done
}

latest_run_dir() {
  find "$1" -mindepth 1 -maxdepth 1 -type d | sort | tail -1
}

print_agent_summary() {
  python3 - "$1" "$2/summary.json" <<'PY'
import json, sys
agent, path = sys.argv[1], sys.argv[2]
s=json.load(open(path)); t=max(1,int(s['total_tasks']))
r,f,e=s['resolved'],s['failed'],s['errors']
p=lambda x: round(100*x/t,2)
print(f"{agent}: resolved {r}/{t} ({p(r)}%), failed {f}/{t} ({p(f)}%), errors {e}/{t} ({p(e)}%)")
PY
}

print_final_summary() {
  echo "[host-run] Results persisted at: $RESULT_BASE"
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"; base="$RESULT_BASE/$a"
    dir="$(latest_run_dir "$base")"; [[ -n "$dir" ]] || continue
    print_agent_summary "$a" "$dir"
  done
}

main() {
  parse_args "$@"; parse_agents; validate_agents
  warn_compat_flags; resolve_instance_ids
  mkdir -p "$RESULT_BASE" "$LOG_DIR"
  if [[ "$PARALLEL" == "true" ]]; then
    run_parallel
  else
    run_sequential
  fi
  print_final_summary
  [[ ${FAILURES:-0} -eq 0 ]]
}

main "$@"
