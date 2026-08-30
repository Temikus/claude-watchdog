#!/usr/bin/env bash
# Stop-hook gating and transcript handling.
#
# Section 3 of design/rewrite-readiness.md, first half: every gate the Stop hook
# applies before it triggers, plus the transcript quirks (UTF-8, CRLF, empty)
# that the truncation path has to survive.
#
# Everything here runs end to end through $HOOK_STOP. Each case gets a hermetic
# $HOME so the developer's own CLAUDE.md and rules can't leak into the prompt.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

GHOME="$TMPROOT/home"
GTMP="$TMPROOT/wtmp"
GANALYSES="$TMPROOT/analyses"
GLOG="$TMPROOT/log"
GSESSIONS="$GTMP/sessions"
mkdir -p "$GHOME" "$GTMP" "$GANALYSES"

# A project dir the hook can resolve as cwd. `.git` pins projectRoot() so the
# rules tests don't depend on whatever sits above $TMPDIR.
PROJ="$TMPROOT/project"
mkdir -p "$PROJ/.git"

# Counter lives in a file: new_sid is used as `sid=$(new_sid)`, and a subshell
# cannot hand an incremented shell variable back.
SIDCOUNT="$TMPROOT/sid-counter"
echo 0 > "$SIDCOUNT"
new_sid() {
  local n
  n=$(( $(cat "$SIDCOUNT") + 1 ))
  echo "$n" > "$SIDCOUNT"
  echo "gates-$$-$n"
}

# gate_run <sid> <transcript> <cwd> <jq-extra> [ENV=VAL ...]
# Truncates the log first so each case asserts on its own lines. Later env
# assignments win, so a case can override any default below.
gate_run() {
  local sid="$1" tp="$2" cwd="$3" extra="$4"; shift 4
  : > "$GLOG"
  run_stop "$(stop_payload "$sid" "$tp" "$cwd" "$extra")" \
    HOME="$GHOME" \
    CLAUDE_WATCHDOG_LOG="$GLOG" \
    CLAUDE_WATCHDOG_TMP="$GTMP" \
    CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" \
    CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
    CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
    CLAUDE_WATCHDOG_MIN_TOOL_USES=3 \
    ${1+"$@"}
}

# assert_outcome <label> <expected> - reads STOP_OUT/STOP_RC, dumps the log on
# failure so a red run explains itself.
assert_outcome() {
  local label="$1" want="$2" got
  got=$(outcome "$STOP_OUT" "$STOP_RC")
  [ "$got" = "$want" ] || { cat "$GLOG" >&2; fail "$label" "expected $want, got $got"; }
}

assert_log() {
  local label="$1" pattern="$2"
  grep -q "$pattern" "$GLOG" || { cat "$GLOG" >&2; fail "$label" "log missing /$pattern/"; }
}

assert_out() {
  local label="$1" pattern="$2"
  printf '%s' "$STOP_OUT" | grep -q "$pattern" || fail "$label" "stdout missing /$pattern/"
}

refute_out() {
  local label="$1" pattern="$2"
  printf '%s' "$STOP_OUT" | grep -q "$pattern" && fail "$label" "stdout unexpectedly matched /$pattern/"
  return 0
}

# --- transcript builders ---------------------------------------------------

# mk_bash_transcript <path> <command> - 3 rounds, one Bash tool_use each and no
# edits, so the read-only gate is decided purely by the command string.
mk_bash_transcript() {
  local path="$1" cmd="$2" i
  : > "$path"
  for i in 1 2 3; do
    {
      jq -nc --arg u "u-$i" --arg t "user $i" \
        '{type:"user",uuid:$u,message:{content:$t}}'
      jq -nc --arg u "a-$i" --arg c "$cmd" \
        '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"running"},{type:"tool_use",id:("t_"+$u),name:"Bash",input:{command:$c}}]}}'
    } >> "$path"
  done
}

