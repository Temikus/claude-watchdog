#!/usr/bin/env bash
# Byte-exact golden comparison for the hook outputs a port must reproduce.
#
#   bash tests/golden.sh                 # compare (diff -u on mismatch)
#   GOLDEN_REGEN=1 bash tests/golden.sh  # rewrite every golden
#
# Runs through HOOK_STOP / HOOK_CONDENSE like the rest of the suite, so a port
# is checked against the same files. See tests/golden/README.md.

# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOLDEN_DIR="tests/golden"
REGEN="${GOLDEN_REGEN:-0}"
FAILED=0

# --- the one normalisation ------------------------------------------------
#
# Both the generator and the comparator pipe through this, so an unstable value
# can never reach a golden from one side only. Everything it rewrites is a value
# that differs per machine or per run; every remaining byte is contract.
#
# Reads stdin, writes stdout. Depends on NORM_TMP / NORM_SESSION being exported.
golden_normalise() {
  local tmp="${NORM_TMP:-}" tmp_real="${NORM_TMP_REAL:-}" sid="${NORM_SESSION:-}"
  sed \
    -e "s|${tmp_real:-@@none@@}|<TMP>|g" \
    -e "s|${tmp:-@@none@@}|<TMP>|g" \
    -e "s|${sid:-@@none@@}|<SESSION>|g" \
    -e 's|[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\(\.[0-9]\{3\}\)\{0,1\}Z|<TIMESTAMP>|g' \
    -e 's|(\([0-9]\{1,\}\)s < \([0-9]\{1,\}\)s since last trigger)|(<N>s < \2s since last trigger)|g' \
    -e "s|$(hostname -s 2>/dev/null || echo @@none@@)|<HOST>|g"
}

# check <golden-name>  - actual on stdin
check() {
  local name="$1" path="$GOLDEN_DIR/$1" actual
  actual="$(golden_normalise)"
  if [ "$REGEN" = "1" ]; then
    printf '%s\n' "$actual" > "$path"
    echo "REGEN: $name"
    return 0
  fi
  if [ ! -f "$path" ]; then
    echo "FAIL: $name - golden missing (run 'just golden-regen')" >&2
    FAILED=1
    return 0
  fi
  if diff -u "$path" <(printf '%s\n' "$actual") > /tmp/golden-diff.$$ 2>&1; then
    pass "$name"
  else
    echo "FAIL: $name - output differs from golden" >&2
    sed -e "s|^--- $path|--- golden|" -e 's|^+++ /dev/fd.*|+++ actual|' /tmp/golden-diff.$$ >&2
    FAILED=1
  fi
  rm -f /tmp/golden-diff.$$
}

# --- condense goldens ------------------------------------------------------
#
# Budget choice, verified against hooks/condense.mjs against this fixture
# (extract output: 5032 bytes, of which 902 bytes of USER lines):
#
#   8192 - pass-through. 5032 <= 8192, so condense() returns rawContent
#          untouched: no [TRUNCATED] notice, no splits. Pins the boundary
#          where truncation must NOT happen.
#   4096 - full truncation path. userPart budget = floor(4096/5) = 819 < 902,
#          so clampUserLines elides; head budget = floor((819-38)*0.4) = 312
#          keeps three USER lines, the tail keeps six, and otherPart takes the
#          last floor(4096*4/5) = 3276 bytes of non-USER lines.
#   2048 - same branches at a tighter budget: userPart = 409, head = 148 keeps
#          a single USER line, so the 40/60 asymmetry is visible rather than
#          incidental.
#
# The section-2 note asked for 4096 and 8192 as the two truncation goldens.
# 8192 cannot truncate this fixture, so 2048 is the second truncation golden
# and 8192 is kept as the pass-through case.
NORM_TMP="" NORM_TMP_REAL="" NORM_SESSION="" \
  run_condense extract "$FIXTURE" | check midturn.extract.txt
for budget in 8192 4096 2048; do
  NORM_TMP="" NORM_TMP_REAL="" NORM_SESSION="" \
    run_condense condense "$FIXTURE" "$budget" | check "midturn.condense-${budget}.txt"
done

