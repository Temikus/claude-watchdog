#!/usr/bin/env bash
# Storage lifecycle: log rotation, sessions-dir cleanup, the analyses cap, and
# marker/delta release on every exit path. Plus the hold and persist hooks'
# own lifecycle edges.
#
# Covers the second half of section 3 of design/rewrite-readiness.md.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# A fresh log per case, so a `grep` cannot match a line an earlier case wrote.
LOGN=0
new_log() { LOGN=$((LOGN + 1)); LOG="$TMPROOT/log.$LOGN"; }

# set_mtime <path> <seconds-ago> - portable `touch -t`, GNU and BSD date.
set_mtime() {
  local path="$1" secs="$2" epoch stamp
  epoch=$(( $(date +%s) - secs ))
  stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$path"
}

# A fresh global tmp + analyses pair per case, so cleanup and cap assertions
# only ever see what the case itself put there.
CASEN=0
new_case() {
  CASEN=$((CASEN + 1))
  GTMP="$TMPROOT/gtmp.$CASEN"
  SESSIONS="$GTMP/sessions"
  ANALYSES="$TMPROOT/analyses.$CASEN"
  mkdir -p "$SESSIONS" "$ANALYSES"
  new_log
}

base_env() {
  echo "CLAUDE_WATCHDOG_TMP=$GTMP" \
       "CLAUDE_WATCHDOG_ANALYSES_DIR=$ANALYSES" \
       "CLAUDE_WATCHDOG_LOG=$LOG" \
       "CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0" \
       "CLAUDE_WATCHDOG_MIN_TOOL_USES=3" \
       "CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0"
}

# stop_run <session-id> <transcript> [ENV=VAL ...] -> prints BLOCK|SKIP|ERR:<code>
stop_run() {
  local sid="$1" tp="$2"; shift 2
  # shellcheck disable=SC2046  # deliberate word splitting of the env list
  run_stop "$(stop_payload "$sid" "$tp" "$TMPROOT")" $(base_env) "$@"
  outcome "$STOP_OUT" "$STOP_RC"
}

# no_residue <session-id> <label> - the marker dir and the delta file must both
# be gone once the hook has exited, whichever path it took.
no_residue() {
  local sid="$1" label="$2"
  [ ! -e "$SESSIONS/$sid" ] || { cat "$LOG"; fail "$label" "marker directory leaked"; }
  [ ! -e "$SESSIONS/delta-${sid}.tmp" ] || { cat "$LOG"; fail "$label" "delta file leaked"; }
}

TRANSCRIPT="$TMPROOT/tr.jsonl"
mk_transcript "$TRANSCRIPT" 1 5 LIFE   # 5 rounds => 5 tool_uses, 5 edits, 5 user messages

# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------

# --- Test 1: the log is trimmed to CLAUDE_WATCHDOG_LOG_MAX_LINES ---
new_case
mkdir -p "$(dirname "$LOG")"
for i in $(seq 1 500); do echo "[old] filler line $i"; done > "$LOG"
oc=$(stop_run "life-rotate-$$" "$TRANSCRIPT" CLAUDE_WATCHDOG_LOG_MAX_LINES=100 CLAUDE_WATCHDOG_MIN_TOOL_USES=99)
[ "$oc" = "SKIP" ] || fail "log-rotation" "expected SKIP, got $oc"
grep -q "LOG ROTATED (was 50[0-9] lines)" "$LOG" || { cat "$LOG"; fail "log-rotation-line" "no LOG ROTATED line"; }
lines=$(wc -l < "$LOG" | tr -d ' ')
# 100 kept + the ROTATED line + the handful this run appends afterwards.
# shellcheck disable=SC2015  # fail() exits, so this is an assert, not if/else
[ "$lines" -ge 100 ] && [ "$lines" -le 115 ] || fail "log-rotation-size" "expected ~100 lines, got $lines"
grep -q "filler line 1$" "$LOG" && fail "log-rotation-head" "oldest lines were not dropped"
grep -q "filler line 500" "$LOG" || fail "log-rotation-tail" "newest kept lines were dropped"
pass "log-rotation"