# mk_edit_transcript <path> <tool> <input-key> <file> - 3 rounds of one edit
# tool, so the tool name and its file-path key decide edits and touched files.
mk_edit_transcript() {
  local path="$1" tool="$2" key="$3" file="$4" i
  : > "$path"
  for i in 1 2 3; do
    {
      jq -nc --arg u "u-$i" --arg t "user $i" \
        '{type:"user",uuid:$u,message:{content:$t}}'
      jq -nc --arg u "a-$i" --arg n "$tool" --arg k "$key" --arg f "$file" \
        '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"editing"},{type:"tool_use",id:("t_"+$u),name:$n,input:{($k):$f}}]}}'
    } >> "$path"
  done
}

# ===========================================================================
# stop_reason
# ===========================================================================

sr_transcript="$TMPROOT/stopreason.jsonl"
mk_transcript "$sr_transcript" 1 3 SR

for reason in compaction tool_use max_tokens; do
  sid=$(new_sid)
  gate_run "$sid" "$sr_transcript" "$PROJ" "{stop_reason:\"$reason\"}"
  assert_outcome "stop-reason-$reason" SKIP
  assert_log "stop-reason-$reason" "SKIP: stop_reason is '$reason', not 'end_turn'"
  pass "stop-reason-$reason-skips"
done

# Control: the same transcript with end_turn triggers, so the cases above
# isolate stop_reason rather than some other gate.
sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$PROJ" ""
assert_outcome "stop-reason-end-turn" BLOCK
pass "stop-reason-end-turn-triggers"

# ===========================================================================
# transcript_path
# ===========================================================================

sid=$(new_sid)
gate_run "$sid" "$TMPROOT/does-not-exist.jsonl" "$PROJ" ""
assert_outcome "transcript-nonexistent" SKIP
assert_log "transcript-nonexistent" "SKIP: transcript not found at"
pass "transcript-nonexistent-skips"

# transcript_path absent from the event entirely.
sid=$(new_sid)
: > "$GLOG"
run_stop "$(jq -n --arg sid "$sid" --arg cwd "$PROJ" \
  '{session_id:$sid, cwd:$cwd, stop_reason:"end_turn"}')" \
  HOME="$GHOME" CLAUDE_WATCHDOG_LOG="$GLOG" CLAUDE_WATCHDOG_TMP="$GTMP" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_MIN_TOOL_USES=3
assert_outcome "transcript-missing" SKIP
assert_log "transcript-missing" "SKIP: transcript not found at"
pass "transcript-missing-skips"

# ===========================================================================
# .claude-watchdog-skip
# ===========================================================================

skipproj="$TMPROOT/skipproj"
mkdir -p "$skipproj"
sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$skipproj" ""
assert_outcome "skip-file-control" BLOCK

touch "$skipproj/.claude-watchdog-skip"
sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$skipproj" ""
assert_outcome "skip-file" SKIP
assert_log "skip-file" "SKIP: disabled via .claude-watchdog-skip in $skipproj"
pass "skip-file-skips"

# ===========================================================================
# read-only turn, and the READ_ONLY_BASH regex
# ===========================================================================

sid=$(new_sid)
ro_transcript="$TMPROOT/readonly.jsonl"
mk_bash_transcript "$ro_transcript" "cat /etc/hosts"
gate_run "$sid" "$ro_transcript" "$PROJ" ""
assert_outcome "read-only-turn" SKIP
assert_log "read-only-turn" "SKIP: delta has no file edits or mutating shell commands"
assert_log "read-only-turn" "edits=0 mutating_bash=0"
pass "read-only-turn-skips"

# Each pair is <command>|<expected outcome>. SKIP means the command was
# classified read-only; BLOCK means it counted as mutating.
while IFS='|' read -r cmd want label; do
  [ -n "$cmd" ] || continue
  sid=$(new_sid)
  bt="$TMPROOT/bash-$sid.jsonl"
  mk_bash_transcript "$bt" "$cmd"
  gate_run "$sid" "$bt" "$PROJ" ""
  assert_outcome "read-only-bash-$label" "$want"
  pass "read-only-bash-$label"
