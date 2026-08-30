#!/usr/bin/env bash
# The SubagentStop persistence hook.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses"
export CLAUDE_WATCHDOG_LOG="$TMPROOT/log"
export CLAUDE_WATCHDOG_TMP="$TMPROOT/tmp"
SESSIONS="$CLAUDE_WATCHDOG_TMP/sessions"
mkdir -p "$SESSIONS"

# --- Test 1: session-analyzer payload writes a file ---
sid1="persist-t1-$$"
run_persist "$(jq -n --arg sid "$sid1" --arg msg $'### Goals\nSome analysis.' \
  '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')"
# shellcheck disable=SC2012  # filenames are <session_id>-<timestamp>.md, no surprises
out=$(ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid1}-*.md 2>/dev/null | head -1)
[ -n "$out" ] || fail "analyzer-writes" "no analysis file written"
grep -q "### Goals" "$out" || fail "analyzer-content" "file missing content"
pass "analyzer-writes"

# --- Test 2: other subagent types are ignored ---
sid2="persist-t2-$$"
run_persist "$(jq -n --arg sid "$sid2" --arg msg "ignored" \
  '{session_id:$sid, agent_type:"general-purpose", last_assistant_message:$msg}')"
if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid2}-*.md >/dev/null 2>&1; then
  fail "other-agent-ignored" "wrote file for non-analyzer subagent"
fi
pass "other-agent-ignored"

# --- Test 3: empty message skips without error ---
sid3="persist-t3-$$"
run_persist "$(jq -n --arg sid "$sid3" \
  '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:""}')"
if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid3}-*.md >/dev/null 2>&1; then
  fail "empty-message" "wrote file for empty message"
fi
grep -q "empty last_assistant_message" "$CLAUDE_WATCHDOG_LOG" || fail "empty-log" "no empty log"
pass "empty-message"

# --- Test 4: invalid session_id is rejected ---
run_persist "$(jq -n --arg msg "x" \
  '{session_id:"evil; rm -rf /", agent_type:"session-analyzer", last_assistant_message:$msg}')"
grep -q "invalid session_id" "$CLAUDE_WATCHDOG_LOG" || fail "bad-sid" "no invalid-sid log"
pass "invalid-session-id"

# --- Test 5: pending sentinel cleared on analyzer completion ---
sid5="persist-t5-$$"
touch "$SESSIONS/pending-${sid5}"
run_persist "$(jq -n --arg sid "$sid5" --arg msg "analysis text" \
  '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')"
[ ! -f "$SESSIONS/pending-${sid5}" ] || fail "pending-cleared" "pending sentinel not removed"
pass "pending-cleared"

# --- Test 6: pending sentinel cleared even when the message is empty ---
sid6="persist-t6-$$"
touch "$SESSIONS/pending-${sid6}"
run_persist "$(jq -n --arg sid "$sid6" \
  '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:""}')"
[ ! -f "$SESSIONS/pending-${sid6}" ] || fail "pending-cleared-empty" "pending sentinel not removed on empty message"
pass "pending-cleared-empty-message"

echo "--- all persist tests passed ---"
