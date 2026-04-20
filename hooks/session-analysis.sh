#!/usr/bin/env bash
# claude-watchdog Stop hook: preprocesses the session transcript and triggers
# the session-analyzer subagent (via exit 2 injection) to provide critical analysis.
# No external API calls — analysis happens in-session via the Agent tool.
# Logs debug info to ~/.claude/logs/claude-watchdog.log (rotated at ~1000 lines).

set -euo pipefail

LOG_FILE="${CLAUDE_WATCHDOG_LOG:-$HOME/.claude/logs/claude-watchdog.log}"
MAX_LINES="${CLAUDE_WATCHDOG_LOG_MAX_LINES:-1000}"
MIN_TRANSCRIPT_LINES="${CLAUDE_WATCHDOG_MIN_LINES:-10}"
CONDENSED_MAX_BYTES="${CLAUDE_WATCHDOG_MAX_BYTES:-51200}"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG_FILE"
}

rotate_log() {
  local current_lines
  current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$current_lines" -gt "$MAX_LINES" ]; then
    tail -n "$MAX_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    log "LOG ROTATED (was ${current_lines} lines)"
  fi
}

# On any error: log it, allow Claude to stop normally
trap 'log "ERROR: unexpected failure at line $LINENO"; exit 0' ERR

if ! command -v jq >/dev/null 2>&1; then
  log "SKIP: jq not found on PATH"
  exit 0
fi

input="$(cat)"

session_id="$(echo "$input" | jq -r '.session_id')"
transcript_path="$(echo "$input" | jq -r '.transcript_path')"
hook_cwd="$(echo "$input" | jq -r '.cwd')"
# Docs say stop_reason has values: end_turn, max_tokens, tool_use
# In practice the field may be absent/null — treat that as end_turn
stop_reason="$(echo "$input" | jq -r '.stop_reason // "end_turn"')"

# Log the full event JSON with content values truncated to 200 chars
event_summary="$(echo "$input" | jq -c '
  walk(if type == "string" and length > 200 then .[:200] + "...[truncated]" else . end)
' 2>/dev/null || echo "$input")"

log "--- session=${session_id} stop_reason=${stop_reason} ---"
log "event: ${event_summary}"
rotate_log

# --- Guards (exit 0 = allow stop, no analysis) ---

if [ "$stop_reason" != "end_turn" ]; then
  log "SKIP: stop_reason is '${stop_reason}', not 'end_turn'"
  exit 0
fi

MARKER="/tmp/claude-watchdog-${session_id}"
if [ -f "$MARKER" ]; then
  log "SKIP: marker file exists (already analyzed this session)"
  exit 0
fi

if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
  log "SKIP: transcript not found at '${transcript_path}'"
  exit 0
fi

line_count=$(wc -l < "$transcript_path")
log "transcript lines: ${line_count}"
if [ "$line_count" -lt "$MIN_TRANSCRIPT_LINES" ]; then
  log "SKIP: transcript too short (${line_count} lines < ${MIN_TRANSCRIPT_LINES})"
  exit 0
fi

# --- Processing ---

touch "$MARKER"
log "marker created: ${MARKER}"

CONDENSED_FILE="/tmp/claude-watchdog-condensed-${session_id}.txt"
jq -r '
  if .type == "user" then
    if (.message.content | type) == "string" then
      "USER: " + .message.content
    elif (.message.content | type) == "array" then
      .message.content[] | select(.type == "text") | "USER: " + .text
    else empty end
  elif .type == "assistant" then
    .message.content[]? | select(.type == "text") | "ASSISTANT: " + .text
  else empty end
' "$transcript_path" 2>/dev/null | tail -c "$CONDENSED_MAX_BYTES" > "$CONDENSED_FILE"

condensed_size=$(wc -c < "$CONDENSED_FILE" 2>/dev/null || echo 0)
log "condensed file: ${CONDENSED_FILE} (${condensed_size} bytes)"

if [ ! -s "$CONDENSED_FILE" ]; then
  log "SKIP: condensed transcript is empty (jq produced no output)"
  rm -f "$MARKER"
  exit 0
fi

# --- Trigger analysis via exit 2 injection ---

log "TRIGGER: injecting session-analyzer subagent request (exit 2)"

cat >&2 <<EOF
Please spawn a session-analyzer agent to critically analyze this session.

Use the Agent tool with:
- subagent_type: "session-analyzer"
- model: "sonnet"
- prompt: "Read and analyze the condensed session transcript at ${CONDENSED_FILE}. The working directory is ${hook_cwd}. Provide your critical analysis."

Present the analysis to the user, then stop.
EOF
exit 2