done <<'CMDS'
sed -n '1,5p' file.txt|SKIP|sed-n-is-read-only
sed -i.bak s/a/b/ file.txt|BLOCK|sed-i-is-mutating
    git diff --stat|SKIP|leading-whitespace-tolerated
git diff|SKIP|git-diff-is-read-only
git push origin main|BLOCK|git-push-is-mutating
CMDS

# ===========================================================================
# top-level user messages
# ===========================================================================

# A text block sharing its entry with a tool_result was typed while the turn was
# running; it is not the prompt that started the turn and must not count.
sid=$(new_sid)
tr_transcript="$TMPROOT/toolresult-text.jsonl"
: > "$tr_transcript"
for i in 1 2 3; do
  {
    jq -nc --arg u "a-$i" \
      '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"editing"},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:"a",new_string:"b"}}]}}'
    jq -nc --arg u "u-$i" \
      '{type:"user",uuid:$u,message:{content:[{type:"text",text:"also do this"},{type:"tool_result",tool_use_id:("t_a-"+($u|ltrimstr("u-"))),content:"ok"}]}}'
  } >> "$tr_transcript"
done
gate_run "$sid" "$tr_transcript" "$PROJ" ""
assert_outcome "no-user-messages-toolresult" SKIP
assert_log "no-user-messages-toolresult" "SKIP: delta has no top-level user messages"
assert_log "no-user-messages-toolresult" "user_messages=0"
pass "text-sharing-tool-result-is-not-top-level"

# Same shape with the tool_result moved to its own entry: now the text block is
# top-level and the hook triggers.
sid=$(new_sid)
tl_transcript="$TMPROOT/toplevel-text.jsonl"
: > "$tl_transcript"
for i in 1 2 3; do
  {
    jq -nc --arg u "a-$i" \
      '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"editing"},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:"a",new_string:"b"}}]}}'
    jq -nc --arg u "r-$i" \
      '{type:"user",uuid:$u,message:{content:[{type:"tool_result",tool_use_id:"t_a-1",content:"ok"}]}}'
    jq -nc --arg u "u-$i" \
      '{type:"user",uuid:$u,message:{content:[{type:"text",text:"also do this"}]}}'
  } >> "$tl_transcript"
done
gate_run "$sid" "$tl_transcript" "$PROJ" ""
assert_outcome "top-level-text" BLOCK
assert_log "top-level-text" "user_messages=3"
pass "text-block-alone-is-top-level"

# Zero user entries at all.
sid=$(new_sid)
nu_transcript="$TMPROOT/nouser.jsonl"
: > "$nu_transcript"
for i in 1 2 3; do
  jq -nc --arg u "a-$i" \
    '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:"editing"},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:"a",new_string:"b"}}]}}' \
    >> "$nu_transcript"
done
gate_run "$sid" "$nu_transcript" "$PROJ" ""
assert_outcome "no-user-messages" SKIP
assert_log "no-user-messages" "SKIP: delta has no top-level user messages"
pass "zero-user-messages-skips"

# ===========================================================================
# edit tools and touched files
# ===========================================================================

sid=$(new_sid)
me_transcript="$TMPROOT/multiedit.jsonl"
mk_edit_transcript "$me_transcript" MultiEdit file_path "$PROJ/src/multi.js"
gate_run "$sid" "$me_transcript" "$PROJ" ""
assert_outcome "multiedit" BLOCK
assert_log "multiedit" "edits=3"
assert_out "multiedit" "Files touched this slice: src/multi.js"
pass "multiedit-counts-as-edit"