# --- Test 2: a log under the cap is left alone ---
new_case
mkdir -p "$(dirname "$LOG")"
for i in $(seq 1 20); do echo "[old] filler line $i"; done > "$LOG"
stop_run "life-norotate-$$" "$TRANSCRIPT" CLAUDE_WATCHDOG_LOG_MAX_LINES=100 CLAUDE_WATCHDOG_MIN_TOOL_USES=99 > /dev/null
grep -q "LOG ROTATED" "$LOG" && fail "log-no-rotation" "rotated a log under the cap"
grep -q "filler line 1$" "$LOG" || fail "log-no-rotation-head" "dropped lines from a log under the cap"
pass "log-no-rotation"

# ---------------------------------------------------------------------------
# Two-hour cleanup of the sessions directory
# ---------------------------------------------------------------------------

# --- Test 3: stale scratch files are swept, cursors and fresh files survive ---
new_case
sid="life-sweep-$$"
for p in condensed raw delta echo pending; do
  echo x > "$SESSIONS/${p}-stale.txt"; set_mtime "$SESSIONS/${p}-stale.txt" 10800   # 3h
  echo x > "$SESSIONS/${p}-fresh.txt"
done
# The cursor has its own 7-day TTL, so 3h old is nowhere near expiry.
echo x > "$SESSIONS/cursor-stale.txt"; set_mtime "$SESSIONS/cursor-stale.txt" 10800
# Anything that is not one of the six prefixes is not ours to delete.
echo x > "$SESSIONS/unrelated-stale.txt"; set_mtime "$SESSIONS/unrelated-stale.txt" 10800
mkdir -p "$SESSIONS/stale-marker"; set_mtime "$SESSIONS/stale-marker" 10800
mkdir -p "$SESSIONS/fresh-marker"
mkdir -p "$SESSIONS/stale-nonempty"; echo x > "$SESSIONS/stale-nonempty/held"
set_mtime "$SESSIONS/stale-nonempty" 10800

stop_run "$sid" "$TRANSCRIPT" CLAUDE_WATCHDOG_MIN_TOOL_USES=99 > /dev/null

for p in condensed raw delta echo pending; do
  [ ! -e "$SESSIONS/${p}-stale.txt" ] || fail "cleanup-stale" "${p}-stale.txt survived the two-hour sweep"
  [ -e "$SESSIONS/${p}-fresh.txt" ] || fail "cleanup-fresh" "${p}-fresh.txt was swept while still fresh"
done
[ -e "$SESSIONS/cursor-stale.txt" ] || fail "cleanup-cursor" "cursor swept at 3h; its TTL is 7 days"
[ -e "$SESSIONS/unrelated-stale.txt" ] || fail "cleanup-unrelated" "swept a file the plugin does not own"
[ ! -e "$SESSIONS/stale-marker" ] || fail "cleanup-marker" "stale marker directory survived"
[ -e "$SESSIONS/fresh-marker" ] || fail "cleanup-fresh-marker" "removed a marker for a run that may still be live"
# A non-empty directory is left alone: rmdir fails and the failure is swallowed.
[ -e "$SESSIONS/stale-nonempty" ] || fail "cleanup-nonempty" "removed a non-empty stale directory"
pass "sessions-dir-two-hour-cleanup"

# ---------------------------------------------------------------------------
# Analyses cap in the Stop hook
# ---------------------------------------------------------------------------

# --- Test 4: the Stop hook prunes the analyses dir to the newest 20 ---
new_case
for i in $(seq 1 25); do
  f=$(printf '%s/old-%02d-20240101T000000Z.md' "$ANALYSES" "$i")
  echo "analysis $i" > "$f"
  # i=1 is the oldest, i=25 the newest.
  set_mtime "$f" $(( (26 - i) * 60 ))
done
stop_run "life-cap-$$" "$TRANSCRIPT" CLAUDE_WATCHDOG_MIN_TOOL_USES=99 > /dev/null
count=$(find "$ANALYSES" -name '*.md' | wc -l | tr -d ' ')
[ "$count" -eq 20 ] || fail "analyses-cap" "expected 20 files, got $count"
for i in 1 2 3 4 5; do
  f=$(printf '%s/old-%02d-20240101T000000Z.md' "$ANALYSES" "$i")
  [ ! -e "$f" ] || fail "analyses-cap-oldest" "oldest file $i survived the cap"
done
for i in 6 25; do
  f=$(printf '%s/old-%02d-20240101T000000Z.md' "$ANALYSES" "$i")
  [ -e "$f" ] || fail "analyses-cap-newest" "newer file $i was pruned"
done
pass "analyses-cap-stop-hook"

