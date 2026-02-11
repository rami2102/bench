#!/usr/bin/env bash
# youbencha-init.sh — Create sample youBencha test cases
# Usage: ./youbencha-init.sh [tests-dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
TESTS_DIR="${1:-$BENCH_DIR/tests/youbencha}"

mkdir -p "$TESTS_DIR"

# Test 1: Add a comment to README
cat > "$TESTS_DIR/001-readme-comment.yaml" << 'EOF'
name: "Add README Comment"
description: "Agent should add a helpful comment to the top of README.md"
repo: https://github.com/youbencha/hello-world.git
branch: main
prompt: "Add a comment at the very top of README.md that says: # This is a test repository for benchmarking AI coding agents. Do NOT remove any existing content."
expected_file: README.md
expected_pattern: "test repository"
EOF

# Test 2: Create a new file
cat > "$TESTS_DIR/002-create-hello.yaml" << 'EOF'
name: "Create Hello World Script"
description: "Agent should create a hello.py file with a hello world function"
repo: https://github.com/youbencha/hello-world.git
branch: main
prompt: "Create a new file called hello.py with a function called greet(name) that returns the string 'Hello, {name}!'. Include a main block that calls greet('World') and prints the result."
expected_file: hello.py
expected_pattern: "def greet"
EOF

# Test 3: Fix a bug
cat > "$TESTS_DIR/003-fix-bug.yaml" << 'EOF'
name: "Fix Off-by-One Bug"
description: "Agent should fix an off-by-one error in a simple script"
repo: local
local_src:
prompt: "There is a file called counter.py with an off-by-one bug in the count_up function. The function should count from 1 to n (inclusive), but currently it counts from 1 to n-1. Fix the bug."
expected_file: counter.py
expected_pattern: "range\(1,\s*n\s*\+\s*1\)"
EOF

# Create the local source for test 3
LOCAL_003="$TESTS_DIR/local-src/003"
mkdir -p "$LOCAL_003"
cat > "$LOCAL_003/counter.py" << 'PYEOF'
def count_up(n):
    """Count from 1 to n inclusive."""
    result = []
    for i in range(1, n):  # BUG: should be range(1, n+1)
        result.append(i)
    return result

if __name__ == "__main__":
    print(count_up(5))  # Should print [1, 2, 3, 4, 5]
PYEOF

# Patch test 3 to point to local src
sed -i "s|^local_src:$|local_src: $LOCAL_003|" "$TESTS_DIR/003-fix-bug.yaml"

# Test 4: Add unit tests
cat > "$TESTS_DIR/004-add-tests.yaml" << 'EOF'
name: "Add Unit Tests"
description: "Agent should create unit tests for an existing module"
repo: local
local_src:
prompt: "Create a test file called test_math_utils.py that tests the add and multiply functions in math_utils.py using pytest. Write at least 3 test cases."
expected_file: test_math_utils.py
expected_pattern: "def test_"
EOF

LOCAL_004="$TESTS_DIR/local-src/004"
mkdir -p "$LOCAL_004"
cat > "$LOCAL_004/math_utils.py" << 'PYEOF'
def add(a, b):
    """Return the sum of a and b."""
    return a + b

def multiply(a, b):
    """Return the product of a and b."""
    return a * b
PYEOF
sed -i "s|^local_src:$|local_src: $LOCAL_004|" "$TESTS_DIR/004-add-tests.yaml"

# Test 5: Refactor code
cat > "$TESTS_DIR/005-refactor.yaml" << 'EOF'
name: "Refactor to Use Dictionary"
description: "Agent should refactor if/elif chain to use a dictionary lookup"
repo: local
local_src:
prompt: "Refactor the get_day_name function in days.py to use a dictionary lookup instead of the if/elif chain. Keep the same function signature and behavior."
expected_file: days.py
expected_pattern: "(dict|{.*:.*})"
EOF

LOCAL_005="$TESTS_DIR/local-src/005"
mkdir -p "$LOCAL_005"
cat > "$LOCAL_005/days.py" << 'PYEOF'
def get_day_name(day_number):
    """Return the name of the day for a given number (1=Monday)."""
    if day_number == 1:
        return "Monday"
    elif day_number == 2:
        return "Tuesday"
    elif day_number == 3:
        return "Wednesday"
    elif day_number == 4:
        return "Thursday"
    elif day_number == 5:
        return "Friday"
    elif day_number == 6:
        return "Saturday"
    elif day_number == 7:
        return "Sunday"
    else:
        return "Invalid day"

if __name__ == "__main__":
    for i in range(1, 8):
        print(f"{i}: {get_day_name(i)}")
PYEOF
sed -i "s|^local_src:$|local_src: $LOCAL_005|" "$TESTS_DIR/005-refactor.yaml"

echo "Created ${TESTS_DIR}:"
ls -la "$TESTS_DIR"/*.yaml
echo ""
echo "Run with:"
echo "  $SCRIPT_DIR/youbencha-run.sh --agent pi --num-tests 2"
echo "  $SCRIPT_DIR/youbencha-run.sh --agent claude --num-tests 5"
