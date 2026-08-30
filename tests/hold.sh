#!/usr/bin/env bash
# The UserPromptSubmit input-hold hook.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_WATCHDOG_TMP="$TMPROOT/tmp"
export CLAUDE_WATCHDOG_LOG="$TMPROOT/log"
SESSIONS="$CLAUDE_WATCHDOG_TMP/sessions"
mkdir -p "$SESSIONS"

mk_payload() { jq -n --arg sid "$1" '{session_id:$sid, hook_event_name:"UserPromptSubmit", cwd:"/tmp"}'; }
# 400s in the past: safely beyond the 240s default TTL
old_iso() { iso_ago 400; }

# --- Test 1: option off -> allow even with a fresh sentinel present ---
sid1="hold-t1-$$"
printf '%s\n' "$(iso_now)" > "$SESSIONS/pending-${sid1}"
run_hold "$(mk_payload "$sid1")"
[ -z "$HOLD_OUT" ] || fail "default-off" "expected empty stdout, got '$HOLD_OUT'"
[ -f "$SESSIONS/pending-${sid1}" ] || fail "default-off-sentinel" "sentinel must be left untouched"
pass "default-off"

# --- Test 2: option on, no sentinel -> allow ---
sid2="hold-t2-$$"
run_hold "$(mk_payload "$sid2")" CLAUDE_WATCHDOG_HOLD_INPUT=1
[ -z "$HOLD_OUT" ] || fail "no-sentinel" "expected empty stdout, got '$HOLD_OUT'"
pass "no-sentinel-allows"

# --- Test 3: fresh sentinel -> block and mark nudged ---
sid3="hold-t3-$$"
printf '%s\n' "$(iso_now)" > "$SESSIONS/pending-${sid3}"
run_hold "$(mk_payload "$sid3")" CLAUDE_WATCHDOG_HOLD_INPUT=1
echo "$HOLD_OUT" | grep -q '"decision":"block"' || fail "fresh-blocks" "expected decision:block, got '$HOLD_OUT'"
sed -n '2p' "$SESSIONS/pending-${sid3}" | grep -qx 'nudged' || fail "fresh-nudged" "sentinel not marked nudged"
grep -q "HOLD: blocked prompt" "$CLAUDE_WATCHDOG_LOG" || fail "fresh-log" "no HOLD log"
pass "fresh-sentinel-blocks"

# --- Test 4: nudged sentinel -> next prompt overrides and releases ---
run_hold "$(mk_payload "$sid3")" CLAUDE_WATCHDOG_HOLD_INPUT=1
[ -z "$HOLD_OUT" ] || fail "override" "expected empty stdout, got '$HOLD_OUT'"
[ ! -f "$SESSIONS/pending-${sid3}" ] || fail "override-cleared" "sentinel should be deleted"
grep -q "RELEASE: user override" "$CLAUDE_WATCHDOG_LOG" || fail "override-log" "no override log"
pass "override-releases"

# --- Test 5: expired sentinel -> TTL releases ---
sid5="hold-t5-$$"
printf '%s\n' "$(old_iso)" > "$SESSIONS/pending-${sid5}"
run_hold "$(mk_payload "$sid5")" CLAUDE_WATCHDOG_HOLD_INPUT=1
[ -z "$HOLD_OUT" ] || fail "ttl" "expected empty stdout, got '$HOLD_OUT'"
[ ! -f "$SESSIONS/pending-${sid5}" ] || fail "ttl-cleared" "sentinel should be deleted"
grep -q "RELEASE: hold expired" "$CLAUDE_WATCHDOG_LOG" || fail "ttl-log" "no expiry log"
pass "ttl-expiry-releases"

# --- Test 6: fail-open on garbage stdin ---
run_hold "not json" CLAUDE_WATCHDOG_HOLD_INPUT=1
[ "$HOLD_RC" -eq 0 ] || fail "fail-open-exit" "expected exit 0, got $HOLD_RC"
[ -z "$HOLD_OUT" ] || fail "fail-open-stdout" "expected empty stdout, got '$HOLD_OUT'"
pass "fail-open"

# --- Test 7: invalid session_id -> allow, no shell injection surface ---
run_hold "$(jq -n '{session_id:"evil; rm -rf /"}')" CLAUDE_WATCHDOG_HOLD_INPUT=1
[ "$HOLD_RC" -eq 0 ] || fail "bad-sid-exit" "expected exit 0, got $HOLD_RC"
[ -z "$HOLD_OUT" ] || fail "bad-sid-stdout" "expected empty stdout, got '$HOLD_OUT'"
pass "invalid-session-id"

echo "--- all hold tests passed ---"