# ---------------------------------------------------------------------------
# Marker directory and delta file released on every exit path after acquisition.
# A leaked marker wedges the plugin for two hours (the sweep above is the only
# other release), so each path gets its own case.
#
# The "condensed transcript is empty" SKIP is not covered because it is not
# reachable: a delta that clears MIN_TOOL_USES has at least one tool_use, which
# always emits a TOOL_USE line, and condense()'s truncating branch prepends
# [TRUNCATED] unconditionally. See the report on this branch.
# ---------------------------------------------------------------------------

# --- Test 5: transcript missing ---
new_case
sid="life-notranscript-$$"
oc=$(stop_run "$sid" "$TMPROOT/does-not-exist.jsonl")
[ "$oc" = "SKIP" ] || fail "release-no-transcript" "expected SKIP, got $oc"
grep -q "SKIP: transcript not found" "$LOG" || { cat "$LOG"; fail "release-no-transcript" "wrong skip reason"; }
no_residue "$sid" "release-no-transcript"
pass "release-on-transcript-not-found"

# --- Test 6: cooldown active ---
new_case
sid="life-cooldown-$$"
printf 'a-LIFE-5\n10\n%s\n' "$TRANSCRIPT" > "$SESSIONS/cursor-${sid}.txt"
oc=$(stop_run "$sid" "$TRANSCRIPT" CLAUDE_WATCHDOG_COOLDOWN_SECONDS=600)
[ "$oc" = "SKIP" ] || fail "release-cooldown" "expected SKIP, got $oc"
grep -q "SKIP: cooldown active" "$LOG" || { cat "$LOG"; fail "release-cooldown" "wrong skip reason"; }
no_residue "$sid" "release-cooldown"
pass "release-on-cooldown"

# --- Test 7: delta below MIN_TOOL_USES ---
new_case
sid="life-small-$$"
oc=$(stop_run "$sid" "$TRANSCRIPT" CLAUDE_WATCHDOG_MIN_TOOL_USES=99)
[ "$oc" = "SKIP" ] || fail "release-small-delta" "expected SKIP, got $oc"
grep -q "SKIP: delta too small" "$LOG" || { cat "$LOG"; fail "release-small-delta" "wrong skip reason"; }
no_residue "$sid" "release-small-delta"
pass "release-on-small-delta"

# --- Test 8: read-only turn (tool uses, but no edits and no mutating shell) ---
new_case
sid="life-readonly-$$"
RO_TRANSCRIPT="$TMPROOT/tr-readonly.jsonl"
: > "$RO_TRANSCRIPT"
for i in 1 2 3; do
  jq -nc --arg u "u-ro-$i" --arg t "ro user $i" '{type:"user",uuid:$u,message:{content:$t}}' >> "$RO_TRANSCRIPT"
  jq -nc --arg u "a-ro-$i" '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"reading"},{type:"tool_use",id:("t_"+$u),name:"Read",input:{file_path:"/tmp/x"}}]}}' >> "$RO_TRANSCRIPT"
done
oc=$(stop_run "$sid" "$RO_TRANSCRIPT" CLAUDE_WATCHDOG_MIN_TOOL_USES=1)
[ "$oc" = "SKIP" ] || fail "release-read-only" "expected SKIP, got $oc"
grep -q "SKIP: delta has no file edits or mutating shell commands" "$LOG" || { cat "$LOG"; fail "release-read-only" "wrong skip reason"; }
no_residue "$sid" "release-read-only"
pass "release-on-read-only-turn"

# --- Test 9: no top-level user messages ---
new_case
sid="life-nouser-$$"
NOUSER_TRANSCRIPT="$TMPROOT/tr-nouser.jsonl"
: > "$NOUSER_TRANSCRIPT"
for i in 1 2 3; do mk_msg assistant "a-nu-$i" "nu assistant $i" >> "$NOUSER_TRANSCRIPT"; done
oc=$(stop_run "$sid" "$NOUSER_TRANSCRIPT" CLAUDE_WATCHDOG_MIN_TOOL_USES=1)
[ "$oc" = "SKIP" ] || fail "release-no-user" "expected SKIP, got $oc"
grep -q "SKIP: delta has no top-level user messages" "$LOG" || { cat "$LOG"; fail "release-no-user" "wrong skip reason"; }
no_residue "$sid" "release-no-user"
pass "release-on-no-user-messages"

