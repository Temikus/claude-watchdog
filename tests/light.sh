#!/usr/bin/env bash
# Light mode: the Stop hook's handoff to the light-mode hooks module.
#
# The module itself is tested by `just test-light` (claude plugin test). Here
# the module is played by files: an alive marker it would write each turn, and
# the consumedAt, doneAt or failedAt it would add to a request.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

LHOME="$TMPROOT/home"
LTMP="$TMPROOT/wtmp"
LANALYSES="$TMPROOT/analyses"
LLOG="$TMPROOT/log"
LDIR="$TMPROOT/light"
LSESSIONS="$LTMP/sessions"
mkdir -p "$LHOME" "$LTMP" "$LANALYSES"

PROJ="$TMPROOT/project"
mkdir -p "$PROJ/.git"

TRANSCRIPT="$TMPROOT/t.jsonl"
mk_transcript "$TRANSCRIPT" 1 3 LM

SIDCOUNT="$TMPROOT/sid-counter"
echo 0 > "$SIDCOUNT"
new_sid() {
  local n
  n=$(( $(cat "$SIDCOUNT") + 1 ))
  echo "$n" > "$SIDCOUNT"
  echo "light-$$-$n"
}

# light_run <sid> [ENV=VAL ...] - a Stop that passes every gate.
light_run() {
  local sid="$1"; shift
  : > "$LLOG"
  run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$PROJ" "")" \
    HOME="$LHOME" \
    CLAUDE_WATCHDOG_LOG="$LLOG" \
    CLAUDE_WATCHDOG_TMP="$LTMP" \
    CLAUDE_WATCHDOG_ANALYSES_DIR="$LANALYSES" \
    CLAUDE_WATCHDOG_LIGHT_DIR="$LDIR" \
    CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
    CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
    CLAUDE_WATCHDOG_MIN_TOOL_USES=3 \
    ${1+"$@"}
}

alive() {
  mkdir -p "$LDIR"
  printf '{"ts":"%s"}\n' "$(iso_now)" > "$LDIR/alive-$1"
}

assert_outcome() {
  local label="$1" want="$2" got
  got=$(outcome "$STOP_OUT" "$STOP_RC")
  [ "$got" = "$want" ] || { cat "$LLOG" >&2; fail "$label" "expected $want, got $got"; }
}

assert_log() {
  grep -q "$2" "$LLOG" || { cat "$LLOG" >&2; fail "$1" "log missing /$2/"; }
}

# --- off -------------------------------------------------------------------

sid=$(new_sid)
alive "$sid"
light_run "$sid"
assert_outcome "off-default" BLOCK
[ ! -e "$LDIR/light-$sid.json" ] || fail "off-default" "request written while light mode is off"
pass "light-off-by-default-keeps-classic-path"

sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=sideways
assert_outcome "invalid-value" BLOCK
assert_log "invalid-value" "CONFIG: LIGHT_MODE='sideways' is not one of off, on, both, using off"
pass "light-invalid-value-falls-back-to-off"

# --- on --------------------------------------------------------------------

sid=$(new_sid)
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-no-marker" BLOCK
assert_log "on-no-marker" "LIGHT: no live module marker for this session, using the analyzer"
[ ! -e "$LDIR/light-$sid.json" ] || fail "on-no-marker" "request written with no module to take it"
pass "light-on-without-module-falls-back-to-analyzer"

sid=$(new_sid)
alive "$sid"
set_mtime "$LDIR/alive-$sid" 25200
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-stale-marker" BLOCK
assert_log "on-stale-marker" "LIGHT: no live module marker for this session, using the analyzer"
pass "light-on-stale-marker-falls-back-to-analyzer"

sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_HOLD_INPUT=1
assert_outcome "on-handoff" SKIP
assert_log "on-handoff" "LIGHT: handed to the module"
assert_log "on-handoff" "TRIGGER: handing the review to the light-mode module"
if grep -q "injecting session-analyzer\|brief file" "$LLOG"; then cat "$LLOG" >&2; fail "on-handoff" "log claims an analyzer run that did not happen"; fi
[ ! -e "$LSESSIONS/brief-$sid.md" ] || fail "on-handoff" "analyzer brief written with no analyzer run"
req="$LDIR/light-$sid.json"
[ -f "$req" ] || fail "on-handoff" "no request file"
[ ! -e "$LSESSIONS/echo-$sid" ] || fail "on-handoff" "echo sentinel written with no continuation coming"
[ ! -e "$LSESSIONS/pending-$sid" ] || fail "on-handoff" "hold sentinel written with nothing to wait for"
[ "$(sed -n '1p' "$LSESSIONS/cursor-$sid.txt")" = "a-LM-3" ] || fail "on-handoff" "cursor did not advance"
pass "light-on-hands-off-without-brief-echo-or-hold"

jq -e --arg sid "$sid" --arg proj "$PROJ" --arg an "$LANALYSES" '
  .version == 1 and .sessionId == $sid and .projectRoot == $proj
  and .analysesDir == $an and .isContinuation == false
  and (.touchedFiles | type) == "array" and (.externalFiles | type) == "array"
  and has("commitRange") and has("attribution")
  and .prevCursor == null and .handoff == "module"
  and (.createdAt | type) == "string" and (has("consumedAt") | not)
' "$req" > /dev/null || { cat "$req" >&2; fail "request-shape" "unexpected request JSON"; }
pass "light-request-carries-the-slice"

