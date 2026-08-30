#!/usr/bin/env bash
# Configuration parsing, storage resolution, and on-disk permissions.
#
# Covers the second half of section 3 of design/rewrite-readiness.md: numeric
# and boolean config parsing, cfg() precedence across all three value types,
# the projectRoot walk, and the 0700/0600 modes in both storage locations.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

GTMP="$TMPROOT/gtmp"
GSESSIONS="$GTMP/sessions"
ANALYSES="$TMPROOT/analyses"
TRANSCRIPT="$TMPROOT/tr.jsonl"
mk_transcript "$TRANSCRIPT" 1 5 CFG   # 5 rounds => 5 tool_uses, 5 edits

# A fresh log per case, so a `grep` cannot match a line an earlier case wrote.
LOGN=0
new_log() { LOGN=$((LOGN + 1)); LOG="$TMPROOT/log.$LOGN"; }

# Baseline env for the Stop hook: global storage, no cooldown, and a threshold
# the fixture clears. Cases append their own overrides after it.
base_env() {
  echo "CLAUDE_WATCHDOG_TMP=$GTMP" \
       "CLAUDE_WATCHDOG_ANALYSES_DIR=$ANALYSES" \
       "CLAUDE_WATCHDOG_LOG=$LOG" \
       "CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0" \
       "CLAUDE_WATCHDOG_MIN_TOOL_USES=3" \
       "CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0"
}

# stop_run <session-id> <cwd> [ENV=VAL ...] -> prints BLOCK|SKIP|ERR:<code>
stop_run() {
  local sid="$1" cwd="$2"; shift 2
  # shellcheck disable=SC2046  # deliberate word splitting of the env list
  run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$cwd")" $(base_env) "$@"
  outcome "$STOP_OUT" "$STOP_RC"
}

# mode_of <path> -> octal permission bits, GNU and BSD stat
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"; }

# ---------------------------------------------------------------------------
# Numeric config: an unparseable value falls back to the documented default.
#
# parseInt('abc') is NaN and every comparison against NaN is false, so before
# the fix each of these silently disabled the gate it feeds. The chosen
# behaviour is fall-back-to-default plus a CONFIG log line, not rejection.
# ---------------------------------------------------------------------------

# --- Test 1: MIN_TOOL_USES=abc falls back to 15, so a 5-tool delta skips ---
new_log
oc=$(stop_run "cfg-min-nan-$$" "$TMPROOT" CLAUDE_WATCHDOG_MIN_TOOL_USES=abc)
[ "$oc" = "SKIP" ] || { cat "$LOG"; fail "min-tool-uses-nan" "expected SKIP (default 15), got $oc"; }
grep -q "SKIP: delta too small (5 < 15)" "$LOG" || fail "min-tool-uses-nan-default" "gate did not use the default of 15"
grep -q "CONFIG: MIN_TOOL_USES='abc' is not a number, using default 15" "$LOG" \
  || fail "min-tool-uses-nan-log" "no CONFIG warning logged"
pass "numeric-config-min-tool-uses-nan"

# --- Test 2: COOLDOWN_SECONDS=abc falls back to 600, so the second run skips ---
new_log
sid="cfg-cd-nan-$$"
oc=$(stop_run "$sid" "$TMPROOT" CLAUDE_WATCHDOG_COOLDOWN_SECONDS=abc)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "cooldown-nan-first" "expected BLOCK, got $oc"; }
oc=$(stop_run "$sid" "$TMPROOT" CLAUDE_WATCHDOG_COOLDOWN_SECONDS=abc)
[ "$oc" = "SKIP" ] || { cat "$LOG"; fail "cooldown-nan-second" "expected SKIP, got $oc"; }
grep -q "SKIP: cooldown active (0s < 600s" "$LOG" || fail "cooldown-nan-default" "cooldown did not use the default of 600"
grep -q "CONFIG: COOLDOWN_SECONDS='abc' is not a number, using default 600" "$LOG" \
  || fail "cooldown-nan-log" "no CONFIG warning logged"
pass "numeric-config-cooldown-nan"

# --- Test 3: MAX_TRANSCRIPT_BYTES=abc falls back to 51200 (no truncation) ---
new_log
sid="cfg-mb-small-$$"
oc=$(stop_run "$sid" "$TMPROOT" CLAUDE_WATCHDOG_MAX_BYTES=200)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "max-bytes-small" "expected BLOCK, got $oc"; }
grep -q '^\[TRUNCATED\]' "$GSESSIONS/condensed-${sid}.txt" \
  || fail "max-bytes-small-truncates" "a 200-byte budget did not truncate"
