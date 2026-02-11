# bench — AI Coding Agent Benchmark Runner

Run **youBencha** and **SWE-Bench Lite** against any CLI coding agent from a single unified interface.

## Supported Agents

| Agent | CLI Command | Non-Interactive Flag | Auto-Approve Flag |
|-------|-------------|---------------------|-------------------|
| **Claude Code** | `claude` | `-p` (print mode) | `--dangerously-skip-permissions` |
| **Codex** | `codex` | `exec` subcommand | `--full-auto` |
| **Gemini CLI** | `gemini` | `-p <prompt>` | `-y` (YOLO mode) |
| **pi** | `pi` | `-p` (print mode) | `--no-session` |

## Quick Start

```bash
# 1. Run 2 quick youBencha tests with pi
./scripts/bench.sh youbencha --agent pi --num-tests 2

# 2. Run 1 SWE-bench task with Claude Code
./scripts/bench.sh swebench --agent claude --num-tests 1

# 3. Compare agents on same tests
./scripts/bench.sh youbencha -a claude -n 5
./scripts/bench.sh youbencha -a pi -n 5
./scripts/bench.sh youbencha -a gemini -n 5
./scripts/bench.sh youbencha -a codex -n 5

# 4. Lightweight cross-agent preset (youBencha + SWE-Bench)
./scripts/light-test.sh --agent pi
```

See [LIGHT_TESTS.md](LIGHT_TESTS.md) for selected vs random light runs.

## Benchmarks

### youBencha (Custom TDD Tests)

5 built-in tests covering:
1. **Add README Comment** — modify existing file
2. **Create Hello World** — create new file with function
3. **Fix Off-by-One Bug** — debug and fix code
4. **Add Unit Tests** — write pytest tests for module
5. **Refactor Code** — refactor if/elif to dictionary

```bash
# Run all 5 tests
./scripts/bench.sh youbencha --agent pi

# Quick smoke test (2 tests)
./scripts/bench.sh youbencha --agent pi --num-tests 2

# With specific model
./scripts/bench.sh youbencha --agent claude --model claude-sonnet-4-20250514
```

See [YOUBENCHA.md](YOUBENCHA.md) for details.

### SWE-Bench Lite (Real GitHub Issues)

300 real GitHub issues from 12 Python repositories. The agent must generate a patch that resolves the issue.

```bash
# Run 2 random tasks
./scripts/bench.sh swebench --agent pi --num-tests 2

# Run specific instance
./scripts/bench.sh swebench --agent claude --instance-ids "sympy__sympy-20590"

# Run with official harness evaluation
./scripts/bench.sh swebench --agent claude --num-tests 5 --use-harness
```

See [SWEBENCH.md](SWEBENCH.md) for details.

## Directory Layout

```
bench/
├── README.md              # This file
├── YOUBENCHA.md           # youBencha benchmark docs
├── SWEBENCH.md            # SWE-Bench Lite docs
├── AGENTS.md              # Agent CLI reference
├── scripts/
│   ├── bench.sh           # Unified entry point
│   ├── agent-run.sh       # Agent CLI wrapper
│   ├── youbencha-run.sh   # youBencha runner
│   ├── youbencha-init.sh  # Create sample tests
│   └── swebench-run.sh    # SWE-Bench Lite runner
├── tests/
│   └── youbencha/         # Test YAML files (auto-created)
├── results/               # Run results (gitignored)
│   ├── youbencha/
│   └── swebench/
└── cache/                 # Dataset cache (gitignored)
    └── swebench/
```

## Requirements

- **bash** 4+
- **git**
- **python3** with `datasets` package (for SWE-bench)
- At least one agent CLI installed: `claude`, `codex`, `gemini`, or `pi`
- API keys set in environment (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
