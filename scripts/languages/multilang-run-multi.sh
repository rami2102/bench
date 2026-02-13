#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

AGENTS_CSV="${AGENTS:-codex,pi,gemini}"
PARALLEL="${PARALLEL:-false}"
NUM_TESTS="${NUM_TESTS:-8}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
TEST_LIST_FILE="${TEST_LIST_FILE:-$BENCH_DIR/tests/multilang/round-robin-by-language.md}"
TIMEOUT="${TIMEOUT:-900}"
VALIDATE=false
LANGUAGE=""

RUN_TAG="$(date +%Y%m%d-%H%M%S)-host-run"
RESULT_BASE="$BENCH_DIR/results/multilang/$RUN_TAG"
LOG_DIR="$RESULT_BASE/logs"

usage() {
  cat <<'EOF'
Usage: multilang-run-multi.sh [options]
  --agents <list|all>        e.g. codex,pi or all
  --parallel                 Run selected agents concurrently
  --num-tests <N|all>        Number of tests (default: 8)
  --instance-ids <csv>       Explicit instance IDs
  --test-list-file <path>    Ordered ID list file (default: round-robin-by-language)
  --timeout <sec>            Per-task timeout (default: 900)
  --no-validate              Disable validation
  --language, -l <lang>      Filter by language (passed to multilang-run.sh)
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
      --validate) VALIDATE=true; shift ;;
      --no-validate) VALIDATE=false; shift ;;
      --language|-l) LANGUAGE="$2"; shift 2 ;;
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

resolve_instance_ids() {
  if [[ -n "$INSTANCE_IDS" ]]; then SELECTED_IDS_CSV="$INSTANCE_IDS"; return; fi
  if [[ ! -f "$TEST_LIST_FILE" ]]; then
    echo "Missing test list: $TEST_LIST_FILE" >&2; exit 1
  fi
  SELECTED_IDS_CSV="$(ids_from_file "$TEST_LIST_FILE" "$NUM_TESTS")"
  [[ -n "$SELECTED_IDS_CSV" ]] || { echo "No instance IDs selected" >&2; exit 1; }
}

model_arg_for() {
  [[ "$1" == "gemini" ]] && echo "--model ${GEMINI_MODEL:-gemini-2.5-flash}" || true
}

timeout_for() {
  # Gemini is ~5x slower; scale timeout accordingly
  local t="$TIMEOUT"
  [[ "$1" == "gemini" ]] && t=$(( TIMEOUT * ${GEMINI_TIMEOUT_MULTIPLIER:-5} ))
  echo "$t"
}

run_agent() {
  local agent="$1" model="$(model_arg_for "$1")"
  local agent_timeout="$(timeout_for "$1")"
  local log="$LOG_DIR/${agent}.log" results="$RESULT_BASE/$agent"
  local validate_flag="" lang_flag=""
  if $VALIDATE; then validate_flag="--validate"; fi
  if [[ -n "$LANGUAGE" ]]; then lang_flag="--language $LANGUAGE"; fi
  mkdir -p "$results" "$LOG_DIR"
  bash "$SCRIPT_DIR/multilang-run.sh" --agent "$agent" $model \
    --instance-ids "$SELECTED_IDS_CSV" --timeout "$agent_timeout" \
    --results-dir "$results" $validate_flag $lang_flag > "$log" 2>&1
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
    dir="$(latest_run_dir "$base" 2>/dev/null || true)"; [[ -n "$dir" ]] || continue
    print_agent_summary "$a" "$dir"
  done
}

main() {
  parse_args "$@"; parse_agents; validate_agents
  resolve_instance_ids
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