# --- Test 10: the success path releases too ---
new_case
sid="life-block-$$"
oc=$(stop_run "$sid" "$TRANSCRIPT")
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "release-on-block" "expected BLOCK, got $oc"; }
no_residue "$sid" "release-on-block"
# The condensed transcript is the analyzer's input and must outlive the run.
[ -e "$SESSIONS/condensed-${sid}.txt" ] || fail "release-on-block" "condensed transcript was removed"
pass "release-on-successful-block"

# --- Test 11: a concurrent run leaves the first run's marker in place ---
new_case
sid="life-concurrent-$$"
mkdir -p "$SESSIONS/$sid"
oc=$(stop_run "$sid" "$TRANSCRIPT")
[ "$oc" = "SKIP" ] || fail "concurrent-marker" "expected SKIP, got $oc"
grep -q "SKIP: concurrent run already in progress" "$LOG" || { cat "$LOG"; fail "concurrent-marker" "wrong skip reason"; }
[ -d "$SESSIONS/$sid" ] || fail "concurrent-marker" "the losing run deleted the winner's marker"
pass "concurrent-run-keeps-foreign-marker"

# ---------------------------------------------------------------------------
# Hold hook lifecycle
# ---------------------------------------------------------------------------

hold_payload() { jq -n --arg sid "$1" '{session_id:$sid, hook_event_name:"UserPromptSubmit", cwd:"/tmp"}'; }

hold_run() {
  local sid="$1"; shift
  run_hold "$(hold_payload "$sid")" "CLAUDE_WATCHDOG_TMP=$GTMP" "CLAUDE_WATCHDOG_LOG=$LOG" \
    CLAUDE_WATCHDOG_HOLD_INPUT=1 "$@"
  outcome "$HOLD_OUT" "$HOLD_RC"
}

# --- Test 12: a TTL of zero or less releases immediately ---
for ttl in 0 -5; do
  new_case
  sid="life-hold-ttl${ttl#-}-$$"
  printf '%s\n' "$(iso_now)" > "$SESSIONS/pending-${sid}"
  oc=$(hold_run "$sid" "CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=$ttl")
  [ "$oc" = "SKIP" ] || fail "hold-ttl-nonpositive" "TTL=$ttl blocked instead of releasing"
  [ ! -e "$SESSIONS/pending-${sid}" ] || fail "hold-ttl-nonpositive" "TTL=$ttl left the sentinel behind"
  grep -q "RELEASE: hold expired" "$LOG" || { cat "$LOG"; fail "hold-ttl-nonpositive" "no RELEASE logged for TTL=$ttl"; }
done
pass "hold-ttl-non-positive-releases"

# --- Test 13: an unparseable timestamp on line 1 falls back to the mtime ---
new_case
sid="life-hold-badts-fresh-$$"
printf 'not-a-timestamp\n' > "$SESSIONS/pending-${sid}"
oc=$(hold_run "$sid" CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=600)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "hold-mtime-fallback-fresh" "expected BLOCK, got $oc"; }
sed -n '2p' "$SESSIONS/pending-${sid}" | grep -qx 'nudged' || fail "hold-mtime-fallback-fresh" "sentinel not marked nudged"

new_case
sid="life-hold-badts-stale-$$"
printf 'not-a-timestamp\n' > "$SESSIONS/pending-${sid}"
set_mtime "$SESSIONS/pending-${sid}" 3600
oc=$(hold_run "$sid" CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=600)
[ "$oc" = "SKIP" ] || fail "hold-mtime-fallback-stale" "expected SKIP, got $oc"
[ ! -e "$SESSIONS/pending-${sid}" ] || fail "hold-mtime-fallback-stale" "expired sentinel not removed"
pass "hold-unparseable-timestamp-falls-back-to-mtime"

# --- Test 14: a failed 'nudged' rewrite still blocks, and blocks again next time ---
# Root ignores the mode bits, so there is no way to make the write fail there.
if [ "$(id -u)" -eq 0 ]; then
  echo "SKIP: hold-nudge-write-failure (running as root)"
else
  new_case
  sid="life-hold-rowrite-$$"
  printf '%s\n' "$(iso_now)" > "$SESSIONS/pending-${sid}"
  chmod 444 "$SESSIONS/pending-${sid}"
  oc=$(hold_run "$sid" CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=600)
  [ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "hold-nudge-write-failure" "expected BLOCK, got $oc"; }
  sed -n '2p' "$SESSIONS/pending-${sid}" | grep -qx 'nudged' && fail "hold-nudge-write-failure" "sentinel was rewritten after all"
  # The override is lost, so the same prompt blocks again; the TTL is the backstop.
  oc=$(hold_run "$sid" CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=600)
  [ "$oc" = "BLOCK" ] || fail "hold-nudge-write-failure" "second attempt should still block, got $oc"
  chmod 644 "$SESSIONS/pending-${sid}"
  pass "hold-nudge-write-failure-still-blocks"