new_log
sid="cfg-mb-nan-$$"
oc=$(stop_run "$sid" "$TMPROOT" CLAUDE_WATCHDOG_MAX_BYTES=abc)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "max-bytes-nan" "expected BLOCK, got $oc"; }
if grep -q '^\[TRUNCATED\]' "$GSESSIONS/condensed-${sid}.txt"; then
  fail "max-bytes-nan-default" "unparseable budget truncated; expected the 51200 default"
fi
grep -q "CONFIG: MAX_TRANSCRIPT_BYTES='abc' is not a number, using default 51200" "$LOG" \
  || fail "max-bytes-nan-log" "no CONFIG warning logged"
pass "numeric-config-max-bytes-nan"

# --- Test 4: LOG_MAX_LINES=abc falls back to 1000, so a 30-line log is kept ---
new_log
for i in $(seq 1 30); do echo "seed line $i" >> "$LOG"; done
stop_run "cfg-lml-nan-$$" "$TMPROOT" CLAUDE_WATCHDOG_LOG_MAX_LINES=abc > /dev/null
if grep -q "LOG ROTATED" "$LOG"; then fail "log-max-lines-nan" "rotated at 30 lines; expected the 1000 default"; fi
grep -q "seed line 1$" "$LOG" || fail "log-max-lines-nan-kept" "seed lines were dropped"
grep -q "CONFIG: CLAUDE_WATCHDOG_LOG_MAX_LINES='abc' is not a number, using default 1000" "$LOG" \
  || fail "log-max-lines-nan-log" "no CONFIG warning logged"
pass "numeric-config-log-max-lines-nan"

# --- Test 5: hold hook HOLD_TTL_SECONDS=abc falls back to 240 (still blocks) ---
new_log
mkdir -p "$GSESSIONS"
sid="cfg-httl-nan-$$"
printf '%s\n' "$(iso_now)" > "$GSESSIONS/pending-${sid}"
run_hold "$(jq -n --arg s "$sid" '{session_id:$s}')" \
  CLAUDE_WATCHDOG_HOLD_INPUT=1 CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_LOG="$LOG" \
  CLAUDE_WATCHDOG_HOLD_TTL_SECONDS=abc
echo "$HOLD_OUT" | grep -q '"decision":"block"' || fail "hold-ttl-nan" "expected block, got '$HOLD_OUT'"
grep -q "CONFIG: CLAUDE_WATCHDOG_HOLD_TTL_SECONDS='abc' is not a number, using default 240" "$LOG" \
  || fail "hold-ttl-nan-log" "no CONFIG warning logged"
rm -f "$GSESSIONS/pending-${sid}"
pass "numeric-config-hold-ttl-nan"

# ---------------------------------------------------------------------------
# Boolean config: only '1' and 'true' are truthy. Everything else, including
# 'TRUE', 'True', 'yes', and 'on', reads as false.
# ---------------------------------------------------------------------------

# --- Test 6: the truthy set ---
for v in 1 true; do
  new_log
  stop_run "cfg-bool-t-$$-$v" "$TMPROOT" "CLAUDE_WATCHDOG_DISABLED=$v" > /dev/null
  grep -q "SKIP: disabled via configuration" "$LOG" || fail "bool-truthy" "DISABLED='$v' did not disable"
done
pass "boolean-config-truthy-set"

# --- Test 7: the falsy set, including the near-misses ---
for v in TRUE True yes on 0 ""; do
  new_log
  stop_run "cfg-bool-f-$$-${v:-empty}" "$TMPROOT" "CLAUDE_WATCHDOG_DISABLED=$v" > /dev/null
  if grep -q "SKIP: disabled via configuration" "$LOG"; then
    fail "bool-falsy" "DISABLED='$v' disabled the hook; only '1' and 'true' are truthy"
  fi
done
pass "boolean-config-falsy-set"

# ---------------------------------------------------------------------------
# cfg() precedence: CLAUDE_WATCHDOG_* > CLAUDE_PLUGIN_OPTION_* > default.
# One case per value type, since a port touches every call site.
# ---------------------------------------------------------------------------

# --- Test 8: bool (DISABLED) ---
new_log
stop_run "cfg-prec-b1-$$" "$TMPROOT" CLAUDE_PLUGIN_OPTION_DISABLED=1 > /dev/null
grep -q "SKIP: disabled via configuration" "$LOG" || fail "prec-bool-plugin" "plugin option alone was ignored"
new_log
stop_run "cfg-prec-b2-$$" "$TMPROOT" CLAUDE_WATCHDOG_DISABLED=0 CLAUDE_PLUGIN_OPTION_DISABLED=1 > /dev/null
if grep -q "SKIP: disabled via configuration" "$LOG"; then
  fail "prec-bool-order" "plugin option beat CLAUDE_WATCHDOG_DISABLED"
fi
pass "cfg-precedence-bool"

