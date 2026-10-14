#!/usr/bin/env bash
# Light mode: the Stop hook's handoff to the light-mode hooks module.
#
# The module itself is tested by `just test-light` (claude plugin test). Here
# the module is played by files: an alive marker it would write each turn, and
# the consumedAt it would add to a request it picked up.
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
  and has("commitRange") and has("attribution") and has("previousAnalysis")
  and (.createdAt | type) == "string" and (has("consumedAt") | not)
' "$req" > /dev/null || { cat "$req" >&2; fail "request-shape" "unexpected request JSON"; }
pass "light-request-carries-the-slice"

# A Stop that finds an old request still unconsumed: the module failed.
sid=$(new_sid)
alive "$sid"
printf '{"version":1}\n' > "$LDIR/light-$sid.json"
set_mtime "$LDIR/light-$sid.json" 300
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-unconsumed" BLOCK
assert_log "on-unconsumed" "LIGHT: previous request was never consumed, using the analyzer"
pass "light-on-unconsumed-request-falls-back-to-analyzer"

# A consumed request does not block the next handoff.
sid=$(new_sid)
alive "$sid"
mkdir -p "$LDIR"
printf '{"version":1,"consumedAt":"%s"}\n' "$(iso_now)" > "$LDIR/light-$sid.json"
set_mtime "$LDIR/light-$sid.json" 300
light_run "$sid" CLAUDE_WATCHDOG_LIGHT_MODE=on
assert_outcome "on-after-consumed" SKIP
jq -e 'has("consumedAt") | not' "$LDIR/light-$sid.json" > /dev/null || fail "on-after-consumed" "request not replaced"
pass "light-on-consumed-request-allows-next-handoff"

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

echo "--- all light-mode handoff tests passed ---"
