#!/usr/bin/env bash
# swebench-validate.sh — Validate a SWE-bench patch by running the actual tests.
#
# For each task, this script:
#   1. Starts from the workspace with the agent's changes applied
#   2. Applies the test_patch (adds/updates test cases from the dataset)
#   3. Runs FAIL_TO_PASS tests (these SHOULD pass after a correct fix)
#   4. Optionally runs PASS_TO_PASS tests (these should still pass)
#
# Usage:
#   ./swebench-validate.sh <task-dir> <instance-json-line>
#
# Or called automatically by swebench-run.sh when --validate is set.
#
# Returns: 0 if all FAIL_TO_PASS tests pass, 1 otherwise.
# Writes: validation-result.json into the task dir.

set -uo pipefail
# NOTE: no set -e — we need to capture test failures

TASK_DIR="${1:?Usage: swebench-validate.sh <task-dir> <instance-json-line>}"
INSTANCE_LINE="${2:?Missing instance JSON line}"

WORKSPACE="$TASK_DIR/workspace"

if [[ ! -d "$WORKSPACE" ]]; then
  echo "[validate] ERROR: Workspace not found: $WORKSPACE" >&2
  exit 1
fi

# Parse instance data
INSTANCE_ID=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['instance_id'])")
TEST_PATCH=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('test_patch',''))")
FAIL_TO_PASS=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('FAIL_TO_PASS','[]'))")
PASS_TO_PASS=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('PASS_TO_PASS','[]'))")
GOLD_PATCH=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('patch',''))")

echo "[validate] Instance: $INSTANCE_ID"

# Parse test lists
FAIL_TESTS=$(python3 -c "import json; tests=json.loads('$FAIL_TO_PASS'); [print(t) for t in tests]" 2>/dev/null || true)
PASS_TESTS=$(python3 -c "import json; tests=json.loads('$PASS_TO_PASS'); [print(t) for t in tests]" 2>/dev/null || true)

FAIL_TEST_COUNT=$(echo "$FAIL_TESTS" | grep -c . || true)
PASS_TEST_COUNT=$(echo "$PASS_TESTS" | grep -c . || true)

echo "[validate] FAIL_TO_PASS tests: $FAIL_TEST_COUNT"
echo "[validate] PASS_TO_PASS tests: $PASS_TEST_COUNT"

# Save gold patch for reference
echo "$GOLD_PATCH" > "$TASK_DIR/gold-patch.diff"

cd "$WORKSPACE"

# --- Step 1: Apply test_patch (adds test cases that verify the fix) ---
TEST_PATCH_APPLIED=false
if [[ -n "$TEST_PATCH" ]]; then
  echo "$TEST_PATCH" > "$TASK_DIR/test-patch.diff"
  echo "[validate] Applying test_patch..."
  if git apply --check "$TASK_DIR/test-patch.diff" 2>/dev/null; then
    git apply "$TASK_DIR/test-patch.diff" 2>/dev/null
    TEST_PATCH_APPLIED=true
    echo "[validate] test_patch applied successfully"
  else
    # Try with more relaxed options
    if git apply --3way "$TASK_DIR/test-patch.diff" 2>/dev/null; then
      TEST_PATCH_APPLIED=true
      echo "[validate] test_patch applied (3-way merge)"
    else
      echo "[validate] WARNING: Could not apply test_patch (may conflict with agent's changes)"
      echo "[validate] Trying fuzzy apply..."
      if patch -p1 --fuzz=3 < "$TASK_DIR/test-patch.diff" 2>/dev/null; then
        TEST_PATCH_APPLIED=true
        echo "[validate] test_patch applied (fuzzy)"
      else
        echo "[validate] WARNING: test_patch could not be applied at all"
      fi
    fi
  fi
fi

# --- Step 2: Detect test framework and runner ---
detect_test_runner() {
  local PY="${VALIDATE_PYTHON:-python3}"
  # Check for common Python test frameworks
  if [[ -f "setup.py" || -f "pyproject.toml" || -f "setup.cfg" ]]; then
    # Python project
    if "$PY" -m pytest --version >/dev/null 2>&1; then
      echo "pytest"
    elif "$PY" -m unittest --help >/dev/null 2>&1; then
      echo "unittest"
    else
      echo "pytest"  # Default for Python
    fi
  else
    echo "unknown"
  fi
}

