#!/usr/bin/env bash
# swebench-validate-harness.sh — Validate SWE-bench patches using the official
# Docker-based harness. This handles all dependency installation via pre-built
# Docker images, so it works for complex projects (astropy, matplotlib, etc.).
#
# Usage:
#   ./swebench-validate-harness.sh <run-dir> [--timeout <sec>] [--max-workers <n>]
#
# The <run-dir> must contain:
#   - predictions.json  (SWE-bench format: instance_id, model_patch, model_name_or_path)
#   - summary.json      (will be updated with harness results)
#
# Requires:
#   - Docker daemon running (or podman with docker compat)
#   - Python swebench package: pip install swebench
#
# Output:
#   - <run-dir>/harness-output.txt     Full harness log
#   - <run-dir>/harness-results.json   Parsed results per instance
#   - Updates each task-*/result.json and task-*/validation-result.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"

RUN_DIR=""
TIMEOUT=1800
MAX_WORKERS=4
DATASET_NAME="princeton-nlp/SWE-bench_Lite"

usage() {
  echo "Usage: swebench-validate-harness.sh <run-dir> [--timeout <sec>] [--max-workers <n>]"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --max-workers)  MAX_WORKERS="$2"; shift 2 ;;
    --dataset)      DATASET_NAME="$2"; shift 2 ;;
    --help|-h)      usage ;;
    *)
      if [[ -z "$RUN_DIR" ]]; then
        RUN_DIR="$1"; shift
      else
        echo "Unknown arg: $1" >&2; exit 1
      fi
      ;;
  esac
done

