# Multi-Language Coding Benchmark

Run real GitHub issues across **8 programming languages** against any agent.

Based on the [Multi-SWE-bench_mini](https://huggingface.co/datasets/ByteDance-Seed/Multi-SWE-bench_mini) dataset (ByteDance, Apache 2.0 license).

## How It Works

1. Downloads the Multi-SWE-bench_mini dataset (400 tasks, cached locally)
2. Selects tasks in **round-robin by language** for maximum variety
3. For each task: clones the repo, checks out the base commit
4. Sends the issue description to the agent (with language context)
5. Captures the git diff as a patch
6. Optionally validates using lightweight language-specific test runners
7. Reports per-language and overall results

## Languages

| Language   | Code | Tasks | Sample Repos |
|-----------|------|-------|-------------|
| Python    | `python` | 50 | django, astropy, sympy, sphinx, flask |
| JavaScript| `js`     | 50 | dayjs, svelte, material-ui |
| TypeScript| `ts`     | 50 | darkreader, svelte, material-ui |
| Java      | `java`   | 50 | fastjson2, jackson-databind, logstash |
| C++       | `c++`    | 50 | Catch2, json (nlohmann), fmt, simdjson |
| Go        | `go`     | 50 | cli (GitHub CLI) |
| Rust      | `rust`   | 50 | clap, tokio |
| C         | `c`      | 50 | zstd, jq, ponyc |

## Running

```bash
# Quick test: 8 tasks (1 per language, round-robin)
./scripts/bench.sh multilang --agent pi --num-tests 8

# 16 tasks (2 per language)
./scripts/bench.sh multilang --agent claude --num-tests 16

# All 400 tasks
./scripts/bench.sh multilang --agent pi --num-tests all

# Specific language only
./scripts/bench.sh multilang --agent gemini -n 10 --language python

# Multiple languages
./scripts/bench.sh multilang --agent codex -n 20 --language python,java,typescript

# Specific instances
./scripts/bench.sh multilang --agent pi --instance-ids "cli__cli-2282,iamkun__dayjs-2369"

# With validation (tries to run tests — requires language toolchains)
./scripts/bench.sh multilang --agent pi -n 8 --validate
```

## Multi-Agent Runs

```bash
# Same 8 tests for all 4 agents
./scripts/languages/multilang-run-multi.sh --agents all --num-tests 8

# Parallel execution
./scripts/languages/multilang-run-multi.sh --agents all --parallel --num-tests 24

# Specific agents
./scripts/languages/multilang-run-multi.sh --agents pi,claude --num-tests 16

# Python + Java only
./scripts/languages/multilang-run-multi.sh --agents all --parallel -n 20 --language python,java
```

## Prerequisites

```bash
# Required
pip install datasets    # For dataset download (fallback; curl also works)
git                     # For cloning repos

# For validation (optional, per language):
python3, pip            # Python tasks
node, npm               # JavaScript/TypeScript tasks
javac, mvn or gradle    # Java tasks
cmake, make, g++        # C/C++ tasks
go                      # Go tasks
cargo                   # Rust tasks
```

## Round-Robin Ordering

Tasks are ordered round-robin by language so that **every N tests you run covers the maximum language variety**:

| Tests | Languages Covered |
|-------|-------------------|
| 1     | 1 (Python) |
| 4     | 4 (Python, JS, TS, Java) |
| 8     | 8 (all languages) |
| 16    | 8 (2 tasks per language) |
| 24    | 8 (3 tasks per language) |
| 400   | 8 (50 tasks per language) |

Order: Python → JavaScript → TypeScript → Java → C++ → Go → Rust → C → repeat

Within each language, tasks are sorted by difficulty: easy → medium → hard.

## Dataset

- **Source:** `ByteDance-Seed/Multi-SWE-bench_mini` from HuggingFace
- **Tasks:** 400 curated GitHub issues from 20+ repositories
- **Languages:** 8 (50 per language, balanced)
- **Difficulty:** Easy, Medium, Hard
- **License:** Apache 2.0 (benchmark); individual repos have various OSS licenses
- **Cached at:** `cache/multilang/multi-swe-bench-mini.jsonl`

## Output Structure

```
results/multilang/<timestamp>-<agent>/
├── summary.json              # Overall + per-language results
├── predictions.json          # SWE-bench compatible predictions
├── selected-instances.jsonl  # Selected task instances
├── task-001-<instance>/
│   ├── result.json           # Task result (language, difficulty, status)
│   ├── prompt.txt            # Prompt sent to agent
│   ├── agent-output.txt      # Agent stdout/stderr
│   ├── patch.diff            # Agent's generated patch
│   ├── gold-patch.diff       # Ground truth patch
│   ├── test-patch.diff       # Test patch from dataset
│   ├── validation-result.json # (if --validate) test results
│   ├── validation-output.txt  # (if --validate) test output
│   └── workspace/            # Repo at base commit + changes
```

## Test Lists

Pre-generated test lists in `tests/multilang/`:

| File | Description |
|------|-------------|
| `round-robin-by-language.md` | All 400 tasks, round-robin ordered |
| `by-language-python.md` | 50 Python tasks |
| `by-language-javascript.md` | 50 JavaScript tasks |
| `by-language-typescript.md` | 50 TypeScript tasks |
| `by-language-java.md` | 50 Java tasks |
| `by-language-cpp.md` | 50 C++ tasks |
| `by-language-go.md` | 50 Go tasks |
| `by-language-rust.md` | 50 Rust tasks |
| `by-language-c.md` | 50 C tasks |

To regenerate: `./scripts/languages/multilang-build-test-lists.sh`

## Costs

| Num Tests | Languages | Est. Tokens | Est. Cost (Sonnet) |
|-----------|-----------|-------------|-------------------|
| 8         | 8 (1 each) | 800K–4M | $0.80–$5.00 |
| 16        | 8 (2 each) | 1.6M–8M | $1.60–$10.00 |
| 50        | 8 (6 each) | 5M–25M | $5–$35 |
| 400 (all) | 8 (50 each) | 40M–200M | $40–$200 |

## Comparison with SWE-bench Lite

| Feature | SWE-bench Lite | Multi-Language |
|---------|---------------|----------------|
| Tasks | 300 | 400 |
| Languages | 1 (Python) | 8 |
| Repos | 12 | 20+ |
| Validation | Docker harness | Lightweight local |
| Dataset | princeton-nlp | ByteDance-Seed |

## Research Notes

### Related Benchmarks

- **[Multi-SWE-bench](https://multi-swe-bench.github.io/)** (ByteDance, 2024–2025): 1,632 instances across 7 languages (Java, TypeScript, JavaScript, Go, Rust, C, C++). Apache 2.0 license. We use the **mini** subset (400 instances, 50 per language including Python).

- **[SWE-PolyBench](https://github.com/amazon-science/SWE-PolyBench)** (Amazon, 2025): 2,110 instances across 4 languages (Java 165, JavaScript 1017, TypeScript 729, Python 199). Apache 2.0 license. Skewed toward JS/TS.

- **[SWE-bench Multilingual](https://www.swebench.com/multilingual.html)** (Official, 2025): 300 tasks across 9 languages (C, C++, Go, Java, JavaScript, TypeScript, PHP, Ruby, Rust). Balanced but private evaluation only.

### Why Multi-SWE-bench_mini?

- ✅ **8 languages** with equal 50-task coverage (perfectly balanced)
- ✅ **Apache 2.0 license** — free for commercial use
- ✅ **Manageable size** — 400 tasks vs. 1,632+ for full datasets
- ✅ **Difficulty levels** — easy/medium/hard per language
- ✅ **Same format** as SWE-bench (compatible tooling)
- ✅ **Docker harness available** via multi-swe-bench-env
