# youBencha Benchmark

TDD-style benchmark with 5 built-in coding tasks.

## Test Cases

| # | Name | Type | What It Tests |
|---|------|------|---------------|
| 001 | Add README Comment | Modify file | Can agent edit existing files? |
| 002 | Create Hello World | Create file | Can agent create new files with functions? |
| 003 | Fix Off-by-One Bug | Debug & fix | Can agent find and fix bugs? |
| 004 | Add Unit Tests | Write tests | Can agent write meaningful tests? |
| 005 | Refactor to Dictionary | Refactor | Can agent improve code structure? |

## Running

```bash
# Quick smoke test (2 tests)
./scripts/bench.sh youbencha --agent pi --num-tests 2

# All 5 tests
./scripts/bench.sh youbencha --agent claude

# With model override
./scripts/bench.sh youbencha --agent pi --model claude-sonnet-4-20250514 --provider anthropic
```

## Evaluation Criteria

Each test checks:
1. **Agent exits cleanly** (exit code 0)
2. **Files were changed** (git diff is non-empty)
3. **Expected file exists** (e.g., `hello.py`)
4. **Expected pattern matches** (e.g., `def greet` in file)

Results: `pass`, `fail`, `timeout`, `error`

## Adding Custom Tests

Create a YAML file in `tests/youbencha/`:

```yaml
name: "My Custom Test"
description: "What this test checks"
repo: https://github.com/user/repo.git  # or "local"
branch: main
prompt: "The instruction for the agent"
expected_file: output.py                 # File that should exist after
expected_pattern: "def my_function"      # Regex to match in expected_file

# For local tests (no git clone):
# repo: local
# local_src: /path/to/source/files
```

## Output Structure

```
results/youbencha/<timestamp>-<agent>/
├── summary.json          # Overall results
├── task-001/
│   ├── result.json       # Task result
│   ├── agent-output.txt  # Agent stdout/stderr
│   ├── git-diff.patch    # Changes made
│   ├── untracked-files.txt
│   └── workspace/        # Cloned repo with changes
├── task-002/
│   └── ...
```
