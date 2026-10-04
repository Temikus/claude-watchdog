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

# --- Test 1b: save path is echoed to stdout so the user sees where it landed ---
echo "$PERSIST_OUT" | grep -q "Analysis saved to: $out" || fail "save-path-echoed" "stdout missing save path"
pass "save-path-echoed"

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

# --- Test 7: plugin-scoped agent_type is accepted ---
sid7="persist-t7-$$"
run_persist "$(jq -n --arg sid "$sid7" --arg msg $'### Goals\nScoped analysis.' \
  '{session_id:$sid, agent_type:"claude-watchdog:session-analyzer", last_assistant_message:$msg}')"
out=$(find "$CLAUDE_WATCHDOG_ANALYSES_DIR" -maxdepth 1 -name "${sid7}-*.md" -print -quit 2>/dev/null)
[ -n "$out" ] || fail "scoped-agent-type" "no analysis file written for scoped agent_type"
pass "scoped-agent-type"

# --- Test 8: non-matching agent_type is skipped and logged with the observed value ---
sid8="persist-t8-$$"
run_persist "$(jq -n --arg sid "$sid8" --arg msg "ignored" \
  '{session_id:$sid, agent_type:"general-purpose", last_assistant_message:$msg}')"
if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid8}-*.md >/dev/null 2>&1; then
  fail "non-matching-agent-type" "wrote file for non-matching agent_type"
fi
grep -q "SKIP: agent_type 'general-purpose' does not match session-analyzer" "$CLAUDE_WATCHDOG_LOG" \
  || fail "non-matching-agent-type-log" "no skip log for non-matching agent_type"
pass "non-matching-agent-type-logged"

# --- Test 9: the analyzer's handback acknowledgement is not an analysis ---
# The analyzer stops twice: once with the report, once with a short ack after
# handing back. Persisting the ack shadowed the real analysis, because
# latestAnalysis() picks the newest file by name.
sid9="persist-t9-$$"
touch "$SESSIONS/pending-${sid9}"
run_persist "$(jq -n --arg sid "$sid9" --arg msg "Report delivered." \
  '{session_id:$sid, agent_type:"claude-watchdog:session-analyzer", last_assistant_message:$msg}')"
if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid9}-*.md >/dev/null 2>&1; then
  fail "handback-ack" "wrote a file for the handback acknowledgement"
fi
grep -q "SKIP: message is not an analysis" "$CLAUDE_WATCHDOG_LOG" \
  || fail "handback-ack-log" "no skip log for the handback acknowledgement"
# The hold must still release: the analyzer really has finished.
[ ! -f "$SESSIONS/pending-${sid9}" ] || fail "handback-ack" "pending sentinel not removed"
pass "handback-ack-not-persisted"

# Subagent transcript lines in the shape Claude Code writes them.
text_line() {
  jq -nc --arg t "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}'
}
handback_line() {
  jq -nc --arg m "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"toolu_1", name:"SubagentHandback", input:{message:$m}}]}}'
}
stop_payload() {
  jq -n --arg sid "$1" --arg msg "$2" --arg tp "$3" \
    '{session_id:$sid, agent_id:"a1", agent_type:"claude-watchdog:session-analyzer", last_assistant_message:$msg, agent_transcript_path:$tp}'
}
session_files() { find "$CLAUDE_WATCHDOG_ANALYSES_DIR" -maxdepth 1 -name "$1-*.md"; }

# --- Test 10: a report sent only via SubagentHandback is read from the agent transcript ---
# The last assistant turn is a tool call, so last_assistant_message arrives empty.
sid10="persist-t10-$$"
tp10="$TMPROOT/agent-t10.jsonl"
handback_line $'### Goals\nHanded back directly.' > "$tp10"
run_persist "$(stop_payload "$sid10" "" "$tp10")"
out=$(session_files "$sid10")
[ -n "$out" ] || fail "handback-only" "no analysis file written"
grep -q "Handed back directly." "$out" || fail "handback-only" "file missing handback content"
echo "$PERSIST_OUT" | grep -q "Analysis saved to: $out" || fail "handback-only" "stdout missing save path"
pass "handback-only-persisted"

# --- Test 11: text turn then a different handback keeps one file, holding the handback ---
# The handback is what the caller received; the earlier text turn is a draft.
sid11="persist-t11-$$"
tp11="$TMPROOT/agent-t11.jsonl"
text_line $'### Goals\nDraft report.' > "$tp11"
run_persist "$(stop_payload "$sid11" $'### Goals\nDraft report.' "$tp11")"
handback_line $'### Goals\nFinal report.' >> "$tp11"
run_persist "$(stop_payload "$sid11" "" "$tp11")"
[ "$(session_files "$sid11" | wc -l)" -eq 1 ] || fail "text-then-handback" "expected exactly one file"
out=$(session_files "$sid11")
grep -q "Final report." "$out" || fail "text-then-handback" "file does not hold the handback"
pass "text-then-handback-replaces-draft"

# --- Test 12: text turn then an identical handback does not duplicate ---
sid12="persist-t12-$$"
tp12="$TMPROOT/agent-t12.jsonl"
text_line $'### Goals\nSame report.' > "$tp12"
run_persist "$(stop_payload "$sid12" $'### Goals\nSame report.' "$tp12")"
handback_line $'### Goals\nSame report.' >> "$tp12"
run_persist "$(stop_payload "$sid12" "" "$tp12")"
[ "$(session_files "$sid12" | wc -l)" -eq 1 ] || fail "identical-handback" "expected exactly one file"
pass "identical-handback-not-duplicated"

# --- Test 13: empty message and no handback in the transcript still skips ---
sid13="persist-t13-$$"
tp13="$TMPROOT/agent-t13.jsonl"
text_line "Working on it." > "$tp13"
run_persist "$(stop_payload "$sid13" "" "$tp13")"
[ -z "$(session_files "$sid13")" ] || fail "no-handback" "wrote a file without a report"
grep -q "empty last_assistant_message for session=$sid13" "$CLAUDE_WATCHDOG_LOG" \
  || fail "no-handback" "no empty-message skip log"
pass "empty-without-handback-skips"

echo "--- all persist tests passed ---"