sid=$(new_sid)
nb_transcript="$TMPROOT/notebook.jsonl"
mk_edit_transcript "$nb_transcript" NotebookEdit notebook_path "$PROJ/nb/run.ipynb"
gate_run "$sid" "$nb_transcript" "$PROJ" ""
assert_outcome "notebookedit" BLOCK
assert_log "notebookedit" "edits=3"
assert_out "notebookedit" "Files touched this slice: nb/run.ipynb"
pass "notebookedit-notebook-path-counts-as-edit"

# An edited_text_file attachment is the user editing a file by hand. It is not a
# tool use, so it adds to the touched list without moving the edit count.
sid=$(new_sid)
att_transcript="$TMPROOT/attachment.jsonl"
mk_edit_transcript "$att_transcript" Edit file_path "$PROJ/src/tool.js"
jq -nc --arg f "$PROJ/src/by-hand.txt" \
  '{type:"attachment",uuid:"att-1",attachment:{type:"edited_text_file",filename:$f}}' >> "$att_transcript"
gate_run "$sid" "$att_transcript" "$PROJ" ""
assert_outcome "edited-text-file" BLOCK
assert_out "edited-text-file" "src/tool.js"
assert_out "edited-text-file" "src/by-hand.txt"
pass "edited-text-file-attachment-adds-touched-file"

# Paths under the hook cwd are relativised; paths outside it stay absolute.
sid=$(new_sid)
rel_transcript="$TMPROOT/relative.jsonl"
mk_edit_transcript "$rel_transcript" Edit file_path "$PROJ/deep/nested/app.js"
gate_run "$sid" "$rel_transcript" "$PROJ" ""
assert_outcome "touched-relative" BLOCK
assert_out "touched-relative" "Files touched this slice: deep/nested/app.js"
refute_out "touched-relative" "Files touched this slice: $PROJ"
pass "touched-paths-relative-to-cwd"

sid=$(new_sid)
out_transcript="$TMPROOT/outside.jsonl"
mk_edit_transcript "$out_transcript" Edit file_path "/etc/elsewhere.conf"
gate_run "$sid" "$out_transcript" "$PROJ" ""
assert_outcome "touched-outside" BLOCK
assert_out "touched-outside" "Files touched this slice: /etc/elsewhere.conf"
pass "touched-paths-outside-cwd-stay-absolute"

# A newline in a path would break the one-line-per-field prompt.
sid=$(new_sid)
nl_transcript="$TMPROOT/newline.jsonl"
mk_edit_transcript "$nl_transcript" Edit file_path "$PROJ/we
ird.js"
gate_run "$sid" "$nl_transcript" "$PROJ" ""
assert_outcome "touched-newline" BLOCK
assert_out "touched-newline" "Files touched this slice: weird.js"
pass "touched-paths-strip-newlines"

# ===========================================================================
# include_rules
# ===========================================================================

rulesproj="$TMPROOT/rulesproj"
mkdir -p "$rulesproj/.git" "$rulesproj/.claude/rules" "$GHOME/.claude/rules"

sid=$(new_sid)
printf 'project root rules\n' > "$rulesproj/CLAUDE.md"
printf 'project extra rules\n' > "$rulesproj/.claude/rules/zzz-project.md"
printf 'global rules\n' > "$GHOME/.claude/CLAUDE.md"
printf 'global extra rules\n' > "$GHOME/.claude/rules/aaa-global.md"
gate_run "$sid" "$sr_transcript" "$rulesproj" ""
assert_outcome "rules-order" BLOCK
assert_out "rules-order" "User instruction files: "
rules_line=$(printf '%s' "$STOP_OUT" | jq -r '.reason' | grep -o 'User instruction files: .*' | head -1)
[ -n "$rules_line" ] || fail "rules-order" "no rules line in prompt"
# Project files must all precede global ones, even though the global rule sorts
# first by filename.
proj_last=$(awk -v s="$rules_line" -v p="$rulesproj" 'BEGIN{n=split(s,a,", "); for(i=1;i<=n;i++) if(index(a[i],p)) last=i; print last+0}')
glob_first=$(awk -v s="$rules_line" -v g="$GHOME" 'BEGIN{n=split(s,a,", "); for(i=n;i>=1;i--) if(index(a[i],g)) first=i; print first+0}')
[ "$proj_last" -gt 0 ] || fail "rules-order" "no project file in: $rules_line"
[ "$glob_first" -gt 0 ] || fail "rules-order" "no global file in: $rules_line"
[ "$proj_last" -lt "$glob_first" ] || fail "rules-order" "project files not before global: $rules_line"
pass "rules-project-files-before-global"

