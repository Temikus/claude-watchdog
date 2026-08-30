#!/usr/bin/env bash
# Transcript condensation: mid-turn user input, noise filtering, byte budget,
# project-root anchoring. Fixture is sanitised from a real session that lost four
# mid-turn user messages (see tests/fixtures/midturn-session.jsonl).
#
# Uses the condense debug CLI - a supported interface, see tests/CONDENSE-CLI.md.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

out="$TMPROOT/extracted.txt"
run_condense extract "$FIXTURE" > "$out"

# count_fixed <literal> -> number of lines containing it
count_fixed() { grep -cF "$1" "$out" || true; }

# --- Test 1: every mid-turn user message survives, labelled, exactly once ---
# These four are verbatim from the session that regressed. Each arrives in a
# different encoding: queue-operation + attachment, attachment only, and
# queue-operation 'remove' with no attachment.
# shellcheck disable=SC2016  # verbatim fixture text, backticks included
MIDTURN_MSGS=(
  'You can check ../base-infrastructure-for-services for any permission changes needed.'
  'Also - please base the changes on _recent_ additions, it looks like the GHA stuff is circa 2022.'
  'Can you please rename stack components to the more generic `bre-remote-cache`?'
  'Also - please compare to other BIFS services within the same repo'
)
for msg in "${MIDTURN_MSGS[@]}"; do
  n=$(count_fixed "$msg")
  [ "$n" = "1" ] || { cat "$out"; fail "midturn-present" "expected 1 line containing '$msg', got $n"; }
  grep -F "$msg" "$out" | grep -q "^USER (mid-turn): ${msg:0:12}" || { cat "$out"; fail "midturn-label" "'$msg' not labelled USER (mid-turn) from the start of the message"; }
done
pass "midturn-messages-extracted"

# --- Test 2: text interleaved with tool_result in one user entry is mid-turn ---
grep -qF 'USER (mid-turn): Hold on - use the leaner shape' "$out" || fail "midturn-array" "interleaved text block not labelled mid-turn"
pass "midturn-array-content"

# --- Test 3: system framing is recognised and stripped ---
grep -qxF 'USER (mid-turn): Skip the GHA workflow entirely.' "$out" || { cat "$out"; fail "midturn-framing" "framed message not unwrapped"; }
if grep -q 'sent a new message while you were working' "$out"; then fail "midturn-framing-strip" "framing text leaked into output"; fi
pass "midturn-framing-stripped"

# --- Test 4: non-human queued prompts are labelled, not passed off as user asks ---
grep -qF 'USER (mid-turn, origin=cron): Scheduled follow-up' "$out" || fail "midturn-origin" "cron-origin prompt not marked"
pass "midturn-origin-labelled"

# --- Test 5: a queued prompt that became its own turn appears once, not mid-turn ---
n=$(count_fixed "Merged 6272. Can you inspect the comments on 877?")
[ "$n" = "1" ] || fail "dequeued-once" "dequeued prompt should appear once, got $n"
grep -qxF 'USER: Merged 6272. Can you inspect the comments on 877?' "$out" || fail "dequeued-plain" "dequeued prompt should be a plain USER line"
pass "dequeued-prompt-not-duplicated"

# --- Test 6: manual file edits surface as user action ---
grep -qxF 'USER (edited file): /repo/MAINTENANCE.md' "$out" || fail "edited-file" "edited_text_file not surfaced"
if grep -q '# Maintenance' "$out"; then fail "edited-file-snippet" "edited_text_file snippet should not be inlined"; fi
pass "edited-file-surfaced"

# --- Test 7: bookkeeping entries no longer spend budget ---
for noise in 'last-prompt' 'custom-title' 'ai-title' 'pr-link' 'SYSTEM[mode]' 'task_reminder'; do
  if grep -qF "$noise" "$out"; then cat "$out"; fail "noise-dropped" "bookkeeping entry '$noise' still emitted"; fi
done
pass "bookkeeping-noise-dropped"

# --- Test 8: unknown entry types stay visible (a future user-bearing type must
# degrade to noisy, never to invisible) ---
grep -q 'SYSTEM\[totally-unknown-future-type\]' "$out" || fail "unknown-kept" "unknown entry type was dropped"
pass "unknown-type-retained"

# --- Test 9: tool_result lines carry the tool name, errors still flagged ---
grep -q '^TOOL_RESULT\[Bash\]: On branch feat/remote-cache$' "$out" || fail "tool-result-kept" "tool_result not condensed into a TOOL_RESULT[Bash] line"
# [ERROR] belongs in the label: a Bash/error body runs to 800 chars, so a suffix
# is read only after the content the call never actually produced.
grep -q '^TOOL_RESULT\[Edit\]\[ERROR\]: edit failed: file not found$' "$out" || fail "tool-result-error" "tool_result error flag lost or not in the label"
grep -q '^TOOL_RESULT: orphan result$' "$out" || fail "tool-result-unknown" "result with unknown tool_use_id should be unlabelled"
pass "tool-result-condensing-intact"

