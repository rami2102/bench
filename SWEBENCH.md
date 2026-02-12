# SWE-Bench Lite Benchmark

Run real GitHub issues from SWE-Bench Lite (300 tasks) against any agent.

## How It Works

1. Downloads the SWE-Bench Lite dataset (cached locally)
2. For each task: clones the repo, checks out the base commit
3. Sends the issue description to the agent as a prompt
4. Captures the git diff as a patch
5. **Validates the fix** by:
   - Applying the dataset's `test_patch` (adds test cases)
   - Installing the project in a venv
   - Running `FAIL_TO_PASS` tests (must now pass after the fix)
   - Optionally running `PASS_TO_PASS` tests (regression check)
6. Reports `resolved` / `not_resolved` / `partially_resolved`

## Running

```bash
# Quick test: 1 random task
./scripts/bench.sh swebench --agent pi --num-tests 1

# 5 random tasks
./scripts/bench.sh swebench --agent claude --num-tests 5

# Specific instance
./scripts/bench.sh swebench --agent pi --instance-ids "django__django-11049"

# With official harness evaluation (requires Docker + swebench package)
./scripts/bench.sh swebench --agent claude --num-tests 5 --use-harness
```

## Prerequisites

```bash
# Required: Python datasets library
pip install datasets

# Optional: Official SWE-bench harness (for verified evaluation)
cd ~/git/SWE-bench && pip install -e .
# Also requires Docker for the official harness
```

## Host (Non-Podman) Multi-Agent Runs

Run the same multi-agent logic directly on host (no Podman):

```bash
# Deterministic first N from round-robin list
./scripts/swebench-run-multi.sh --agents codex,pi --num-tests 10

# Same tests for all selected agents in parallel
./scripts/swebench-run-multi.sh --agents all --parallel --test-list-file tests/swebench/round-robin-by-repo.md --num-tests 20

# Exact explicit instances
./scripts/swebench-run-multi.sh --agents gemini,pi --instance-ids "django__django-11049,sympy__sympy-20590"
```

Notes:
- Supports the same selection switches as Podman runner (`--agents`, `--parallel`, `--num-tests`, `--instance-ids`, `--test-list-file`).
- Saves per-agent results and per-agent percentages under `results/swebench/<timestamp>-host-run/...`.

## Podman (Isolated) Runs

Use the full runner for isolated SWE-bench evaluation in Podman (validation enabled by default):

```bash
# Build + run via one wrapper
./scripts/podman-swebench-all.sh --agents codex,pi --num-tests 10

# Same ordered tests for all agents, in parallel
./scripts/podman-swebench-all.sh --agents all --parallel --test-list-file tests/swebench/round-robin-by-repo.md --num-tests 20

# Exact explicit instances
./scripts/podman-swebench-run.sh --agents gemini,pi --instance-ids "django__django-11049,sympy__sympy-20590"
```

Notes:
- `scripts/podman-swebench-run.sh` supports `--agents <list|all>`, `--parallel`, `--num-tests <N|all>`, `--instance-ids`, `--test-list-file`.
- Results persist on host disk after Podman exits under `results/swebench/<timestamp>-podman-run/...` (host folder is bind-mounted into container).
- Repo caches are pre-cloned on host via `scripts/swebench-cache-local.sh` and mounted read-only at `cache/swebench/repos`.
- Auth is reused non-interactively by mounting local agent auth folders (`~/.codex`, `~/.gemini`, `~/.pi`, `~/.claude`).
- SWE-bench Lite is Python-focused; balancing is done round-robin by repository using `tests/swebench/round-robin-by-repo.md`.

## Dataset

- **Source:** `princeton-nlp/SWE-bench_Lite` from HuggingFace
- **Tasks:** 300 curated GitHub issues from 12 Python repos
- **Repos:** Django, Flask, Matplotlib, Scikit-learn, Sympy, etc.
- **Cached at:** `cache/swebench/swe-bench-lite.jsonl`

## Evaluation Levels

### Level 1: Test Validation (default)
For each patch, the script:
- Creates a Python venv and installs the project
- Applies the dataset's `test_patch` (adds/updates test cases)
- Runs `FAIL_TO_PASS` tests via pytest — these should pass after a correct fix
- Runs `PASS_TO_PASS` tests (up to 20) — checks for regressions
- **Verdict:** `resolved`, `partially_resolved`, `not_resolved`, `tests_not_runnable`

⚠️ **Limitations:** Some older repos need specific Python versions (e.g., Python 3.8/3.9).
If tests can't run due to dependency issues, the verdict is `tests_not_runnable`.
For full compatibility, use the official Docker harness.

### Level 2: `--no-validate` (patch-only)
Skip all validation. Only checks if a patch was generated.

### Level 3: Official Docker Harness (`--use-harness`)
Runs the full SWE-bench evaluation in Docker containers with correct Python versions:
- Applies the patch to the repo
- Runs the project's full test suite
- Reports pass/fail based on tests
- Requires: Docker + `pip install swebench`

## Output Structure

```
results/swebench/<timestamp>-<agent>/
├── summary.json              # Overall results
├── predictions.json          # SWE-bench format (for official harness)
├── task-001-<instance>/
│   ├── result.json           # Task result + resolved status
│   ├── validation-result.json # Detailed test results
│   ├── validation-output.txt # Full validation log
│   ├── prompt.txt            # The prompt sent to agent
│   ├── agent-output.txt      # Agent stdout/stderr
│   ├── patch.diff            # Agent's generated patch
│   ├── gold-patch.diff       # Ground truth patch (for comparison)
│   ├── test-patch.diff       # Test cases added from dataset
│   ├── test-fail2pass-*.log  # Individual test run logs
│   ├── venv/                 # Python venv used for testing
│   └── workspace/            # Repo at base commit + changes
```

## Costs

| Num Tests | Est. Tokens | Est. Cost (Sonnet) |
|-----------|-------------|-------------------|
| 1 | 100K–500K | $0.10–$0.70 |
| 5 | 500K–2.5M | $0.50–$3.50 |
| 50 | 5M–25M | $5–$35 |
| 300 (all) | 30M–150M | $30–$150 |
