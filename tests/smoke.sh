#!/usr/bin/env bash
# Smoke-test the Stop hook with a synthetic end_turn event.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
session_id="smoketest-$$"
hold_sid="smokehold-$$"
# Hermetic cwd: the hook resolves project-local storage from the event's `cwd`,
# so pointing it at a mktemp dir keeps the run out of the real repo.
hook_cwd="$TMPROOT/project"
mkdir -p "$hook_cwd"
sessions="$hook_cwd/.claude/tmp/claude-watchdog/sessions"
# The echo sentinel always lives in the global sessions dir (it must resolve
# before the local/global decision), so clean it from there regardless.
trap 'rm -rf "$TMPROOT"; rm -f "$HOME/.claude/tmp/claude-watchdog/sessions/echo-${session_id}" "$HOME/.claude/logs/claude-watchdog-analyses/${session_id}-"*.md "$HOME/.claude/logs/claude-watchdog-analyses/${hold_sid}-"*.md 2>/dev/null || true' EXIT

transcript="$TMPROOT/transcript.jsonl"
for i in $(seq 1 5); do
  {
    printf '{"type":"user","message":{"content":"do task %s"}}\n' "$i"
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on task %s"},{"type":"tool_use","id":"toolu_%s","name":"Edit","input":{"file_path":"/tmp/test","old_string":"a","new_string":"b"}}]}}\n' "$i" "$i"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_%s","content":"file contents here"}]}}\n' "$i"
  } >> "$transcript"
done

payload=$(stop_payload "$session_id" "$transcript" "$hook_cwd")
run_stop "$payload" CLAUDE_WATCHDOG_LOG="$TMPROOT/log" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
echo "hook exit: $STOP_RC (expected 0)"
echo "--- stdout ---"
echo "$STOP_OUT"
echo "--- log ---"
cat "$TMPROOT/log"
echo "--- condensed ---"
cat "$sessions/condensed-${session_id}.txt" 2>/dev/null || echo "(not found)"

# Default protocol: analysis is signalled via a JSON `decision:block` on stdout with exit 0.
[ "$STOP_RC" -eq 0 ] || fail "smoke-exit" "expected exit 0, got $STOP_RC"
echo "$STOP_OUT" | grep -q '"decision":"block"' || fail "smoke-decision" "expected decision:block on stdout"
echo "$STOP_OUT" | grep -q 'This is the first analysis for this session.' || fail "smoke-first-analysis" "expected first-analysis marker in prompt"
echo "$STOP_OUT" | grep -q 'Files touched this slice: /tmp/test' || fail "smoke-touched-files" "expected touched files in prompt"
# Input-hold is opt-in: the default run above must not write a pending sentinel.
[ ! -f "$HOME/.claude/tmp/claude-watchdog/sessions/pending-${session_id}" ] || fail "smoke-pending" "pending sentinel written without opt-in"

# With the option on, a trigger writes a timestamped pending sentinel. Use a
# hermetic CLAUDE_WATCHDOG_TMP so the sentinel lands in the tmpdir.
wtmp="$TMPROOT/wtmp"
payload_hold=$(stop_payload "$hold_sid" "$transcript" "$hook_cwd")
run_stop "$payload_hold" CLAUDE_WATCHDOG_LOG="$TMPROOT/log" CLAUDE_WATCHDOG_TMP="$wtmp" \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_HOLD_INPUT=1
echo "$STOP_OUT" | grep -q '"decision":"block"' || fail "smoke-hold-trigger" "hold-enabled run should still trigger"
pending="$wtmp/sessions/pending-${hold_sid}"
[ -f "$pending" ] || fail "smoke-hold-pending" "pending sentinel missing with CLAUDE_WATCHDOG_HOLD_INPUT=1"
head -1 "$pending" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' \
  || fail "smoke-hold-timestamp" "pending sentinel timestamp not an ISO 8601 instant"
echo "pending sentinel OK: $pending"