# --- Test 9: int (MIN_TOOL_USES) ---
new_log
# base_env pins MIN_TOOL_USES=3, so drop it for the plugin-alone case by
# calling run_stop directly with a hand-built env list.
run_stop "$(stop_payload "cfg-prec-i1-$$" "$TRANSCRIPT" "$TMPROOT")" \
  CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$ANALYSES" CLAUDE_WATCHDOG_LOG="$LOG" \
  CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
  CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES=99
grep -q "SKIP: delta too small (5 < 99)" "$LOG" || { cat "$LOG"; fail "prec-int-plugin" "plugin option alone was ignored"; }
new_log
oc=$(stop_run "cfg-prec-i2-$$" "$TMPROOT" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES=99)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "prec-int-order" "plugin option beat CLAUDE_WATCHDOG_MIN_TOOL_USES, got $oc"; }
pass "cfg-precedence-int"

# --- Test 10: string (LEGACY_HOOK -> exit 2 + stderr instead of JSON) ---
# NOTE: the plugin-side name is lower-case (CLAUDE_PLUGIN_OPTION_legacy_hook),
# unlike every other option. legacy_hook is not declared in plugin.json, so
# nothing sets it in practice; pinned here as the string-typed precedence case.
new_log
oc=$(stop_run "cfg-prec-s1-$$" "$TMPROOT" CLAUDE_PLUGIN_OPTION_legacy_hook=true)
[ "$oc" = "ERR:2" ] || { cat "$LOG"; fail "prec-string-plugin" "expected ERR:2 from the plugin option, got $oc"; }
new_log
oc=$(stop_run "cfg-prec-s2-$$" "$TMPROOT" CLAUDE_WATCHDOG_LEGACY_HOOK=false CLAUDE_PLUGIN_OPTION_legacy_hook=true)
[ "$oc" = "BLOCK" ] || { cat "$LOG"; fail "prec-string-order" "plugin option beat CLAUDE_WATCHDOG_LEGACY_HOOK, got $oc"; }
pass "cfg-precedence-string"

# ---------------------------------------------------------------------------
# Storage resolution: the projectRoot walk and the literal "null" cwd.
# HOME is overridden per run so the walk's $HOME stop is exercised hermetically.
# ---------------------------------------------------------------------------

# --- Test 11: .git above the cwd anchors storage to the repo root ---
new_log
FAKE_HOME="$TMPROOT/home"
mkdir -p "$FAKE_HOME/repo/.git" "$FAKE_HOME/repo/sub/dir"
sid="cfg-root-git-$$"
run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$FAKE_HOME/repo/sub/dir")" \
  HOME="$FAKE_HOME" CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$ANALYSES" \
  CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
grep -q "LOCAL_STORAGE: using project-local path $FAKE_HOME/repo/.claude/tmp/claude-watchdog/sessions" "$LOG" \
  || { cat "$LOG"; fail "project-root-git" "storage not anchored to the repo root"; }
pass "project-root-anchors-at-git"

# --- Test 12: the walk stops at $HOME - a marker in $HOME never wins ---
new_log
mkdir -p "$FAKE_HOME/.git" "$FAKE_HOME/loose/dir"
sid="cfg-root-home-$$"
run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$FAKE_HOME/loose/dir")" \
  HOME="$FAKE_HOME" CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$ANALYSES" \
  CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
grep -q "LOCAL_STORAGE: using project-local path $FAKE_HOME/loose/dir/.claude/tmp/claude-watchdog/sessions" "$LOG" \
  || { cat "$LOG"; fail "project-root-home-stop" "walk did not stop at \$HOME"; }
if grep -q "anchored to project root" "$LOG"; then
  fail "project-root-home-stop-anchor" "walk hoisted storage above the cwd despite stopping at \$HOME"
fi
pass "project-root-walk-stops-at-home"

# --- Test 13: the walk stops at the filesystem root ---
# $TMPROOT is outside FAKE_HOME and has no .git or .claude above it, so the
# walk runs all the way to '/' and falls back to the cwd unchanged.
new_log
mkdir -p "$TMPROOT/rootwalk/a/b"
sid="cfg-root-fs-$$"
run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$TMPROOT/rootwalk/a/b")" \
  HOME="$FAKE_HOME" CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$ANALYSES" \
  CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
grep -q "LOCAL_STORAGE: using project-local path $TMPROOT/rootwalk/a/b/.claude/tmp/claude-watchdog/sessions" "$LOG" \
  || { cat "$LOG"; fail "project-root-fs-stop" "walk did not fall back to the cwd at the filesystem root"; }
pass "project-root-walk-stops-at-fs-root"

# --- Test 14: cwd arriving as the literal string "null" falls back to global ---
new_log
sid="cfg-cwd-null-$$"
run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "null")" \
  CLAUDE_WATCHDOG_TMP="$GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$ANALYSES" CLAUDE_WATCHDOG_LOG="$LOG" \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