# Over 8 KB: skipped and the reason logged.
sid=$(new_sid)
head -c 9000 /dev/zero | tr '\0' 'x' > "$rulesproj/.claude/rules/big.md"
gate_run "$sid" "$sr_transcript" "$rulesproj" ""
assert_outcome "rules-8kb" BLOCK
assert_log "rules-8kb" "RULES: skipped $rulesproj/.claude/rules/big.md (9000B, over 8KB)"
refute_out "rules-8kb" "big.md"
pass "rules-over-8kb-skipped-and-logged"
rm -f "$rulesproj/.claude/rules/big.md"

# 16 KB total cap: two 7000B project files fit (14000B); the next 7000B file
# would exceed the cap and is skipped, but a later small file still fits - the
# cap skips individual files rather than stopping at the first overflow.
sid=$(new_sid)
head -c 7000 /dev/zero | tr '\0' 'a' > "$rulesproj/CLAUDE.md"
head -c 7000 /dev/zero | tr '\0' 'b' > "$rulesproj/.claude/rules/zzz-project.md"
head -c 7000 /dev/zero | tr '\0' 'c' > "$GHOME/.claude/CLAUDE.md"
printf 'small global rule\n' > "$GHOME/.claude/rules/aaa-global.md"
gate_run "$sid" "$sr_transcript" "$rulesproj" ""
assert_outcome "rules-cap" BLOCK
assert_log "rules-cap" "RULES: skipped $GHOME/.claude/CLAUDE.md (7000B, total cap)"
assert_out "rules-cap" "aaa-global.md"
pass "rules-16kb-total-cap"

# Opt-out sends nothing at all.
sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$rulesproj" "" CLAUDE_WATCHDOG_INCLUDE_RULES=0
assert_outcome "rules-off" BLOCK
refute_out "rules-off" "User instruction files:"
pass "include-rules-0-sends-none"

# ===========================================================================
# Previous analysis
# ===========================================================================

sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$PROJ" ""
assert_outcome "prev-analysis-absent" BLOCK
refute_out "prev-analysis-absent" "Previous analysis"
pass "no-previous-analysis-line-when-none-exists"

sid=$(new_sid)
: > "$GANALYSES/${sid}-20260101T000000Z.md"
: > "$GANALYSES/${sid}-20260615T120000Z.md"
: > "$GANALYSES/${sid}-20260302T000000Z.md"
: > "$GANALYSES/other-session-20261231T000000Z.md"
gate_run "$sid" "$sr_transcript" "$PROJ" ""
assert_outcome "prev-analysis" BLOCK
assert_out "prev-analysis" "Previous analysis (optional context, read only if useful): $GANALYSES/${sid}-20260615T120000Z.md"
refute_out "prev-analysis" "20260302T000000Z"
pass "previous-analysis-points-at-newest"
rm -f "$GANALYSES/${sid}-"*.md "$GANALYSES/other-session-"*.md

# ===========================================================================
# interactive_recommendations
# ===========================================================================

sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$PROJ" ""
assert_outcome "interactive-off" BLOCK
assert_out "interactive-off" "Present the analysis to the user, then stop."
refute_out "interactive-off" "AskUserQuestion"
refute_out "interactive-off" "watchdog-todo.md"
pass "interactive-recommendations-off-by-default"