fi

# ---------------------------------------------------------------------------
# Persist hook lifecycle
# ---------------------------------------------------------------------------

persist_run() {
  local sid="$1" msg="$2"
  run_persist "$(jq -n --arg sid "$sid" --arg msg "$msg" \
    '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')" \
    "CLAUDE_WATCHDOG_TMP=$GTMP" "CLAUDE_WATCHDOG_ANALYSES_DIR=$ANALYSES" "CLAUDE_WATCHDOG_LOG=$LOG"
}

# --- Test 15: the filename is <session_id>-YYYYMMDDTHHMMSSZ.md ---
new_case
sid="life-persist-name-$$"
persist_run "$sid" "analysis body"
written=$(find "$ANALYSES" -name '*.md' -maxdepth 1 | head -1)
[ -n "$written" ] || fail "persist-filename" "no file written"
base=$(basename "$written")
echo "$base" | grep -Eq "^${sid}-[0-9]{8}T[0-9]{6}Z\.md$" \
  || fail "persist-filename" "unexpected filename '$base'"
pass "persist-filename-format"

# --- Test 16: the analyses dir is pruned to the newest 20 after a write ---
new_case
sid="life-persist-cap-$$"
for i in $(seq 1 22); do
  f=$(printf '%s/prior-%02d-20240101T000000Z.md' "$ANALYSES" "$i")
  echo "analysis $i" > "$f"
  set_mtime "$f" $(( (23 - i) * 60 ))   # i=1 oldest
done
persist_run "$sid" "newest analysis"
count=$(find "$ANALYSES" -name '*.md' | wc -l | tr -d ' ')
[ "$count" -eq 20 ] || fail "persist-cap" "expected 20 files, got $count"
find "$ANALYSES" -name "${sid}-*.md" | grep -q . || fail "persist-cap" "the file just written was pruned"
for i in 1 2 3; do
  f=$(printf '%s/prior-%02d-20240101T000000Z.md' "$ANALYSES" "$i")
  [ ! -e "$f" ] || fail "persist-cap-oldest" "oldest file $i survived the cap"
done
[ -e "$(printf '%s/prior-22-20240101T000000Z.md' "$ANALYSES")" ] || fail "persist-cap-newest" "newest prior file was pruned"
pass "persist-analyses-cap-prunes-oldest"

# --- Test 17: stdin over 128 KB is truncated, so the hook fails open ---
new_case
sid="life-persist-huge-$$"
huge=$(head -c 200000 /dev/zero | tr '\0' 'x')
run_persist "$(jq -n --arg sid "$sid" --arg msg "$huge" \
  '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')" \
  "CLAUDE_WATCHDOG_TMP=$GTMP" "CLAUDE_WATCHDOG_ANALYSES_DIR=$ANALYSES" "CLAUDE_WATCHDOG_LOG=$LOG"
[ "$PERSIST_RC" -eq 0 ] || fail "persist-stdin-cap" "expected a clean exit, got $PERSIST_RC"
find "$ANALYSES" -name "${sid}-*.md" | grep -q . && fail "persist-stdin-cap" "wrote a file from a truncated payload"
grep -q "ERROR: unexpected failure" "$LOG" || { cat "$LOG"; fail "persist-stdin-cap" "truncated payload was not logged as a failure"; }
pass "persist-stdin-128kb-cap"

# --- Test 18: a payload just under the cap is persisted whole ---
new_case
sid="life-persist-large-$$"
large=$(head -c 100000 /dev/zero | tr '\0' 'y')
persist_run "$sid" "$large"
written=$(find "$ANALYSES" -name "${sid}-*.md" | head -1)
[ -n "$written" ] || { cat "$LOG"; fail "persist-under-cap" "no file written for a 100KB message"; }
size=$(wc -c < "$written" | tr -d ' ')
[ "$size" -eq 100001 ] || fail "persist-under-cap" "expected 100001 bytes, got $size"
pass "persist-under-stdin-cap"

echo "--- all lifecycle tests passed ---"