# --- labels.txt vs the goldens --------------------------------------------
#
# The second half of the section-1 label check: tests/agent-prompt.sh asserts
# every label in tests/labels.txt is documented in the analyzer prompt, and this
# asserts every one of them is actually produced by the condenser. Together they
# stop the list going stale in either direction.
label_rc=0
while IFS= read -r label; do
  case "$label" in ''|'#'*) continue ;; esac
  label="${label%"${label##*[![:space:]]}"}"
  if grep -qF -- "$label" "$GOLDEN_DIR"/midturn.*.txt; then
    pass "label in goldens: $label"
  else
    echo "FAIL: label '$label' from tests/labels.txt appears in no golden" >&2
    label_rc=1
  fi
done < tests/labels.txt
[ "$label_rc" -eq 0 ] || FAILED=1

# --- Stop hook goldens -----------------------------------------------------

SID="golden-session-0000"
TMPROOT="$(mktemp -d)"
TMPREAL="$(cd "$TMPROOT" && pwd -P)"
trap 'rm -rf "$TMPROOT"' EXIT
export NORM_TMP="$TMPROOT" NORM_TMP_REAL="$TMPREAL" NORM_SESSION="$SID"

PROJ="$TMPROOT/proj"
FAKE_HOME="$TMPROOT/home"
mkdir -p "$PROJ/.git" "$FAKE_HOME/.claude/rules"
printf 'Project rules for the golden fixture.\n' > "$PROJ/CLAUDE.md"
printf 'Global rule A.\n' > "$FAKE_HOME/.claude/rules/a-rules.md"

# Common environment. HOME is redirected so the runner's real CLAUDE.md and
# rules directory cannot leak into the prompt golden. Sets BASE_ENV rather than
# printing, so this stays on bash 3.2 (macOS) - no mapfile.
BASE_ENV=()
set_base_env() {
  BASE_ENV=(
    "HOME=$FAKE_HOME"
    "CLAUDE_WATCHDOG_TMP=$TMPROOT/wd"
    "CLAUDE_WATCHDOG_ANALYSES_DIR=$TMPROOT/analyses"
    "CLAUDE_WATCHDOG_LOG=$1"
  )
}

SESS_DIR="$PROJ/.claude/tmp/claude-watchdog/sessions"
GLOBAL_SESS="$TMPROOT/wd/sessions"

# reset_state - wipe everything a previous case left behind, so each case runs
# against the same starting conditions regardless of order.
reset_state() {
  rm -rf "$SESS_DIR" "$GLOBAL_SESS" "$TMPROOT/analyses" "$PROJ/.claude-watchdog-skip"
}

# skip_case <golden-suffix> <session-id> <transcript> <payload-extra> [ENV=VAL ...]
# Runs the Stop hook and pins the SKIP line(s) it logged.
skip_case() {
  local suffix="$1" sid="$2" tp="$3" extra="$4"; shift 4
  local logf="$TMPROOT/log-$suffix.txt"
  : > "$logf"
  set_base_env "$logf"
  run_stop "$(stop_payload "$sid" "$tp" "$PROJ" "$extra")" "${BASE_ENV[@]}" "$@"
  [ "$STOP_RC" -eq 0 ] || fail "golden:$suffix" "expected exit 0, got $STOP_RC"
  grep 'SKIP:' "$logf" | check "stop.log.${suffix}.txt"
}

# A transcript that clears every gate: 12 tool uses, 2 edits, user messages.
TRIGGER_TP="$FIXTURE"

# 1. disabled via configuration
reset_state
skip_case disabled "$SID" "$TRIGGER_TP" '' CLAUDE_WATCHDOG_DISABLED=1

# 2. invalid session_id
reset_state
skip_case invalid-session-id 'bad id!' "$TRIGGER_TP" ''

# 3. running inside a subagent
reset_state
skip_case subagent "$SID" "$TRIGGER_TP" '{agent_id:"agt_1",agent_type:"general-purpose"}'

# 4. stop_reason is not end_turn
reset_state
skip_case stop-reason "$SID" "$TRIGGER_TP" '{stop_reason:"max_tokens"}'

# 5. our own analyzer echo
reset_state
mkdir -p "$GLOBAL_SESS"
printf '2026-01-01T00:00:00Z\n' > "$GLOBAL_SESS/echo-$SID"
skip_case echo "$SID" "$TRIGGER_TP" '{stop_hook_active:true}'

# 6. background tasks in flight
reset_state
skip_case background-tasks "$SID" "$TRIGGER_TP" '{background_tasks:[{type:"shell"},{type:"agent"}]}'

# 7. analysis already scheduled via session cron
reset_state
skip_case session-cron "$SID" "$TRIGGER_TP" '{session_crons:[{prompt:"/analyze-session"}]}'

# 8. .claude-watchdog-skip in the hook cwd
reset_state
: > "$PROJ/.claude-watchdog-skip"
skip_case skip-file "$SID" "$TRIGGER_TP" ''
rm -f "$PROJ/.claude-watchdog-skip"

# 9. concurrent run (marker already held)
reset_state
mkdir -p "$SESS_DIR/$SID"
skip_case concurrent "$SID" "$TRIGGER_TP" ''

# 10. transcript missing
reset_state
skip_case no-transcript "$SID" "$TMPROOT/does-not-exist.jsonl" ''

# 11. cooldown active
reset_state
mkdir -p "$SESS_DIR"
printf 'u-nope\n1\n%s\n' "$TRIGGER_TP" > "$SESS_DIR/cursor-$SID.txt"
skip_case cooldown "$SID" "$TRIGGER_TP" ''

# 12. delta too small (fixture has 12 tool uses, default minimum is 15)
reset_state
skip_case delta-too-small "$SID" "$TRIGGER_TP" ''

# 13. read-only turn: tool uses, but no edits and no mutating shell
reset_state
READONLY_TP="$TMPROOT/readonly.jsonl"
: > "$READONLY_TP"
jq -nc '{type:"user",uuid:"u-ro-1",message:{content:"please look around"}}' >> "$READONLY_TP"
for i in $(seq 1 6); do
  jq -nc --arg u "a-ro-$i" '{type:"assistant",uuid:$u,message:{content:[
    {type:"tool_use",id:("t1-"+$u),name:"Read",input:{file_path:"/repo/a.txt"}},
    {type:"tool_use",id:("t2-"+$u),name:"Bash",input:{command:"git status"}}]}}' >> "$READONLY_TP"
