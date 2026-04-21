#!/usr/bin/env bash
# claude-watchdog Stop hook: preprocesses the session transcript and triggers
# the session-analyzer subagent (via exit 2 injection) to provide critical analysis.
# No external API calls — analysis happens in-session via the Agent tool.
# Logs debug info to ~/.claude/logs/claude-watchdog.log (rotated at ~1000 lines).

set -euo pipefail

LOG_FILE="${CLAUDE_WATCHDOG_LOG:-$HOME/.claude/logs/claude-watchdog.log}"
MAX_LINES="${CLAUDE_WATCHDOG_LOG_MAX_LINES:-1000}"
MIN_TOOL_USES="${CLAUDE_WATCHDOG_MIN_TOOL_USES:-8}"
CONDENSED_MAX_BYTES="${CLAUDE_WATCHDOG_MAX_BYTES:-51200}"
WATCHDOG_TMP="${CLAUDE_WATCHDOG_TMP:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/tmp/claude-watchdog}}"
SESSIONS_DIR="$WATCHDOG_TMP/sessions"
ANALYSES_DIR="${CLAUDE_WATCHDOG_ANALYSES_DIR:-$HOME/.claude/logs/claude-watchdog-analyses}"
CURSOR_TTL_DAYS="${CLAUDE_WATCHDOG_CURSOR_TTL_DAYS:-7}"
CURSOR_SLICE="${CLAUDE_WATCHDOG_CURSOR_SLICE:-$(dirname "$0")/cursor-slice.mjs}"
COOLDOWN_SECONDS="${CLAUDE_WATCHDOG_COOLDOWN_SECONDS:-600}"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$WATCHDOG_TMP" && chmod 700 "$WATCHDOG_TMP"
mkdir -p "$SESSIONS_DIR" && chmod 700 "$SESSIONS_DIR"
mkdir -p "$ANALYSES_DIR"

# Cleanup: condensed/raw/delta files older than 2 hours
find "$SESSIONS_DIR" -maxdepth 1 -type f \( -name 'condensed-*' -o -name 'raw-*' -o -name 'delta-*' \) -mmin +120 -delete 2>/dev/null || true
# Cleanup: marker directories older than 2 hours (empty dirs from atomic mkdir)
find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +120 -exec rmdir {} + 2>/dev/null || true
# Cleanup: cursor files older than CURSOR_TTL_DAYS days
find "$SESSIONS_DIR" -maxdepth 1 -type f -name 'cursor-*' -mtime "+${CURSOR_TTL_DAYS}" -delete 2>/dev/null || true