# --- Step 3: Try to install project dependencies (best effort) ---
install_deps() {
  echo "[validate] Setting up virtual environment..."

  # Create a venv for isolated testing
  VENV_DIR="$TASK_DIR/venv"
  python3 -m venv "$VENV_DIR" 2>/dev/null || {
    echo "[validate] WARNING: Could not create venv, trying direct install"
    VENV_DIR=""
  }

  if [[ -n "$VENV_DIR" && -f "$VENV_DIR/bin/pip" ]]; then
    PIP="$VENV_DIR/bin/pip"
    PYTHON="$VENV_DIR/bin/python"
    # Upgrade pip and install common compat packages
    "$PIP" install --upgrade pip setuptools 2>/dev/null || true
  else
    PIP="pip"
    PYTHON="python3"
    # Fallback: use --break-system-packages
    PIP="pip install --break-system-packages"
  fi

  echo "[validate] Attempting to install project dependencies..."

  # Try pip install in editable mode (most common for SWE-bench repos)
  if [[ -f "setup.py" || -f "pyproject.toml" ]]; then
    $PIP install -e ".[test]" 2>"$TASK_DIR/install-stderr.txt" || \
    $PIP install -e ".[dev]"  2>>"$TASK_DIR/install-stderr.txt" || \
    $PIP install -e .         2>>"$TASK_DIR/install-stderr.txt" || \
    echo "[validate] WARNING: Could not install project"
  fi

  # Install pytest if not available
  "$PYTHON" -m pytest --version 2>/dev/null || \
    $PIP install pytest 2>/dev/null || true

  # Export PYTHON for test runner to use
  export VALIDATE_PYTHON="$PYTHON"
}

# Only install deps if we have tests to run
DEPS_INSTALLED=false
if [[ $FAIL_TEST_COUNT -gt 0 ]]; then
  install_deps 2>/dev/null
  DEPS_INSTALLED=true
fi

# Detect test runner AFTER deps are installed (so venv python is available)
TEST_RUNNER=$(detect_test_runner)
echo "[validate] Test runner: $TEST_RUNNER"

# --- Step 4: Run FAIL_TO_PASS tests ---
# These are the tests that FAILED on the base commit and SHOULD PASS after a correct fix.
FAIL_TO_PASS_RESULTS=""
FAIL_TO_PASS_PASSED=0
FAIL_TO_PASS_FAILED=0
FAIL_TO_PASS_ERRORS=0

find_test_file() {
  # Given a test id like "test_immutable" or "tests/test_basic.py::test_immutable"
  # or "sympy/core/tests/test_basic.py::test_immutable", resolve to pytest-style path
  local test_id="$1"

  # Already a pytest-style path (contains :: or .py)
  if [[ "$test_id" == *"::"* || "$test_id" == *".py"* ]]; then
    echo "$test_id"
    return
  fi

  # Bare function name — search for it in the test_patch diff
  if [[ -f "$TASK_DIR/test-patch.diff" ]]; then
    local test_file
    test_file=$(grep '^diff --git' "$TASK_DIR/test-patch.diff" | head -1 | sed 's|.*b/||')
    if [[ -n "$test_file" && -f "$test_file" ]]; then
      echo "${test_file}::${test_id}"
      return
    fi
  fi

  # Search the codebase for the test function
  local found
  found=$(grep -rl "def ${test_id}" --include="*.py" . 2>/dev/null | grep -i test | head -1 || true)
  if [[ -n "$found" ]]; then
    # Remove leading ./
    found="${found#./}"
    echo "${found}::${test_id}"
    return
  fi

  # Give up — return as-is
  echo "$test_id"
}

run_single_test() {
  local test_id="$1"
  local log_file="$2"
  local PY="${VALIDATE_PYTHON:-python3}"

  # Resolve bare test names to full pytest paths
  local resolved_id
  resolved_id=$(find_test_file "$test_id")

  case "$TEST_RUNNER" in
    pytest)
      echo "  Running: $PY -m pytest $resolved_id" >> "$log_file"
      "$PY" -m pytest "$resolved_id" -x --tb=short --no-header -q \
        >> "$log_file" 2>&1
      return $?
      ;;
    unittest)
      "$PY" -m unittest "$resolved_id" \
        > "$log_file" 2>&1
      return $?
      ;;
    *)
      echo "Unknown test runner" > "$log_file"
      return 2
      ;;
  esac
}

if [[ $FAIL_TEST_COUNT -gt 0 ]]; then
  echo ""
  echo "[validate] Running FAIL_TO_PASS tests..."
  TEST_IDX=0
  while IFS= read -r TEST_ID; do
    [[ -z "$TEST_ID" ]] && continue
    TEST_IDX=$((TEST_IDX + 1))
    TEST_LOG="$TASK_DIR/test-fail2pass-${TEST_IDX}.log"

    set +e
    run_single_test "$TEST_ID" "$TEST_LOG"
    TEST_EXIT=$?
    set -e

    if [[ $TEST_EXIT -eq 0 ]]; then
      echo "    ✅ PASS: $TEST_ID"
      FAIL_TO_PASS_PASSED=$((FAIL_TO_PASS_PASSED + 1))
    elif [[ $TEST_EXIT -eq 2 || $TEST_EXIT -eq 3 || $TEST_EXIT -eq 4 || $TEST_EXIT -eq 5 ]]; then
      # pytest exit codes: 2=interrupted, 3=internal error, 4=usage error, 5=no tests collected
      echo "    ⚠️  SKIP: $TEST_ID (could not run, exit=$TEST_EXIT)"
      FAIL_TO_PASS_ERRORS=$((FAIL_TO_PASS_ERRORS + 1))
    else
      echo "    ❌ FAIL: $TEST_ID"
      FAIL_TO_PASS_FAILED=$((FAIL_TO_PASS_FAILED + 1))
    fi
  done <<< "$FAIL_TESTS"