grep -q "LOCAL_STORAGE: hook_cwd empty or invalid, falling back to global" "$LOG" \
  || { cat "$LOG"; fail "cwd-null-log" "no fallback log line"; }
[ -f "$GSESSIONS/condensed-${sid}.txt" ] || fail "cwd-null-storage" "condensed transcript not in global storage"
[ ! -e "null" ] || fail "cwd-null-literal-dir" "a directory literally named 'null' was created"
pass "cwd-null-falls-back-to-global"

# ---------------------------------------------------------------------------
# Permissions. Asserted as explicit octal modes, not as "tighter than the
# umask": the hooks set umask 0o077 themselves, so the result must be 0700 /
# 0600 regardless of what the caller's umask was. Run under a deliberately
# loose 022 so a regression to caller-umask behaviour shows up.
# ---------------------------------------------------------------------------

# --- Test 15: global storage, analyses dir, and the log ---
new_log
PERM_GTMP="$TMPROOT/perm-gtmp"
PERM_AN="$TMPROOT/perm-analyses"
sid="cfg-perm-g-$$"
( umask 022
  run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$TMPROOT")" \
    CLAUDE_WATCHDOG_TMP="$PERM_GTMP" CLAUDE_WATCHDOG_ANALYSES_DIR="$PERM_AN" \
    CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
    CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 )
for d in "$PERM_GTMP" "$PERM_GTMP/sessions" "$PERM_AN"; do
  m=$(mode_of "$d")
  [ "$m" = "700" ] || fail "perm-global-dir" "$d is $m, expected 700"
done
for f in "$PERM_GTMP/sessions/condensed-${sid}.txt" "$PERM_GTMP/sessions/cursor-${sid}.txt" \
         "$PERM_GTMP/sessions/echo-${sid}" "$LOG"; do
  m=$(mode_of "$f")
  [ "$m" = "600" ] || fail "perm-global-file" "$f is $m, expected 600"
done
pass "permissions-global-storage-0700-0600"

# --- Test 16: project-local storage, including the directories on the way down ---
new_log
PERM_PROJ="$TMPROOT/perm-proj"
mkdir -p "$PERM_PROJ/.git"
sid="cfg-perm-l-$$"
( umask 022
  run_stop "$(stop_payload "$sid" "$TRANSCRIPT" "$PERM_PROJ")" \
    CLAUDE_WATCHDOG_TMP="$TMPROOT/perm-gtmp2" CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/perm-an2" \
    CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 )
LOCAL_SESSIONS="$PERM_PROJ/.claude/tmp/claude-watchdog/sessions"
[ -d "$LOCAL_SESSIONS" ] || { cat "$LOG"; fail "perm-local-missing" "project-local storage was not used"; }
for d in "$PERM_PROJ/.claude" "$PERM_PROJ/.claude/tmp" "$PERM_PROJ/.claude/tmp/claude-watchdog" "$LOCAL_SESSIONS"; do
  m=$(mode_of "$d")
  [ "$m" = "700" ] || fail "perm-local-dir" "$d is $m, expected 700"
done
for f in "$LOCAL_SESSIONS/condensed-${sid}.txt" "$LOCAL_SESSIONS/cursor-${sid}.txt"; do
  m=$(mode_of "$f")
  [ "$m" = "600" ] || fail "perm-local-file" "$f is $m, expected 600"
done
pass "permissions-local-storage-0700-0600"

# --- Test 17: the persist hook's analyses directory and analysis file ---
new_log
PERSIST_AN="$TMPROOT/persist-analyses"
sid="cfg-perm-p-$$"
( umask 022
  run_persist "$(jq -n --arg s "$sid" '{session_id:$s, agent_type:"session-analyzer", last_assistant_message:"analysis body"}')" \
    CLAUDE_WATCHDOG_ANALYSES_DIR="$PERSIST_AN" CLAUDE_WATCHDOG_LOG="$LOG" CLAUDE_WATCHDOG_TMP="$TMPROOT/persist-tmp" )
m=$(mode_of "$PERSIST_AN")
[ "$m" = "700" ] || fail "perm-persist-dir" "$PERSIST_AN is $m, expected 700"
# shellcheck disable=SC2012  # filenames are <session_id>-<timestamp>.md
af=$(ls "$PERSIST_AN"/${sid}-*.md | head -1)
m=$(mode_of "$af")
[ "$m" = "600" ] || fail "perm-persist-file" "$af is $m, expected 600"
m=$(mode_of "$LOG")
[ "$m" = "600" ] || fail "perm-persist-log" "$LOG is $m, expected 600"
pass "permissions-persist-analyses-0700-0600"

echo "--- all config tests passed ---"