# Keep only 20 most recent analyses
ls -t "$ANALYSES_DIR"/*.md 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true

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

# Per-project disable via environment variable
if [ "${CLAUDE_WATCHDOG_DISABLED:-0}" = "1" ]; then
  log "SKIP: disabled via CLAUDE_WATCHDOG_DISABLED"
  exit 0
fi

input="$(head -c 65536)"

session_id="$(echo "$input" | jq -r '.session_id')"
transcript_path="$(echo "$input" | jq -r '.transcript_path')"
hook_cwd="$(echo "$input" | jq -r '.cwd')"
# Docs say stop_reason has values: end_turn, max_tokens, tool_use
# In practice the field may be absent/null — treat that as end_turn
stop_reason="$(echo "$input" | jq -r '.stop_reason // "end_turn"')"

# Validate session_id format (alphanumeric, hyphens, underscores only)
if [[ ! "$session_id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  log "SKIP: invalid session_id format"
  exit 0
fi

# Log the full event JSON with content values truncated to 200 chars
event_summary="$(echo "$input" | jq -c '
  walk(if type == "string" and length > 200 then .[:200] + "...[truncated]" else . end)
' 2>/dev/null || echo "${input:0:500}")"

log "--- session=${session_id} stop_reason=${stop_reason} ---"
log "event: ${event_summary}"
rotate_log

# --- Guards (exit 0 = allow stop, no analysis) ---

if [ "$stop_reason" != "end_turn" ]; then
  log "SKIP: stop_reason is '${stop_reason}', not 'end_turn'"
  exit 0
fi

# Per-project disable via sentinel file
if [ -n "$hook_cwd" ] && [ -f "${hook_cwd}/.claude-watchdog-skip" ]; then
  log "SKIP: disabled via .claude-watchdog-skip in ${hook_cwd}"
  exit 0
fi

# Short-lived lock (released on EXIT). Prevents concurrent runs for the same session.
MARKER="${SESSIONS_DIR}/${session_id}"
CURSOR_FILE="${SESSIONS_DIR}/cursor-${session_id}.txt"
DELTA_FILE="${SESSIONS_DIR}/delta-${session_id}.tmp"

if ! mkdir "$MARKER" 2>/dev/null; then
  log "SKIP: concurrent run already in progress for ${session_id}"
  exit 0
fi
trap 'rmdir "$MARKER" 2>/dev/null || true; rm -f "$DELTA_FILE" 2>/dev/null || true' EXIT

if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
  log "SKIP: transcript not found at '${transcript_path}'"
  exit 0
fi

# Read cursor if present; validate stored transcript path and integer fields
CURSOR_UUID=""
CURSOR_LINENUM=0
DELTA_START=1
if [ -f "$CURSOR_FILE" ]; then
  CURSOR_UUID=$(sed -n '1p' "$CURSOR_FILE" 2>/dev/null || true)
  raw_linenum=$(sed -n '2p' "$CURSOR_FILE" 2>/dev/null || true)
  CURSOR_TRANSCRIPT=$(sed -n '3p' "$CURSOR_FILE" 2>/dev/null || true)
  if [[ ! "$CURSOR_UUID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log "CURSOR: malformed uuid, ignoring cursor"
    CURSOR_UUID=""
  fi
  if [[ "$raw_linenum" =~ ^[0-9]+$ ]]; then
    CURSOR_LINENUM="$raw_linenum"
  fi
  if [ -n "$CURSOR_TRANSCRIPT" ] && [ ! -f "$CURSOR_TRANSCRIPT" ]; then
    log "CURSOR: stale transcript path, ignoring cursor"
    CURSOR_UUID=""
    CURSOR_LINENUM=0
  fi
fi

# Cooldown: skip if a trigger fired recently for this session.
# The cursor file's mtime is the last-trigger timestamp (updated only on trigger).
if [ "$COOLDOWN_SECONDS" -gt 0 ] && [ -f "$CURSOR_FILE" ]; then
  # GNU stat uses -c %Y (epoch); BSD/macOS uses -f %m. Try GNU first — on GNU,
  # `-f %m` would succeed but return the mount point string, not an epoch.
  cursor_mtime=$(stat -c %Y "$CURSOR_FILE" 2>/dev/null || stat -f %m "$CURSOR_FILE" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if [[ "$cursor_mtime" =~ ^[0-9]+$ ]] && [ "$cursor_mtime" -gt 0 ]; then
    age=$(( now_epoch - cursor_mtime ))
    if [ "$age" -lt "$COOLDOWN_SECONDS" ]; then
      log "SKIP: cooldown active (${age}s < ${COOLDOWN_SECONDS}s since last trigger)"
      exit 0
    fi
  fi
fi

if [ -n "$CURSOR_UUID" ]; then
  slice_out=$(node "$CURSOR_SLICE" slice "$transcript_path" "$CURSOR_UUID" "$CURSOR_LINENUM" 2>>"$LOG_FILE" || echo "DELTA_START=1")
  # Extract integer after DELTA_START=; fall back to 1 if the node script misbehaves
  ds_value="${slice_out#*DELTA_START=}"
  ds_value="${ds_value%%[!0-9]*}"
  if [[ "$ds_value" =~ ^[0-9]+$ ]] && [ "$ds_value" -ge 1 ]; then
    DELTA_START="$ds_value"
  else
    DELTA_START=1
  fi
  log "CURSOR: uuid=${CURSOR_UUID} hint=${CURSOR_LINENUM} -> delta starts at line ${DELTA_START}"
fi

# Build DELTA_FILE from the slice of transcript we haven't analyzed yet
tail -n "+${DELTA_START}" "$transcript_path" > "$DELTA_FILE"

# Count tool_use events in the delta (not the whole transcript) to filter trivial re-triggers
tool_use_count=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name' "$DELTA_FILE" 2>/dev/null | wc -l | tr -d ' ')
log "tool_use count (delta): ${tool_use_count}"
if [ "$tool_use_count" -lt "$MIN_TOOL_USES" ]; then
  log "SKIP: delta too small (${tool_use_count} < ${MIN_TOOL_USES}), cursor unchanged"
  exit 0
fi

# --- Processing ---

umask 077

RAW_FILE="${SESSIONS_DIR}/raw-${session_id}.txt"
CONDENSED_FILE="${SESSIONS_DIR}/condensed-${session_id}.txt"

# Hybrid extraction: structured for known types, catch-all fallback for unknown
jq -r '
  if .type == "user" then
    if (.message.content | type) == "string" then
      "USER: " + .message.content
    elif (.message.content | type) == "array" then
      .message.content[] |
        if .type == "text" then "USER: " + .text
        elif .type == "tool_result" then
          "TOOL_RESULT: " + (
            if (.content | type) == "string" then .content[:500]
            elif (.content | type) == "array" then
              ([.content[] | select(.type == "text") | .text] | join("\n"))[:500]
            else "(no content)" end
          ) + (if .is_error == true then " [ERROR]" else "" end)
        else empty end
    else empty end
  elif .type == "assistant" then
    .message.content[]? |
      if .type == "text" then "ASSISTANT: " + .text
      elif .type == "thinking" then
        "THINKING: " + .thinking[:300]
      elif .type == "tool_use" then
        "TOOL_USE: " + .name + "(" + ((.input | tostring)[:500]) + ")"
      else empty end
  else
    "SYSTEM[" + (.type // "unknown") + "]: " + ((. | tostring)[:200])
  end
' "$DELTA_FILE" 2>/dev/null > "$RAW_FILE"

# Weighted extraction: prioritize USER messages over tool noise
raw_size=$(wc -c < "$RAW_FILE" 2>/dev/null || echo 0)
if [ "$raw_size" -le "$CONDENSED_MAX_BYTES" ]; then
  # Fits within budget — keep everything in chronological order
  mv "$RAW_FILE" "$CONDENSED_FILE"
else
  USER_BUDGET=$(( CONDENSED_MAX_BYTES / 5 ))
  OTHER_BUDGET=$(( CONDENSED_MAX_BYTES * 4 / 5 ))
  {
    # All user messages (capped at 20% budget), preserving chronological order
    (grep '^USER: ' "$RAW_FILE" || true) | head -c "$USER_BUDGET"
    echo ""
    echo "--- [above: user messages; below: recent tool calls and responses] ---"
    echo ""
    # Recent non-user content (last 80% of budget)
    (grep -v '^USER: ' "$RAW_FILE" || true) | tail -c "$OTHER_BUDGET"
  } > "$CONDENSED_FILE"
  rm -f "$RAW_FILE"
fi

condensed_size=$(wc -c < "$CONDENSED_FILE" 2>/dev/null || echo 0)
log "condensed file: ${CONDENSED_FILE} (${condensed_size} bytes)"

if [ ! -s "$CONDENSED_FILE" ]; then
  log "SKIP: condensed transcript is empty (jq produced no output)"
  exit 0
fi

# --- Trigger analysis via exit 2 injection ---
# Persistence to disk happens in the SubagentStop hook (hooks/persist-analysis.sh)
# so the subagent doesn't need to call Write, keeping UI output clean.

log "TRIGGER: injecting session-analyzer subagent request (exit 2)"

# Sanitize paths: strip newlines to prevent prompt injection
safe_condensed="${CONDENSED_FILE//$'\n'/}"
safe_cwd="${hook_cwd//$'\n'/}"

cat >&2 <<EOF
Please spawn a session-analyzer agent to critically analyze this session.

Use the Agent tool with:
- subagent_type: "session-analyzer"
- model: "sonnet"
- prompt: "Read and analyze the condensed session transcript at '${safe_condensed}'. The working directory is '${safe_cwd}'. Provide your critical analysis."

Present the analysis to the user, then stop.
EOF

# Advance the cursor to the last uuid of the delta we just analyzed
lastuuid_out=$(node "$CURSOR_SLICE" last-uuid "$DELTA_FILE" 2>>"$LOG_FILE" || true)
if [ -n "$lastuuid_out" ]; then
  # Parse key=value lines with awk (not eval) and validate types before use
  new_uuid=$(printf '%s\n' "$lastuuid_out" | awk -F= '$1=="UUID" {print $2; exit}')
  rel_line=$(printf '%s\n' "$lastuuid_out" | awk -F= '$1=="REL_LINE" {print $2; exit}')
  if [[ "$new_uuid" =~ ^[A-Za-z0-9_-]+$ ]] && [[ "$rel_line" =~ ^[0-9]+$ ]]; then
    ABS_LINE=$(( DELTA_START - 1 + rel_line ))
    printf '%s\n%s\n%s\n' "$new_uuid" "$ABS_LINE" "$transcript_path" > "$CURSOR_FILE"
    log "CURSOR: updated to uuid=${new_uuid} line=${ABS_LINE}"
  else
    log "CURSOR: invalid last-uuid output, cursor unchanged"
  fi
fi

exit 2