# --- a review the module never delivered ---------------------------------------

# mark <sid> <jq filter> - what the module would write onto the request.
mark() {
  jq -c "$2" "$LDIR/light-$1.json" > "$LDIR/light-$1.json.new" && mv "$LDIR/light-$1.json.new" "$LDIR/light-$1.json"
}

# The fork failed: the next Stop puts the cursor back, so the analyzer reviews
# the slice the handoff had already moved past.
sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "failed-handoff" SKIP
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z", failedAt: "2026-01-01T00:00:02Z", failure: "api-error"}'
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "failed-recovered" BLOCK
assert_log "failed-recovered" "LIGHT: previous review failed (api-error), the analyzer re-reviews its slice"
assert_log "failed-recovered" "tool_use count (delta): 3 "
[ ! -e "$LDIR/light-$sid.json" ] || fail "failed-recovered" "failed request left behind, it would recover twice"
pass "light-failed-review-is-re-reviewed-by-the-analyzer"

# Same slice, but the cursor existed before the handoff: it is restored, and the
# cooldown that the handoff started does not hold the analyzer back.
sid=$(new_sid)
alive "$sid"
printf 'a-LM-1\n2\n%s\n\n' "$TRANSCRIPT" > "$LSESSIONS/cursor-$sid.txt"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_MIN_TOOL_USES=1
assert_outcome "restore-handoff" SKIP
jq -e '.prevCursor | startswith("a-LM-1\n")' "$LDIR/light-$sid.json" > /dev/null || fail "restore-handoff" "request does not carry the previous cursor"
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z", failedAt: "2026-01-01T00:00:02Z", failure: "nothing-to-fork"}'
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_MIN_TOOL_USES=1 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=600
assert_outcome "restore-recovered" BLOCK
assert_log "restore-recovered" "CURSOR: uuid=a-LM-1 "
pass "light-failed-review-restores-the-cursor-past-the-cooldown"

# A recovery whose Stop then skips leaves a cursor the 7-day sweep will not take.
sid=$(new_sid)
alive "$sid"
printf 'a-LM-1\n2\n%s\n\n' "$TRANSCRIPT" > "$LSESSIONS/cursor-$sid.txt"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_MIN_TOOL_USES=1
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z", failedAt: "2026-01-01T00:00:02Z", failure: "api-error"}'
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_MIN_TOOL_USES=99
assert_outcome "restore-then-skip" SKIP
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on CLAUDE_WATCHDOG_MIN_TOOL_USES=99
[ "$(sed -n '1p' "$LSESSIONS/cursor-$sid.txt" 2>/dev/null)" = "a-LM-1" ] || fail "restore-then-skip" "restored cursor was swept"
pass "light-restored-cursor-survives-the-sweep"

# Picked up but never finished (the session died mid-fork).
sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z"}'
set_mtime "$LDIR/light-$sid.json" 300
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "unfinished" BLOCK
assert_log "unfinished" "LIGHT: previous review never finished, the analyzer re-reviews its slice"
pass "light-unfinished-review-is-re-reviewed-by-the-analyzer"

# Never picked up at all, and no cursor recorded to go back to.
sid=$(new_sid)
alive "$sid"
printf '{"version":1}\n' > "$LDIR/light-$sid.json"
set_mtime "$LDIR/light-$sid.json" 300
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-unconsumed" BLOCK
assert_log "on-unconsumed" "LIGHT: previous review was never picked up, using the analyzer"
pass "light-on-unconsumed-request-falls-back-to-analyzer"

# A request still in flight is left alone.
sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z"}'
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "in-flight" SKIP
if grep -q "LIGHT: previous review" "$LLOG"; then cat "$LLOG" >&2; fail "in-flight" "recovered a review that is still running"; fi
pass "light-in-flight-request-is-not-recovered"

# A finished review does not block the next handoff.
sid=$(new_sid)
alive "$sid"
mkdir -p "$LDIR"
printf '{"version":1,"consumedAt":"%s","doneAt":"%s"}\n' "$(iso_now)" "$(iso_now)" > "$LDIR/light-$sid.json"
set_mtime "$LDIR/light-$sid.json" 300
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-after-done" SKIP
jq -e 'has("consumedAt") | not' "$LDIR/light-$sid.json" > /dev/null || fail "on-after-done" "request not replaced"
pass "light-on-finished-request-allows-next-handoff"

# The plugin option works like the env override.
sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_PLUGIN_OPTION_LIGHT_MODE=on
assert_outcome "plugin-option" SKIP
pass "light-plugin-option-enables-handoff"

# --- both ------------------------------------------------------------------

sid=$(new_sid)
alive "$sid"
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=both
assert_outcome "both" BLOCK
[ -f "$LDIR/light-$sid.json" ] || fail "both" "no request file"
assert_log "both" "LIGHT: handed to the module, analyzer runs too"
pass "light-both-runs-module-and-analyzer"

# In both, the analyzer already reviewed the slice: a failed fork changes nothing.
mark "$sid" '. + {consumedAt: "2026-01-01T00:00:00Z", failedAt: "2026-01-01T00:00:02Z", failure: "api-error"}'
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=both
if grep -q "LIGHT: previous review" "$LLOG"; then cat "$LLOG" >&2; fail "both-failed" "re-reviewed a slice the analyzer already covered"; fi
pass "light-both-failed-fork-is-not-re-reviewed"

echo "--- all light-mode handoff tests passed ---"