sid=$(new_sid)
gate_run "$sid" "$sr_transcript" "$PROJ" "" CLAUDE_WATCHDOG_INTERACTIVE_RECOMMENDATIONS=1
assert_outcome "interactive-on" BLOCK
assert_out "interactive-on" "Present the full analysis to the user."
assert_out "interactive-on" "AskUserQuestion"
assert_out "interactive-on" "$PROJ/.claude/watchdog-todo.md"
refute_out "interactive-on" "Present the analysis to the user, then stop."
pass "interactive-recommendations-switches-block-and-todo-path"

# ===========================================================================
# Legacy exit-2 mode
# ===========================================================================

sid=$(new_sid)
: > "$GLOG"
legacy_err="$TMPROOT/legacy.err"
legacy_rc=0
legacy_out=$(printf '%s' "$(stop_payload "$sid" "$sr_transcript" "$PROJ")" | env \
  HOME="$GHOME" CLAUDE_WATCHDOG_LOG="$GLOG" CLAUDE_WATCHDOG_TMP="$GTMP" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_MIN_TOOL_USES=3 \
  CLAUDE_WATCHDOG_LEGACY_HOOK=true \
  "${HOOK_STOP_CMD[@]}" 2>"$legacy_err") || legacy_rc=$?
[ "$legacy_rc" -eq 2 ] || { cat "$GLOG" >&2; fail "legacy-exit2" "expected exit 2, got $legacy_rc"; }
[ -z "$legacy_out" ] || fail "legacy-exit2" "expected empty stdout, got: $legacy_out"
grep -q 'Please spawn a session-analyzer agent' "$legacy_err" || fail "legacy-exit2" "instruction not on stderr"
grep -q '"decision"' "$legacy_err" && fail "legacy-exit2" "stderr should carry the bare instruction, not JSON"
assert_log "legacy-exit2" "TRIGGER: injecting session-analyzer subagent request (mode=exit2)"
pass "legacy-exit2-instruction-on-stderr"

# ===========================================================================
# stdin handling
# ===========================================================================

