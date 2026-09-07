#!/usr/bin/env bash
# Every transcript label the condenser emits must be documented in the analyzer
# prompt, and the prompt assembly must hand the analyzer the final assistant
# message. The label list lives in tests/labels.txt - see the header there.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

prompt="agents/session-analyzer.md"
labels=$(sed 's/[[:space:]]*$//' tests/labels.txt | grep -v '^#' | grep -v '^$')
[ "$(echo "$labels" | wc -l)" -ge 8 ] || { echo "FAIL: tests/labels.txt lists too few labels:"; echo "$labels"; exit 1; }
rc=0
while IFS= read -r label; do
  if grep -qF -- "$label" "$prompt"; then echo "PASS: $label"; else echo "FAIL: $label missing from $prompt" >&2; rc=1; fi
done <<< "$labels"

# --- The condensed file the hook writes must end with the final assistant message ---
# The delta ends on tool results, so without this the analyzer is asked to judge
# whether the deliverable was produced while never being shown it.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
HEADER='=== FINAL ASSISTANT MESSAGE (session ended here) ==='
FINAL_TEXT='Renamed the stack components to bre-remote-cache and pushed the branch.'

run_hook() { # run_hook <session-id> <payload-json> -> echoes condensed file path
  local sid="$1" payload="$2" tmp="$TMPROOT/w-$1"
  run_stop "$payload" CLAUDE_WATCHDOG_LOG="$TMPROOT/hook-$sid.log" CLAUDE_WATCHDOG_TMP="$tmp" \
    CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
    CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
  echo "$tmp/sessions/condensed-${sid}.txt"
}

sid="final-msg-$$"
cwd="$TMPROOT/project"; mkdir -p "$cwd"
payload=$(jq -n --arg sid "$sid" --arg tp "$FIXTURE" --arg cwd "$cwd" --arg msg "$FINAL_TEXT" \
  '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", last_assistant_message:$msg}')
f=$(run_hook "$sid" "$payload")
[ -f "$f" ] || { cat "$TMPROOT/hook-$sid.log"; echo "FAIL: hook wrote no condensed file" >&2; rc=1; }
if [ -f "$f" ]; then
  grep -qF "$HEADER" "$f" || { echo "FAIL: condensed file missing the final-message header" >&2; rc=1; }
  grep -qF "$FINAL_TEXT" "$f" || { echo "FAIL: final assistant message not in condensed file" >&2; rc=1; }
  # must be the tail, after the tool traffic - not buried mid-transcript
  tail -3 "$f" | grep -qF "$FINAL_TEXT" || { tail -5 "$f"; echo "FAIL: final message is not at the end of the file" >&2; rc=1; }
  grep -qF "$HEADER" "$prompt" || { echo "FAIL: $HEADER undocumented in $prompt" >&2; rc=1; }
  if [ "$rc" = "0" ]; then echo "PASS: $HEADER"; fi
fi

# Absent from the event -> no empty header stanza.
sid2="final-msg-none-$$"
payload2=$(stop_payload "$sid2" "$FIXTURE" "$cwd")
f2=$(run_hook "$sid2" "$payload2")
if [ -f "$f2" ] && grep -qF "$HEADER" "$f2"; then
  echo "FAIL: header emitted with no last_assistant_message" >&2; rc=1
else
  echo "PASS: no final-message header when the event carries none"
fi

# Already flushed to the transcript -> appended copy would be a duplicate.
sid3="final-msg-dupe-$$"
ON_DISK='Renamed the stack components.'
payload3=$(jq -n --arg sid "$sid3" --arg tp "$FIXTURE" --arg cwd "$cwd" --arg msg "$ON_DISK" \
  '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", last_assistant_message:$msg}')
f3=$(run_hook "$sid3" "$payload3")
if [ ! -f "$f3" ]; then
  echo "FAIL: hook wrote no condensed file for the dedupe case" >&2; rc=1
elif grep -qF "$HEADER" "$f3"; then
  echo "FAIL: final message re-appended although it is already in the transcript" >&2; rc=1
elif [ "$(grep -cF "$ON_DISK" "$f3")" != "1" ]; then
  echo "FAIL: final message appears $(grep -cF "$ON_DISK" "$f3") times, expected 1" >&2; rc=1
else
  echo "PASS: no duplicate when the final message already reached the transcript"
fi

# --- Issue #34: Bash grant must not use an unsupported permission-rule pattern ---
skill="skills/analyze-session/SKILL.md"
check_no_bash_pattern() { # check_no_bash_pattern <file> <field>
  local file="$1" field="$2"
  local line; line=$(grep -m1 "^${field}:" "$file")
  if echo "$line" | grep -q 'Bash('; then
    echo "FAIL: $file $field grants Bash with a permission-rule pattern, which frontmatter does not honour: $line" >&2; rc=1
  elif ! echo "$line" | grep -qE '(^|, )Bash(,|$)'; then
    echo "FAIL: $file $field does not grant plain Bash: $line" >&2; rc=1
  else
    echo "PASS: $file $field grants plain Bash, no pattern"
  fi
}
check_no_bash_pattern "$prompt" "tools"
check_no_bash_pattern "$skill" "allowed-tools"

check_rule_present() { # check_rule_present <file> <needle> <description>
  if grep -qF "$2" "$1"; then echo "PASS: $1 has $3"; else echo "FAIL: $1 missing $3" >&2; rc=1; fi
}
for f in "$prompt" "$skill"; do
  check_rule_present "$f" "git show" "an explicit git show mention"
  check_rule_present "$f" 'MUST begin with `### Goals`' "the no-preamble rule"
  check_rule_present "$f" "delete the heading instead" "the conditional-section negative example"
  check_rule_present "$f" "Never use an em dash" "the em/en dash punctuation rule"
  check_rule_present "$f" 'Every heading is `###`' "the heading-level rule"
done

# --- Twin parity: the ## Output section must have the same headings, in the
# same order, in both files. Prose differs deliberately (transcript vs. live
# conversation wording); structure must not.
extract_headings() { sed -n '/^## Output$/,/^Rules:$/p' "$1" | grep -oE '^(###[^(]*|- [A-Za-z]+:)'; }
if diff -q <(extract_headings "$prompt") <(extract_headings "$skill") > /dev/null; then
  echo "PASS: agent and skill Output section structure is in step"
else
  diff <(extract_headings "$prompt") <(extract_headings "$skill") >&2
  echo "FAIL: agent and skill Output section structure has drifted" >&2; rc=1
fi

exit $rc
