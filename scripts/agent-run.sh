#!/usr/bin/env bash
# agent-run.sh — Unified wrapper to run any supported coding agent CLI
# in non-interactive mode with a given prompt inside a working directory.
#
# Usage:
#   ./agent-run.sh <agent> <workdir> <prompt> [model]
#
# Agents: claude, codex, gemini, pi
# Exit code: pass-through from agent CLI

set -euo pipefail

AGENT="${1:?Usage: agent-run.sh <agent> <workdir> <prompt> [model]}"
WORKDIR="${2:?Missing workdir}"
PROMPT="${3:?Missing prompt}"
MODEL="${4:-}"

cd "$WORKDIR"

case "$AGENT" in
  claude)
    CMD=(claude -p --dangerously-skip-permissions --output-format text)
    [[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
    CMD+=("$PROMPT")
    ;;
  codex)
    CMD=(codex exec --full-auto)
    [[ -n "$MODEL" ]] && CMD+=(-m "$MODEL")
    CMD+=("$PROMPT")
    ;;
  gemini)
    CMD=(gemini -p "$PROMPT" --sandbox false -y)
    [[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
    ;;
  pi)
    CMD=(pi -p --no-session)
    [[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
    CMD+=("$PROMPT")
    ;;
  *)
    echo "ERROR: Unknown agent '$AGENT'. Supported: claude, codex, gemini, pi" >&2
    exit 1
    ;;
esac

echo "[agent-run] Agent: $AGENT | Model: ${MODEL:-default} | Dir: $WORKDIR" >&2
echo "[agent-run] Running: ${CMD[*]}" >&2

exec "${CMD[@]}"