garbage_rc=0
garbage_out=$(printf 'this is not json at all' | env \
  HOME="$GHOME" CLAUDE_WATCHDOG_LOG="$GLOG" CLAUDE_WATCHDOG_TMP="$GTMP" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" \
  "${HOOK_STOP_CMD[@]}" 2>/dev/null) || garbage_rc=$?
[ "$garbage_rc" -eq 0 ] || fail "garbage-stdin" "expected exit 0, got $garbage_rc"
[ -z "$garbage_out" ] || fail "garbage-stdin" "expected no stdout, got: $garbage_out"
pass "garbage-stdin-fails-open"

empty_rc=0
empty_out=$(printf '' | env \
  HOME="$GHOME" CLAUDE_WATCHDOG_LOG="$GLOG" CLAUDE_WATCHDOG_TMP="$GTMP" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" \
  "${HOOK_STOP_CMD[@]}" 2>/dev/null) || empty_rc=$?
[ "$empty_rc" -eq 0 ] || fail "empty-stdin" "expected exit 0, got $empty_rc"
[ -z "$empty_out" ] || fail "empty-stdin" "expected no stdout, got: $empty_out"
pass "empty-stdin-fails-open"

# Past 64 KB the input is cut mid-JSON, so it can no longer parse. The hook must
# fail open rather than crash or half-act on a truncated event.
sid=$(new_sid)
: > "$GLOG"
big_rc=0
big_out=$(jq -nc --arg sid "$sid" --arg tp "$sr_transcript" --arg cwd "$PROJ" \
  --arg pad "$(head -c 70000 /dev/zero | tr '\0' 'p')" \
  '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", padding:$pad}' | env \
  HOME="$GHOME" CLAUDE_WATCHDOG_LOG="$GLOG" CLAUDE_WATCHDOG_TMP="$GTMP" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$GANALYSES" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_MIN_TOOL_USES=3 \
  "${HOOK_STOP_CMD[@]}" 2>/dev/null) || big_rc=$?
[ "$big_rc" -eq 0 ] || fail "stdin-cap" "expected exit 0, got $big_rc"
[ -z "$big_out" ] || fail "stdin-cap" "oversized stdin must not trigger, got: $big_out"
assert_log "stdin-cap" "ERROR: unexpected failure"
pass "stdin-64kb-cap-fails-open"

# ===========================================================================
# Empty condensed transcript
# ===========================================================================

# The empty-input case, through the documented condense CLI.
empty_jsonl="$TMPROOT/empty.jsonl"
: > "$empty_jsonl"
[ -z "$(run_condense condense "$empty_jsonl" 4096 | tr -d '\n')" ] \
  || fail "empty-condensed-cli" "empty transcript should condense to nothing"
pass "empty-transcript-condenses-to-nothing"

# Through the hook the guard is unreachable: reaching it requires edits > 0 and
# at least one top-level user message, and every entry that satisfies those
# emits a line. The smallest qualifying delta still produces content, so the
# guard never fires. See the summary note on the dead branch.
sid=$(new_sid)
min_transcript="$TMPROOT/minimal.jsonl"
: > "$min_transcript"
{
  jq -nc '{type:"user",uuid:"u-1",message:{content:"go"}}'
  jq -nc '{type:"assistant",uuid:"a-1",message:{content:[{type:"tool_use",id:"t_1",name:"Edit",input:{file_path:"/tmp/x"}}]}}'
} >> "$min_transcript"
gate_run "$sid" "$min_transcript" "$PROJ" "" CLAUDE_WATCHDOG_MIN_TOOL_USES=1
assert_outcome "empty-condensed-unreachable" BLOCK
grep -q "SKIP: condensed transcript is empty" "$GLOG" && fail "empty-condensed-unreachable" "guard fired unexpectedly"
[ -s "$GSESSIONS/condensed-${sid}.txt" ] || fail "empty-condensed-unreachable" "condensed file is empty"
pass "minimal-delta-never-condenses-to-empty"

# ===========================================================================
# Multi-byte UTF-8 at the truncation boundary
# ===========================================================================

# assert_utf8_clean <label> <file> - the file must be valid UTF-8 and free of
# U+FFFD, which is what a cut through a multi-byte sequence leaves behind.
# jq reads bytes and emits U+FFFD for anything that is not valid UTF-8, so one
# grep over the round-trip catches both an invalid sequence and a literal
# replacement character. (BSD iconv is not usable here: it errors on input with
# no trailing newline regardless of encoding.)
assert_utf8_clean() {
  local label="$1" f="$2"
  [ -f "$f" ] || fail "$label" "$f does not exist"
  if jq -Rs . < "$f" | LC_ALL=C grep -q $'\xef\xbf\xbd'; then
    fail "$label" "$f is invalid UTF-8 or contains U+FFFD - a character was split"
  fi
}

# Assistant text is dense 3-byte Japanese, so the byte budget lands inside a
# character for most budgets rather than by luck. Sweeping a range of budgets
# guarantees at least one cut straddles a character.
utf8_transcript="$TMPROOT/utf8.jsonl"
jp=$(jq -rn '"日本語テキスト" * 40')
: > "$utf8_transcript"
for i in 1 2 3 4 5; do
  {
    jq -nc --arg u "u-$i" --arg t "ユーザー $i $jp" \
      '{type:"user",uuid:$u,message:{content:$t}}'
    jq -nc --arg u "a-$i" --arg t "アシスタント $i $jp" \
      '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:$t},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/日本.txt",old_string:"あ",new_string:"い"}}]}}'
  } >> "$utf8_transcript"
done

for budget in 500 501 502 503 504 505 506 507 508 509 510 700 1024 2048; do
  sid=$(new_sid)
  gate_run "$sid" "$utf8_transcript" "$PROJ" "" CLAUDE_WATCHDOG_MAX_BYTES="$budget"
  assert_outcome "utf8-budget-$budget" BLOCK
  cfile="$GSESSIONS/condensed-${sid}.txt"
  grep -q '\[TRUNCATED\]' "$cfile" || fail "utf8-budget-$budget" "budget $budget did not truncate"
  assert_utf8_clean "utf8-budget-$budget" "$cfile"
done
pass "utf8-truncation-never-splits-a-character"

# The touched-file list and the prompt itself carry the same content.
sid=$(new_sid)
gate_run "$sid" "$utf8_transcript" "$PROJ" "" CLAUDE_WATCHDOG_MAX_BYTES=600
assert_outcome "utf8-prompt" BLOCK
printf '%s' "$STOP_OUT" > "$TMPROOT/utf8-stdout.json"
assert_utf8_clean "utf8-prompt" "$TMPROOT/utf8-stdout.json"
pass "utf8-prompt-output-is-valid-utf8"

# Per-tool-result caps truncate by character count, not bytes. An astral
# character (surrogate pair) sitting on that boundary must not be halved.
sid=$(new_sid)
astral_transcript="$TMPROOT/astral.jsonl"
# A leading ASCII char puts the astral characters on odd UTF-16 offsets, so a
# code-unit slice at the 500-char tool_result cap lands mid-surrogate-pair.
emoji=$(jq -rn '"x" + ("\ud83d\ude00" * 600)')
: > "$astral_transcript"
for i in 1 2 3; do
  {
    jq -nc --arg u "u-$i" --arg t "user $i" \
      '{type:"user",uuid:$u,message:{content:$t}}'
    jq -nc --arg u "a-$i" --arg e "$emoji" \
      '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:$e},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:$e,new_string:"b"}}]}}'
    jq -nc --arg u "r-$i" --arg e "$emoji" \
      '{type:"user",uuid:$u,message:{content:[{type:"tool_result",tool_use_id:("t_a-"+($u|ltrimstr("r-"))),content:$e}]}}'
  } >> "$astral_transcript"
done
gate_run "$sid" "$astral_transcript" "$PROJ" "" CLAUDE_WATCHDOG_MAX_BYTES=1000000
assert_outcome "astral" BLOCK
assert_utf8_clean "astral" "$GSESSIONS/condensed-${sid}.txt"
pass "astral-characters-survive-per-tool-caps"

# ===========================================================================
# CRLF transcripts
# ===========================================================================

sid=$(new_sid)
crlf_transcript="$TMPROOT/crlf.jsonl"
mk_transcript "$TMPROOT/crlf-lf.jsonl" 1 3 CRLF
sed 's/$/\r/' "$TMPROOT/crlf-lf.jsonl" > "$crlf_transcript"
LC_ALL=C grep -q $'\r' "$crlf_transcript" || fail "crlf" "fixture is not CRLF"
gate_run "$sid" "$crlf_transcript" "$PROJ" ""
assert_outcome "crlf" BLOCK
assert_log "crlf" "edits=3"
assert_log "crlf" "user_messages=3"
cfile="$GSESSIONS/condensed-${sid}.txt"
grep -q 'CRLF user 1' "$cfile" || fail "crlf" "user content missing from condensed output"
grep -q 'CRLF assistant 3' "$cfile" || fail "crlf" "assistant content missing from condensed output"
LC_ALL=C grep -q $'\r' "$cfile" && fail "crlf" "carriage returns leaked into the condensed transcript"
pass "crlf-transcript-parses-and-condenses-cleanly"

# The cursor must still advance to a clean uuid, not one with a trailing \r.
cursor_uuid=$(sed -n '1p' "$GSESSIONS/cursor-${sid}.txt")
[ "$cursor_uuid" = "a-CRLF-3" ] || fail "crlf-cursor" "expected a-CRLF-3, got '$cursor_uuid'"
pass "crlf-cursor-uuid-has-no-carriage-return"

echo "--- all gate tests passed ---"