else
  echo "[validate] No FAIL_TO_PASS tests defined for this instance"
fi

# --- Step 5: Run PASS_TO_PASS tests (regression check) ---
PASS_TO_PASS_PASSED=0
PASS_TO_PASS_FAILED=0
PASS_TO_PASS_ERRORS=0

if [[ $PASS_TEST_COUNT -gt 0 && $PASS_TEST_COUNT -le 20 ]]; then
  echo ""
  echo "[validate] Running PASS_TO_PASS tests (regression check, max 20)..."
  TEST_IDX=0
  while IFS= read -r TEST_ID; do
    [[ -z "$TEST_ID" ]] && continue
    TEST_IDX=$((TEST_IDX + 1))
    TEST_LOG="$TASK_DIR/test-pass2pass-${TEST_IDX}.log"

    set +e
    run_single_test "$TEST_ID" "$TEST_LOG"
    TEST_EXIT=$?
    set -e

    if [[ $TEST_EXIT -eq 0 ]]; then
      PASS_TO_PASS_PASSED=$((PASS_TO_PASS_PASSED + 1))
    elif [[ $TEST_EXIT -eq 2 || $TEST_EXIT -eq 3 || $TEST_EXIT -eq 4 || $TEST_EXIT -eq 5 ]]; then
      PASS_TO_PASS_ERRORS=$((PASS_TO_PASS_ERRORS + 1))
    else
      echo "    ❌ REGRESSION: $TEST_ID"
      PASS_TO_PASS_FAILED=$((PASS_TO_PASS_FAILED + 1))
    fi
  done <<< "$PASS_TESTS"
  echo "    Regression: ${PASS_TO_PASS_PASSED} pass, ${PASS_TO_PASS_FAILED} fail, ${PASS_TO_PASS_ERRORS} skip"
elif [[ $PASS_TEST_COUNT -gt 20 ]]; then
  echo "[validate] Skipping PASS_TO_PASS tests ($PASS_TEST_COUNT tests — too many, use --use-harness for full eval)"
fi

# --- Step 6: Determine overall result ---
# RESOLVED = all FAIL_TO_PASS tests pass AND no PASS_TO_PASS regressions
if [[ $FAIL_TEST_COUNT -eq 0 ]]; then
  VERDICT="no_tests"
  RESOLVED=false
elif [[ $FAIL_TO_PASS_ERRORS -eq $FAIL_TEST_COUNT ]]; then
  VERDICT="tests_not_runnable"
  RESOLVED=false
elif [[ $FAIL_TO_PASS_FAILED -eq 0 && $FAIL_TO_PASS_PASSED -gt 0 && $PASS_TO_PASS_FAILED -eq 0 ]]; then
  VERDICT="resolved"
  RESOLVED=true
elif [[ $FAIL_TO_PASS_PASSED -gt 0 && $FAIL_TO_PASS_FAILED -gt 0 ]]; then
  VERDICT="partially_resolved"
  RESOLVED=false
else
  VERDICT="not_resolved"
  RESOLVED=false
fi

echo ""
echo "[validate] ═══════════════════════════════════════"
if $RESOLVED; then
  echo "[validate]  ✅ RESOLVED: $INSTANCE_ID"
else
  echo "[validate]  ❌ ${VERDICT^^}: $INSTANCE_ID"
fi
echo "[validate]  FAIL_TO_PASS: ${FAIL_TO_PASS_PASSED}/${FAIL_TEST_COUNT} passed"
if [[ $PASS_TEST_COUNT -gt 0 && $PASS_TEST_COUNT -le 20 ]]; then
  echo "[validate]  PASS_TO_PASS: ${PASS_TO_PASS_PASSED}/${PASS_TEST_COUNT} still pass (${PASS_TO_PASS_FAILED} regressions)"
fi
echo "[validate] ═══════════════════════════════════════"

# --- Write validation result ---
cat > "$TASK_DIR/validation-result.json" << ENDJSON
{
  "instance_id": "$INSTANCE_ID",
  "verdict": "$VERDICT",
  "resolved": $RESOLVED,
  "test_patch_applied": $TEST_PATCH_APPLIED,
  "deps_installed": $DEPS_INSTALLED,
  "fail_to_pass": {
    "total": $FAIL_TEST_COUNT,
    "passed": $FAIL_TO_PASS_PASSED,
    "failed": $FAIL_TO_PASS_FAILED,
    "errors": $FAIL_TO_PASS_ERRORS
  },
  "pass_to_pass": {
    "total": $PASS_TEST_COUNT,
    "passed": $PASS_TO_PASS_PASSED,
    "failed": $PASS_TO_PASS_FAILED,
    "errors": $PASS_TO_PASS_ERRORS
  }
}
ENDJSON

$RESOLVED && exit 0 || exit 1