[[ -z "$RUN_DIR" ]] && { echo "ERROR: <run-dir> required" >&2; usage; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"

PREDICTIONS_FILE="$RUN_DIR/predictions.json"
[[ -f "$PREDICTIONS_FILE" ]] || { echo "ERROR: $PREDICTIONS_FILE not found" >&2; exit 1; }

# --- Check prerequisites ---
check_docker() {
  if docker info &>/dev/null; then
    echo "[harness] Docker available"
    return 0
  fi
  # Try podman with docker compat
  if podman info &>/dev/null; then
    echo "[harness] Podman available (docker compat)"
    return 0
  fi
  echo "[harness] ERROR: Docker or Podman required for SWE-bench harness" >&2
  return 1
}

check_swebench() {
  if python3 -c "from swebench.harness.run_evaluation import main" &>/dev/null; then
    echo "[harness] swebench package available"
    return 0
  fi
  echo "[harness] Installing swebench package..."
  pip3 install --break-system-packages swebench 2>/dev/null || \
  pip3 install swebench 2>/dev/null || {
    echo "[harness] ERROR: Cannot install swebench. Run: pip install swebench" >&2
    return 1
  }
}

check_docker
check_swebench

# --- Check predictions file has actual patches ---
PATCH_COUNT=$(python3 -c "
import json
preds = json.load(open('$PREDICTIONS_FILE'))
count = sum(1 for p in preds if p.get('model_patch','').strip())
print(count)
")

if [[ "$PATCH_COUNT" -eq 0 ]]; then
  echo "[harness] No patches in predictions file — nothing to validate"
  exit 0
fi

echo "[harness] Validating $PATCH_COUNT predictions with official SWE-bench Docker harness..."
echo "[harness] Timeout per instance: ${TIMEOUT}s, max workers: $MAX_WORKERS"

# --- Extract instance IDs from predictions ---
INSTANCE_IDS=$(python3 -c "
import json
preds = json.load(open('$PREDICTIONS_FILE'))
ids = [p['instance_id'] for p in preds if p.get('model_patch','').strip()]
print(' '.join(ids))
")

# --- Determine a unique run ID ---
RUN_ID="$(basename "$RUN_DIR")"

# --- Run the official harness ---
# The harness pulls/builds Docker images with all deps pre-installed,
# applies the patch, runs the project's test suite, and writes reports.
set +e
python3 -m swebench.harness.run_evaluation \
  --dataset_name "$DATASET_NAME" \
  --split test \
  --predictions_path "$PREDICTIONS_FILE" \
  --max_workers "$MAX_WORKERS" \
  --timeout "$TIMEOUT" \
  --run_id "$RUN_ID" \
  --instance_ids $INSTANCE_IDS \
  --cache_level env \
  --report_dir "$RUN_DIR" \
  2>&1 | tee "$RUN_DIR/harness-output.txt"
HARNESS_EXIT=$?
set -e

echo "[harness] Harness exited with code $HARNESS_EXIT"

# --- Parse harness reports and update task results ---
# The harness writes per-instance reports to:
#   logs/run_evaluation/<run_id>/<model_name>/<instance_id>/report.json
python3 - "$RUN_DIR" "$PREDICTIONS_FILE" "$RUN_ID" << 'PYEOF'
import json, sys, os, glob
from pathlib import Path

run_dir = Path(sys.argv[1])
predictions_file = sys.argv[2]
run_id = sys.argv[3]

# Load predictions
preds = json.load(open(predictions_file))
pred_map = {p['instance_id']: p for p in preds}

# Find harness report files
# They live in logs/run_evaluation/<run_id>/<model>/<instance_id>/report.json
# Could be in CWD or in run_dir
search_dirs = [
    Path("logs/run_evaluation") / run_id,
    run_dir / "logs" / "run_evaluation" / run_id,
]

harness_results = {}
for search_dir in search_dirs:
    if not search_dir.exists():
        continue
    for report_file in search_dir.rglob("report.json"):
        try:
            content = report_file.read_text().strip()
            if not content:
                continue
            report = json.loads(content)
            for instance_id, result in report.items():
                harness_results[instance_id] = result
        except (json.JSONDecodeError, KeyError) as e:
            print(f"  Warning: Could not parse {report_file}: {e}")

print(f"[harness] Found {len(harness_results)} harness reports")

# Count results
resolved = 0
not_resolved = 0
errors = 0

for instance_id, result in harness_results.items():
    is_resolved = result.get("resolved", False)
    if is_resolved:
        resolved += 1
    else:
        not_resolved += 1
    print(f"  {'✅' if is_resolved else '❌'} {instance_id}: {'RESOLVED' if is_resolved else 'NOT RESOLVED'}")

# Update task-* result.json files in run_dir
for task_dir in sorted(run_dir.glob("task-*")):
    result_file = task_dir / "result.json"
    if not result_file.exists():
        continue
    try:
        result = json.load(open(result_file))
        instance_id = result.get("instance_id", "")
        if instance_id in harness_results:
            hr = harness_results[instance_id]
            is_resolved = hr.get("resolved", False)
            result["resolved"] = is_resolved
            result["status"] = "resolved" if is_resolved else "not_resolved"
            result["harness_validated"] = True
            # Write updated result
            with open(result_file, 'w') as f:
                json.dump(result, f, indent=2)
            # Write validation-result.json
            val_result = {
                "instance_id": instance_id,
                "verdict": "resolved" if is_resolved else "not_resolved",
                "resolved": is_resolved,
                "harness_validated": True,
                "harness_report": hr,
            }
            with open(task_dir / "validation-result.json", 'w') as f:
                json.dump(val_result, f, indent=2)
        elif result.get("status") not in ("timeout", "error", "no_patch"):
            # Patch was generated but harness didn't report — mark as error
            result["status"] = "harness_error"
            result["harness_validated"] = True
            errors += 1
            with open(result_file, 'w') as f:
                json.dump(result, f, indent=2)
    except Exception as e:
        print(f"  Warning: Could not update {result_file}: {e}")

# Write overall harness results
harness_summary = {
    "total_evaluated": len(harness_results),
    "resolved": resolved,
    "not_resolved": not_resolved,
    "errors": errors,
    "results": {k: {"resolved": v.get("resolved", False)} for k, v in harness_results.items()},
}
with open(run_dir / "harness-results.json", 'w') as f:
    json.dump(harness_summary, f, indent=2)

# Update summary.json
summary_file = run_dir / "summary.json"
if summary_file.exists():
    try:
        summary = json.load(open(summary_file))
        summary["resolved"] = resolved
        summary["failed"] = not_resolved
        summary["errors"] = errors
        summary["harness_validated"] = True
        with open(summary_file, 'w') as f:
            json.dump(summary, f, indent=2)
    except Exception as e:
        print(f"  Warning: Could not update summary.json: {e}")

print(f"\n[harness] Summary: {resolved} resolved, {not_resolved} not resolved, {errors} errors")
PYEOF

echo "[harness] Done. Results in $RUN_DIR/harness-results.json"