# --- Test 9b: per-tool result caps (payload 1000 chars; cap + label + marker) ---
# result_len <marker> -> length of the payload after the label
result_len() { grep -F "$1" "$out" | sed 's/^TOOL_RESULT[^:]*: //' | awk '{print length($0)}'; }
[ "$(result_len 'READCAP')" = "80" ] || fail "cap-read" "Read result should be capped at 80, got $(result_len 'READCAP')"
[ "$(result_len 'BASHCAP')" = "800" ] || fail "cap-bash" "Bash result should be capped at 800, got $(result_len 'BASHCAP')"
[ "$(result_len 'WRITECAP')" = "500" ] || fail "cap-default" "Write result should be capped at 500, got $(result_len 'WRITECAP')"
[ "$(result_len 'WRITEERR')" = "800" ] || fail "cap-error" "is_error result should be capped at 800, got $(result_len 'WRITEERR')"
[ "$(result_len 'MCPCAP')" = "500" ] || fail "cap-mcp" "mcp__fs__Read must not get the Read cap, got $(result_len 'MCPCAP')"
grep -q '^TOOL_RESULT\[Write\]\[ERROR\]: WRITEERR ' "$out" || fail "cap-error-label" "error result lost its [Name] label or [ERROR] marker"
pass "tool-result-per-tool-caps"

# --- Test 10: under the byte budget, mid-turn lines survive tool-call flood ---
# Mirrors the real session's shape: ~400KB of tool traffic, a few KB of user text,
# 50KB budget. Mid-turn lines must land in the protected user bucket.
flood="$TMPROOT/flood.jsonl"
cat "$FIXTURE" > "$flood"
for i in $(seq 1 400); do
  jq -nc --arg i "$i" '{type:"assistant",uuid:("a-f"+$i),message:{content:[{type:"tool_use",id:("tf_"+$i),name:"Read",input:{file_path:("/repo/file-"+$i+".tf"),padding:"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}]}}' >> "$flood"
  jq -nc --arg i "$i" '{type:"user",uuid:("u-f"+$i),message:{content:[{type:"tool_result",tool_use_id:("tf_"+$i),content:("resource block "+$i+" xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")}]}}' >> "$flood"
done
budgeted="$TMPROOT/budgeted.txt"
run_condense condense "$flood" 51200 > "$budgeted"
raw_bytes=$(run_condense extract "$flood" | wc -c | tr -d ' ')
[ "$raw_bytes" -gt 51200 ] || fail "budget-precondition" "flood transcript ($raw_bytes B) did not exceed the budget"
[ "$(wc -c < "$budgeted" | tr -d ' ')" -le 52400 ] || fail "budget-respected" "condensed output exceeded the budget"
midturn=$(grep -c '^USER (mid-turn' "$budgeted" || true)
[ "$midturn" = "7" ] || fail "budget-midturn" "expected all 7 mid-turn lines to survive truncation, got $midturn"
grep -qF 'You can check ../base-infrastructure-for-services' "$budgeted" || fail "budget-midturn-text" "mid-turn text dropped by truncation"
pass "midturn-survives-byte-budget"

# --- Test 11: when user text alone busts its budget, both ends are kept ---
# The old head-only slice dropped the most recent asks - exactly where mid-turn
# corrections live.
many="$TMPROOT/many-users.jsonl"
: > "$many"
for i in $(seq 1 300); do
  jq -nc --arg i "$i" '{type:"user",uuid:("u-m"+$i),message:{content:("ask number "+$i+" - xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")}}' >> "$many"
  jq -nc --arg i "$i" '{type:"assistant",uuid:("a-m"+$i),message:{content:[{type:"tool_use",id:("tm_"+$i),name:"Read",input:{file_path:("/repo/f"+$i)}}]}}' >> "$many"
done
clamped="$TMPROOT/clamped.txt"
run_condense condense "$many" 8192 > "$clamped"
grep -q 'elided' "$clamped" || { head -5 "$clamped"; fail "clamp-marker" "expected an elision marker"; }
# The truncation notice must reach the analyzer with verbose off (the default),
# or a truncated transcript reads as a session that ended early.
grep -q '^\[TRUNCATED\]' "$clamped" || { head -3 "$clamped"; fail "clamp-notice" "no [TRUNCATED] notice without verbose mode"; }
grep -q '^USER: ask number 1 - ' "$clamped" || fail "clamp-head" "first user message (session goal) dropped"
grep -q '^USER: ask number 300 - ' "$clamped" || fail "clamp-tail" "last user message dropped - head-only slice regressed"
pass "user-clamp-keeps-both-ends"

