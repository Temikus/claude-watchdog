set shell := ["bash", "-uc"]

default:
    @just --list

# Validate JSON manifests with jq
lint:
    jq empty .claude-plugin/plugin.json
    jq empty hooks/hooks.json
    bash -n hooks/session-analysis.sh

# Smoke-test the hook with a fake Stop event (uses a scratch transcript)
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    tmpdir=$(mktemp -d)
    transcript="$tmpdir/transcript.jsonl"
    for i in $(seq 1 12); do
      printf '{"type":"user","message":{"content":"hello %s"}}\n' "$i" >> "$transcript"
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"ack %s"}]}}\n' "$i" >> "$transcript"
    done
    session_id="smoketest-$$"
    payload=$(jq -n --arg sid "$session_id" --arg tp "$transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload" | CLAUDE_WATCHDOG_LOG="$tmpdir/log" bash hooks/session-analysis.sh && rc=$? || rc=$?
    echo "hook exit: $rc (expected 2)"
    echo "--- log ---"
    cat "$tmpdir/log"
    rm -f "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-${session_id}" \
          "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-condensed-${session_id}.txt"

# Install instructions
install-hint:
    @echo "In Claude Code, run:"
    @echo "  /plugin marketplace add Temikus/claude-plugins"
    @echo "  /plugin install claude-watchdog@temikus"