done
skip_case read-only "$SID" "$READONLY_TP" '' CLAUDE_WATCHDOG_MIN_TOOL_USES=5

# 14. no top-level user messages in the delta
reset_state
NOUSER_TP="$TMPROOT/no-user.jsonl"
: > "$NOUSER_TP"
for i in $(seq 1 6); do
  jq -nc --arg u "a-nu-$i" '{type:"assistant",uuid:$u,message:{content:[
    {type:"tool_use",id:("t-"+$u),name:"Edit",input:{file_path:"/repo/a.txt",old_string:"a",new_string:"b"}}]}}' >> "$NOUSER_TP"
done
skip_case no-user-messages "$SID" "$NOUSER_TP" '' CLAUDE_WATCHDOG_MIN_TOOL_USES=5

# Not covered: `SKIP: condensed transcript is empty`. It sits behind the
# user-message gate, and any entry that satisfies isUserMessage() also produces a
# USER line in extractTranscript(), so the condensed text cannot be empty at that
# point. Unreachable in the current implementation; see tests/golden/README.md.

# --- the blocking path: prompt and diagnostics -----------------------------

reset_state
TRIGGER_LOG="$TMPROOT/log-trigger.txt"
: > "$TRIGGER_LOG"
set_base_env "$TRIGGER_LOG"
run_stop "$(stop_payload "$SID" "$TRIGGER_TP" "$PROJ")" "${BASE_ENV[@]}" \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=5 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
[ "$(outcome "$STOP_OUT" "$STOP_RC")" = BLOCK ] \
  || fail "golden:stop.prompt" "expected BLOCK, got $(outcome "$STOP_OUT" "$STOP_RC")"
printf '%s' "$STOP_OUT" | jq -r '.reason' | check stop.prompt.txt

# The verbose header, with its counts, off the same trigger.
reset_state
VERBOSE_LOG="$TMPROOT/log-verbose.txt"
: > "$VERBOSE_LOG"
set_base_env "$VERBOSE_LOG"
run_stop "$(stop_payload "$SID" "$TRIGGER_TP" "$PROJ")" "${BASE_ENV[@]}" \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=5 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
  CLAUDE_WATCHDOG_VERBOSE=1
[ "$(outcome "$STOP_OUT" "$STOP_RC")" = BLOCK ] \
  || fail "golden:diagnostics" "expected BLOCK, got $(outcome "$STOP_OUT" "$STOP_RC")"
head -1 "$SESS_DIR/condensed-$SID.txt" | check stop.diagnostics.txt

if [ "$FAILED" -ne 0 ]; then
  echo "--- golden comparison failed ---" >&2
  echo "If the change was intentional, run 'just golden-regen' and commit the" >&2
  echo "updated goldens in the same PR as the behaviour change." >&2
  exit 1
fi

if [ "$REGEN" = "1" ]; then
  echo "--- goldens regenerated ---"
else
  echo "--- all golden comparisons passed ---"
fi