# --- Test 12: end-to-end through the Stop hook ---
e2e_sid="condense-e2e-$$"
e2e_tmp="$TMPROOT/wtmp"
e2e_cwd="$TMPROOT/e2e-project"
mkdir -p "$e2e_cwd"
run_stop "$(stop_payload "$e2e_sid" "$FIXTURE" "$e2e_cwd")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/hook.log" CLAUDE_WATCHDOG_TMP="$e2e_tmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_VERBOSE=1
echo "$STOP_OUT" | grep -q '"decision":"block"' || { cat "$TMPROOT/hook.log"; fail "e2e-trigger" "hook did not trigger"; }
e2e_file="$e2e_tmp/sessions/condensed-${e2e_sid}.txt"
[ -f "$e2e_file" ] || fail "e2e-file" "condensed file not written"
grep -qF 'USER (mid-turn): You can check ../base-infrastructure-for-services' "$e2e_file" || { cat "$e2e_file"; fail "e2e-midturn" "mid-turn message missing from hook output"; }
grep -q 'mid_turn_messages=7' "$e2e_file" || { head -2 "$e2e_file"; fail "e2e-diagnostics" "verbose diagnostics missing the mid-turn count"; }
pass "end-to-end-hook-output"

# --- Test 13: local storage anchors to the project root, not the shell cwd ---
# A turn ending with the shell inside a subdirectory used to scatter transcripts
# into <repo>/<subdir>/.claude/tmp.
anchor_sid="condense-anchor-$$"
repo="$TMPROOT/fake-repo"
deep="$repo/services/remote-cache"
mkdir -p "$deep" "$repo/.git"
run_stop "$(stop_payload "$anchor_sid" "$FIXTURE" "$deep")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/anchor.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/atmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
[ -f "$repo/.claude/tmp/claude-watchdog/sessions/condensed-${anchor_sid}.txt" ] || { cat "$TMPROOT/anchor.log"; fail "anchor-root" "condensed not written to the project root"; }
[ ! -d "$deep/.claude" ] || fail "anchor-subdir" "hook created .claude inside the subdirectory"
grep -q "LOCAL_STORAGE: anchored to project root" "$TMPROOT/anchor.log" || fail "anchor-log" "no anchoring log line"
pass "local-storage-anchors-to-project-root"

# --- Test 14: a stray .claude in a subdirectory does not re-anchor there ---
# The old bug left one behind; .git must still win, or the fix perpetuates it.
stray_sid="condense-stray-$$"
mkdir -p "$deep/.claude/tmp/claude-watchdog/sessions"
run_stop "$(stop_payload "$stray_sid" "$FIXTURE" "$deep")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/stray.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/stmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
[ -f "$repo/.claude/tmp/claude-watchdog/sessions/condensed-${stray_sid}.txt" ] || { cat "$TMPROOT/stray.log"; fail "stray-claude-root" "did not anchor to the git root"; }
[ ! -f "$deep/.claude/tmp/claude-watchdog/sessions/condensed-${stray_sid}.txt" ] || fail "stray-claude-subdir" "re-anchored to the stray .claude directory"
pass "stray-claude-dir-does-not-win-over-git"

# --- Test 15: no .git, but a .claude marker -> anchor there ---
nogit_sid="condense-nogit-$$"
nogit="$TMPROOT/no-git-project"
mkdir -p "$nogit/.claude" "$nogit/nested/dir"
run_stop "$(stop_payload "$nogit_sid" "$FIXTURE" "$nogit/nested/dir")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/nogit.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/ntmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
[ -f "$nogit/.claude/tmp/claude-watchdog/sessions/condensed-${nogit_sid}.txt" ] || { cat "$TMPROOT/nogit.log"; fail "nogit-claude" "did not anchor to the .claude marker"; }
pass "claude-marker-anchors-when-no-git"

# --- Test 16: no project marker -> cwd is used, as before ---
plain_sid="condense-plain-$$"
plain="$TMPROOT/no-markers/work"
mkdir -p "$plain"
run_stop "$(stop_payload "$plain_sid" "$FIXTURE" "$plain")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/plain.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/ptmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
[ -f "$plain/.claude/tmp/claude-watchdog/sessions/condensed-${plain_sid}.txt" ] || { cat "$TMPROOT/plain.log"; fail "no-marker-cwd" "condensed not written under the cwd"; }
pass "no-marker-falls-back-to-cwd"

echo "--- all condense tests passed ---"
