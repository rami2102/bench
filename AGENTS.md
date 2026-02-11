# Agent CLI Reference

How each agent is invoked in non-interactive mode by `agent-run.sh`.

## Claude Code (`claude`)

```bash
claude -p \
  --dangerously-skip-permissions \
  --output-format text \
  [--model <model>] \
  "<prompt>"
```

| Flag | Purpose |
|------|---------|
| `-p` / `--print` | Non-interactive print mode |
| `--dangerously-skip-permissions` | Skip all permission prompts |
| `--output-format text` | Plain text output |
| `--model <model>` | Model override (e.g., `claude-sonnet-4-20250514`) |
| `--append-system-prompt` | Add to system prompt |

**Default model:** Claude Sonnet (latest)
**Env var:** `ANTHROPIC_API_KEY`

---

## Codex (`codex`)

```bash
codex exec \
  --full-auto \
  [-m <model>] \
  "<prompt>"
```

| Flag | Purpose |
|------|---------|
| `exec` | Non-interactive subcommand |
| `--full-auto` | Auto-approve + sandbox |
| `-m <model>` | Model override (e.g., `o3`, `o4-mini`) |
| `--dangerously-bypass-approvals-and-sandbox` | Alternative: no sandbox at all |
| `-c model="o3"` | Config-style model override |

**Default model:** o4-mini
**Env var:** `OPENAI_API_KEY`

---

## Gemini CLI (`gemini`)

```bash
gemini \
  -p "<prompt>" \
  --sandbox false \
  -y \
  [--model <model>]
```

| Flag | Purpose |
|------|---------|
| `-p <prompt>` | Non-interactive headless mode |
| `-y` / `--yolo` | Auto-approve all tool actions |
| `--sandbox false` | Disable sandbox |
| `--model <model>` | Model override (e.g., `gemini-2.5-pro`) |
| `--approval-mode yolo` | Alternative to `-y` |
| `--raw-output` | Disable output sanitization |

**Default model:** gemini-2.5-flash
**Env var:** `GOOGLE_API_KEY` or `GEMINI_API_KEY`

---

## pi (`pi`)

```bash
pi -p \
  --no-session \
  [--model <model>] \
  [--provider <provider>] \
  "<prompt>"
```

| Flag | Purpose |
|------|---------|
| `-p` / `--print` | Non-interactive mode: process prompt and exit |
| `--no-session` | Ephemeral, don't save session |
| `--model <model>` | Model override (e.g., `claude-sonnet-4-20250514`) |
| `--provider <name>` | Provider (anthropic, openai, google) |
| `--tools <list>` | Limit tools (default: read,bash,edit,write) |
| `--thinking <level>` | Thinking level: off, minimal, low, medium, high |
| `--no-extensions` | Disable extensions |
| `--no-skills` | Disable skills |

**Default model:** gemini-2.5-flash
**Default provider:** google
**Env vars:** `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or Google auth via `/login`

---

## Adding a New Agent

Edit `scripts/agent-run.sh` and add a new case:

```bash
  my-agent)
    CMD=(my-agent-cli --non-interactive)
    [[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
    CMD+=("$PROMPT")
    ;;
```

Requirements:
1. CLI must accept a prompt and run non-interactively
2. CLI must be able to read/write files in the current directory
3. CLI should exit with code 0 on success
