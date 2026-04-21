#!/usr/bin/env bash
# claude-watchdog SubagentStop hook: persist session-analyzer output to disk.
# Fires when any subagent completes. We filter to session-analyzer by
# inspecting agent_type in the event payload, and write last_assistant_message
# to the analyses directory. This avoids having the subagent call Write itself,
# which clutters the UI with a file-preview block.

set -euo pipefail

LOG_FILE="${CLAUDE_WATCHDOG_LOG:-$HOME/.claude/logs/claude-watchdog.log}"
ANALYSES_DIR="${CLAUDE_WATCHDOG_ANALYSES_DIR:-$HOME/.claude/logs/claude-watchdog-analyses}"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$ANALYSES_DIR"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [persist] $*" >> "$LOG_FILE"
}

trap 'log "ERROR: unexpected failure at line $LINENO"; exit 0' ERR

if ! command -v jq >/dev/null 2>&1; then
  log "SKIP: jq not found on PATH"
  exit 0
fi

input="$(head -c 131072)"

agent_type="$(echo "$input" | jq -r '.agent_type // ""')"
session_id="$(echo "$input" | jq -r '.session_id // ""')"
message="$(echo "$input" | jq -r '.last_assistant_message // ""')"

if [ "$agent_type" != "session-analyzer" ]; then
  exit 0
fi

if [[ ! "$session_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  log "SKIP: invalid session_id"
  exit 0
fi

if [ -z "$message" ]; then
  log "SKIP: empty last_assistant_message for session=${session_id}"
  exit 0
fi

output_file="${ANALYSES_DIR}/${session_id}-$(date -u '+%Y%m%dT%H%M%SZ').md"
printf '%s\n' "$message" > "$output_file"
log "WROTE: ${output_file} ($(wc -c < "$output_file" | tr -d ' ') bytes)"

# Keep only 20 most recent analyses (same policy as session-analysis.sh)
ls -t "$ANALYSES_DIR"/*.md 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

exit 0
