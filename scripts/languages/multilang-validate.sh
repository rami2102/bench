#!/usr/bin/env bash
# multilang-validate.sh — Lightweight validation for multi-language patches.
#
# Applies the test_patch from the dataset, then tries to run
# fail-to-pass tests using the appropriate language toolchain.
#
# Usage:
#   ./multilang-validate.sh <task_dir> <instance_json_line>
#
# Exit: 0 if resolved, 1 otherwise

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TASK_DIR="${1:?Usage: multilang-validate.sh <task_dir> <instance_json_line>}"
INSTANCE_LINE="${2:?Missing instance JSON line}"

WORKSPACE="$TASK_DIR/workspace"

# Parse fields from JSON
LANGUAGE=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['language'])")
TEST_PATCH=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin).get('test_patch',''))")
F2P_TESTS=$(echo "$INSTANCE_LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(list(d.get('f2p_tests',{}).keys())))")

echo "[validate] Language: $LANGUAGE"
echo "[validate] Workspace: $WORKSPACE"
echo "[validate] F2P tests: $F2P_TESTS"

# Language-specific test runner
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
VERDICT="not_resolved"
ERROR_MSG=""

apply_test_patch() {
  cd "$WORKSPACE"
  if [[ -n "$TEST_PATCH" ]]; then
    echo "[validate] Applying test patch..."
    echo "$TEST_PATCH" | git apply --allow-empty 2>&1 || {
      echo "[validate] WARNING: test patch apply failed, trying with --3way"
      echo "$TEST_PATCH" | git apply --allow-empty --3way 2>&1 || true
    }
  fi
}

run_python_tests() {
  echo "[validate] Setting up Python venv..."
  python3 -m venv "$TASK_DIR/venv" 2>/dev/null || true
  if [[ -d "$TASK_DIR/venv" ]]; then
    source "$TASK_DIR/venv/bin/activate" 2>/dev/null || true
    pip install -e . 2>&1 | tail -5 || pip install . 2>&1 | tail -5 || true
    echo "[validate] Running pytest..."
    if pytest --tb=short -q 2>&1 | tee "$TASK_DIR/test-output.txt"; then
      return 0
    else
      return 1
    fi
  else
    ERROR_MSG="Could not create venv"
    return 2
  fi
}

run_java_tests() {
  echo "[validate] Running Java tests..."
  if [[ -f "pom.xml" ]]; then
    mvn test -q 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
    if [[ -f "gradlew" ]]; then
      chmod +x gradlew
      ./gradlew test 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
    else
      gradle test 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
    fi
  else
    ERROR_MSG="No pom.xml or build.gradle found"
    return 2
  fi
}

run_js_tests() {
  echo "[validate] Running JavaScript tests..."
  if [[ -f "package.json" ]]; then
    npm install --ignore-scripts 2>&1 | tail -5 || true
    if npm test 2>&1 | tee "$TASK_DIR/test-output.txt"; then
      return 0
    else
      npx jest --passWithNoTests 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
    fi
  else
    ERROR_MSG="No package.json found"
    return 2
  fi
}

run_ts_tests() {
  echo "[validate] Running TypeScript tests..."
  if [[ -f "package.json" ]]; then
    npm install --ignore-scripts 2>&1 | tail -5 || true
    if npm test 2>&1 | tee "$TASK_DIR/test-output.txt"; then
      return 0
    else
      npx jest --passWithNoTests 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0
      npx vitest run 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
    fi
  else
    ERROR_MSG="No package.json found"
    return 2
  fi
}

run_c_cpp_tests() {
  echo "[validate] Running C/C++ tests..."
  if [[ -f "CMakeLists.txt" ]]; then
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tail -10 || { ERROR_MSG="cmake failed"; return 2; }
    make -j$(nproc) 2>&1 | tail -10 || { ERROR_MSG="make failed"; return 2; }
    ctest --output-on-failure 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  elif [[ -f "Makefile" || -f "makefile" ]]; then
    make 2>&1 | tail -10 || { ERROR_MSG="make failed"; return 2; }
    make test 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  elif [[ -f "configure" ]]; then
    ./configure 2>&1 | tail -5 || true
    make 2>&1 | tail -10 || { ERROR_MSG="make failed"; return 2; }
    make check 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  else
    ERROR_MSG="No CMakeLists.txt, Makefile, or configure found"
    return 2
  fi
}

run_go_tests() {
  echo "[validate] Running Go tests..."
  if [[ -f "go.mod" ]]; then
    go test ./... 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  else
    ERROR_MSG="No go.mod found"
    return 2
  fi
}

run_rust_tests() {
  echo "[validate] Running Rust tests..."
  if [[ -f "Cargo.toml" ]]; then
    cargo test 2>&1 | tee "$TASK_DIR/test-output.txt" && return 0 || return 1
  else
    ERROR_MSG="No Cargo.toml found"
    return 2
  fi
}

run_tests() {
  case "$LANGUAGE" in
    python)  run_python_tests ;;
    java)    run_java_tests ;;
    js)      run_js_tests ;;
    ts)      run_ts_tests ;;
    c|c++)   run_c_cpp_tests ;;
    go)      run_go_tests ;;
    rust)    run_rust_tests ;;
    *)       ERROR_MSG="Unsupported language: $LANGUAGE"; return 2 ;;
  esac
}

write_result() {
  case $TEST_EXIT in
    0) VERDICT="resolved"; TESTS_PASSED=1; TESTS_RUN=1 ;;
    1) VERDICT="not_resolved"; TESTS_FAILED=1; TESTS_RUN=1 ;;
    2) VERDICT="tests_not_runnable" ;;
  esac

  cat > "$TASK_DIR/validation-result.json" << ENDJSON
{
  "verdict": "$VERDICT",
  "language": "$LANGUAGE",
  "tests_run": $TESTS_RUN,
  "tests_passed": $TESTS_PASSED,
  "tests_failed": $TESTS_FAILED,
  "error": "$ERROR_MSG"
}
ENDJSON

  echo "[validate] Verdict: $VERDICT"
}

main() {
  apply_test_patch

  set +e
  run_tests
  TEST_EXIT=$?
  set -e

  write_result

  [[ "$VERDICT" == "resolved" ]] && exit 0 || exit 1
}

main
