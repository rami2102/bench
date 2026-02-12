#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-bench-agents:latest}"
AGENTS_CSV="${AGENTS:-codex,pi,gemini}"
PARALLEL="${PARALLEL:-false}"
NUM_TESTS="${NUM_TESTS:-1}"
INSTANCE_IDS="${INSTANCE_IDS:-}"
TEST_LIST_FILE="${TEST_LIST_FILE:-$BENCH_DIR/tests/swebench/round-robin-by-repo.md}"
TIMEOUT="${TIMEOUT:-900}"
VALIDATE=true
USE_HARNESS=true
BUILD_IMAGE=false

RUN_TAG="$(date +%Y%m%d-%H%M%S)-podman-run"
RESULT_BASE="$BENCH_DIR/results/swebench/$RUN_TAG"
CONTAINER_RESULT_BASE="/workspace/results/swebench/$RUN_TAG"
LOG_DIR="$RESULT_BASE/logs"

usage() {
  cat <<'EOF'
Usage: podman-swebench-run.sh [options]
  --agents <list|all>        e.g. codex,pi or all
  --parallel                 Run selected agents concurrently
  --num-tests <N|all>        Number of tests (default: 1)
  --instance-ids <csv>       Explicit SWE-bench instance IDs
  --test-list-file <path>    Ordered ID list file (default: round-robin)
  --timeout <sec>            Per-task timeout (default: 900)
  --no-validate              Disable all validation
  --no-harness               Use lightweight local validation (not recommended)
  --build-image              Build image before run
  --image-name <name>        Podman image tag
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
ids = []
for line in open(path):
    s = line.strip()
    if not s or s.startswith('#'): continue
    s = re.sub(r'^[-*]\s*', '', s)
    ids.append(s)
if n == 'all':
    print(','.join(ids)); sys.exit(0)
count = max(0, int(n))
print(','.join(ids[:count]))
PY
}

ids_all_dataset() {
  python3 - "$1" <<'PY'
import json, sys
ids=[json.loads(l)['instance_id'] for l in open(sys.argv[1])]
print(','.join(ids))
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

build_image_if_needed() {
  if [[ "$BUILD_IMAGE" != "true" ]]; then
    return
  fi
  IMAGE_NAME="$IMAGE_NAME" bash "$SCRIPT_DIR/podman-build.sh"
}

prepare_cache() {
  bash "$SCRIPT_DIR/swebench-cache-local.sh" --instance-ids "$SELECTED_IDS_CSV"
}

mounts() {
  MOUNTS=(
    "-v" "$BENCH_DIR:/workspace:Z"
    "-v" "$BENCH_DIR/cache/swebench/repos:/workspace/cache/swebench/repos:ro,Z"
    "-v" "$HOME/.codex:/home/node/.codex:Z"
    "-v" "$HOME/.gemini:/home/node/.gemini:Z"
    "-v" "$HOME/.pi:/home/node/.pi:Z"
    "-v" "$HOME/.gitconfig:/home/node/.gitconfig:Z"
  )
  if [[ -d "$HOME/.claude" ]]; then
    MOUNTS+=("-v" "$HOME/.claude:/home/node/.claude:Z")
  fi
  if [[ -f "$HOME/.claude.json" ]]; then
    MOUNTS+=("-v" "$HOME/.claude.json:/home/node/.claude.json:Z")
  fi
}

model_arg_for() {
  [[ "$1" == "gemini" ]] && echo "--model ${GEMINI_MODEL:-gemini-2.5-flash}" || true
}

validate_flag() {
  # Inside podman: always --no-validate (patch-only).
  # Harness validation runs on host after podman exits (needs Docker).
  echo "--no-validate"
}

run_agent() {
  local agent="$1" model="$(model_arg_for "$1")" no_val="$(validate_flag)"
  local log="$LOG_DIR/${agent}.log"
  local host_results="$RESULT_BASE/$agent"
  local ctr_results="$CONTAINER_RESULT_BASE/$agent"
  mkdir -p "$host_results" "$LOG_DIR"
  podman run --rm --userns=keep-id --user "$(id -u):$(id -g)" --network host \
    "${MOUNTS[@]}" -w /workspace "$IMAGE_NAME" bash -lc \
    "./scripts/bench.sh swebench --agent $agent $model --instance-ids $SELECTED_IDS_CSV --timeout $TIMEOUT --results-dir $ctr_results $no_val" \
    > "$log" 2>&1
}

run_parallel() {
  pids=(); names=()
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"; run_agent "$a" &
    pids+=("$!"); names+=("$a")
  done
  FAILURES=0
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
  local base="$1"
  find "$base" -mindepth 1 -maxdepth 1 -type d | sort | tail -1
}

print_agent_summary() {
  local agent="$1" dir="$2" summary="$dir/summary.json"
  python3 - "$agent" "$summary" <<'PY'
import json, sys
agent, path = sys.argv[1], sys.argv[2]
s=json.load(open(path))
t=max(1,int(s['total_tasks']))
r,f,e=s['resolved'],s['failed'],s['errors']
p=lambda x: round(100*x/t,2)
print(f"{agent}: resolved {r}/{t} ({p(r)}%), failed {f}/{t} ({p(f)}%), errors {e}/{t} ({p(e)}%)")
PY
}

run_harness_validation() {
  if ! $USE_HARNESS || ! $VALIDATE; then
    echo "[podman-run] Harness validation skipped"
    return
  fi
  echo ""
  echo "[podman-run] Running SWE-bench Docker harness on host for validation..."
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"; base="$RESULT_BASE/$a"
    dir="$(latest_run_dir "$base")"
    [[ -n "$dir" && -f "$dir/predictions.json" ]] || continue
    echo "[podman-run] Validating $a patches..."
    set +e
    bash "$SCRIPT_DIR/swebench-validate-harness.sh" "$dir" \
      --timeout "$TIMEOUT" --max-workers 2
    set -e
  done
}

print_final_summary() {
  echo "[podman-run] Results persisted at: $RESULT_BASE"
  for raw in "${AGENTS[@]}"; do
    a="$(echo "$raw" | xargs)"; base="$RESULT_BASE/$a"
    dir="$(latest_run_dir "$base")"; [[ -n "$dir" ]] || continue
    if [[ -f "$dir/harness-results.json" ]]; then
      # Use harness results
      python3 - "$a" "$dir/harness-results.json" <<'PY'
import json, sys
agent = sys.argv[1]
h = json.load(open(sys.argv[2]))
r, nr, e = h['resolved'], h['not_resolved'], h['errors']
t = r + nr + e
print(f"{agent}: resolved {r}/{t}, not_resolved {nr}/{t}, errors {e}/{t} (Docker harness)")
PY
    elif [[ -f "$dir/summary.json" ]]; then
      print_agent_summary "$a" "$dir"
    fi
  done
}

main() {
  parse_args "$@"; parse_agents; validate_agents
  resolve_instance_ids; build_image_if_needed; prepare_cache; mounts
  mkdir -p "$RESULT_BASE" "$LOG_DIR"
  if [[ "$PARALLEL" == "true" ]]; then
    run_parallel
  else
    run_sequential
  fi
  run_harness_validation
  print_final_summary
  [[ ${FAILURES:-0} -eq 0 ]]
}

main "$@"
