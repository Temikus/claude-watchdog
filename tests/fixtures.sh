#!/usr/bin/env bash
# Fixtures: event capture (CLAUDE_WATCHDOG_DUMP_EVENTS), the sanitiser, the
# reconstructed event payloads, and the extra transcript entry types.
#
# Section 4 of design/rewrite-readiness.md. Everything here goes through the
# HOOK_* indirection in tests/lib.sh, so it runs unchanged against a port.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

EVENTS_DIR="tests/fixtures/events"

# A transcript fat enough to clear the Stop hook's gates, for the dump tests.
big_enough="$TMPROOT/session.jsonl"
mk_transcript "$big_enough" 1 8 "dump"

# =============================================================================
# 1. CLAUDE_WATCHDOG_DUMP_EVENTS
# =============================================================================

# --- unset: nothing is written, anywhere ------------------------------------
unset_dir="$TMPROOT/dump-unset"
mkdir -p "$unset_dir"
sid_a="fixdump-off-$$"
run_stop "$(stop_payload "$sid_a" "$big_enough" "$TMPROOT")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/a.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/atmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
outcome_off=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$outcome_off" = "BLOCK" ] || fail "dump-unset-baseline" "expected BLOCK, got $outcome_off"
[ -z "$(ls -A "$unset_dir")" ] || fail "dump-unset" "files written with CLAUDE_WATCHDOG_DUMP_EVENTS unset"
pass "dump-off-by-default"

# --- set: the raw stdin of each hook lands in the directory, byte for byte ---
dump_dir="$TMPROOT/dump-on"
sid_b="fixdump-on-$$"
payload_b=$(stop_payload "$sid_b" "$big_enough" "$TMPROOT")
run_stop "$payload_b" \
  CLAUDE_WATCHDOG_DUMP_EVENTS="$dump_dir" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/b.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/btmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
outcome_on=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$outcome_on" = "$outcome_off" ] || fail "dump-no-behaviour-change" "outcome changed with dumping on: $outcome_off -> $outcome_on"

stop_dumps=("$dump_dir"/stop-*.json)
[ "${#stop_dumps[@]}" -eq 1 ] || fail "dump-stop-count" "expected 1 stop dump, got ${#stop_dumps[@]}"
diff <(printf '%s' "$payload_b") "${stop_dumps[0]}" > /dev/null \
  || fail "dump-stop-bytes" "dumped file is not the raw stdin"
pass "dump-stop-writes-raw-stdin"

payload_hold=$(event_fixture prompt-submit "{session_id:\"fixdump-hold-$$\"}")
run_hold "$payload_hold" CLAUDE_WATCHDOG_DUMP_EVENTS="$dump_dir" \
  CLAUDE_WATCHDOG_HOLD_INPUT=1 CLAUDE_WATCHDOG_TMP="$TMPROOT/htmp" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/b.log"
[ "$HOLD_RC" -eq 0 ] || fail "dump-hold-rc" "hold hook exited $HOLD_RC"
hold_dumps=("$dump_dir"/prompt-submit-*.json)
[ "${#hold_dumps[@]}" -eq 1 ] || fail "dump-hold-count" "expected 1 prompt-submit dump, got ${#hold_dumps[@]}"
diff <(printf '%s' "$payload_hold") "${hold_dumps[0]}" > /dev/null \
  || fail "dump-hold-bytes" "dumped file is not the raw stdin"
pass "dump-prompt-submit-writes-raw-stdin"

payload_sub=$(event_fixture subagent-stop "{session_id:\"fixdump-sub-$$\"}")
run_persist "$payload_sub" CLAUDE_WATCHDOG_DUMP_EVENTS="$dump_dir" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_TMP="$TMPROOT/ptmp" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/b.log"
[ "$PERSIST_RC" -eq 0 ] || fail "dump-persist-rc" "persist hook exited $PERSIST_RC"
sub_dumps=("$dump_dir"/subagent-stop-*.json)
[ "${#sub_dumps[@]}" -eq 1 ] || fail "dump-persist-count" "expected 1 subagent-stop dump, got ${#sub_dumps[@]}"
diff <(printf '%s' "$payload_sub") "${sub_dumps[0]}" > /dev/null \
  || fail "dump-persist-bytes" "dumped file is not the raw stdin"
pass "dump-subagent-stop-writes-raw-stdin"

# --- two invocations, two files: names must not collide ----------------------
run_stop "$(stop_payload "fixdump-on2-$$" "$big_enough" "$TMPROOT")" \
  CLAUDE_WATCHDOG_DUMP_EVENTS="$dump_dir" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/b.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/btmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
stop_dumps=("$dump_dir"/stop-*.json)
[ "${#stop_dumps[@]}" -eq 2 ] || fail "dump-unique-names" "second invocation did not add a file (${#stop_dumps[@]} present)"
pass "dump-names-are-unique-per-invocation"

# --- unwritable directory: fail open ----------------------------------------
blocked="$TMPROOT/blocked"
mkdir -p "$blocked"
chmod 500 "$blocked"
sid_c="fixdump-ro-$$"
run_stop "$(stop_payload "$sid_c" "$big_enough" "$TMPROOT")" \
  CLAUDE_WATCHDOG_DUMP_EVENTS="$blocked/nested" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/c.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/ctmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
chmod 700 "$blocked"
oc=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$oc" = "BLOCK" ] || { cat "$TMPROOT/c.log"; fail "dump-fail-open" "expected BLOCK with an unwritable dump dir, got $oc"; }
pass "dump-fails-open-on-unwritable-dir"

# =============================================================================
# 2. just fixture-sanitise
# =============================================================================

seed_secrets() {
  jq -n --arg h "$HOME" --arg u "${USER:-nobody}" --arg host "$(hostname)" '{
    session_id: "3f2a1b7c-9d4e-4f01-8a23-556677889900",
    transcript_path: ($h + "/.claude/projects/-repo/3f2a1b7c-9d4e-4f01-8a23-556677889900.jsonl"),
    cwd: ($h + "/Code/private-thing"),
    whoami: $u,
    machine: $host,
    contact: "engineer@corp.example.org",
    anthropic_key: "sk-ant-api03-AbCdEf0123456789ZzZz",
    github_token: "ghp_0123456789abcdefghijklmnopqrstuvwx",
    aws_key: "AKIAIOSFODNN7EXAMPLE",
    header: "Authorization: Bearer abcdef0123456789deadbeefcafe",
    jwt: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.QWERTYuiopAS",
    slack: "xoxb-1234567890-abcdefghijklm",
    google: "AIzaSyA0123456789abcdefghijklmnopqrstu",
    elsewhere: "/Users/someoneelse/work/other-repo/src/main.rs"
  }'
}

sani="$TMPROOT/captured.json"
seed_secrets > "$sani"
bash tests/fixture-sanitise.sh "$sani" > /dev/null || fail "sanitise-run" "fixture-sanitise exited non-zero"

jq -e . "$sani" > /dev/null || fail "sanitise-valid-json" "output is not valid JSON"
pass "sanitise-leaves-valid-json"

# Each seeded category must be gone. Checked against the file as a whole so a
# secret moved to another key is still caught.
assert_absent() {
  local label="$1" pattern="$2"
  if grep -qE "$pattern" "$sani"; then
    grep -oE "$pattern" "$sani" | head -1
    fail "sanitise-$label" "$label survived sanitisation"
  fi
}
assert_absent "home-path" "$HOME"
assert_absent "username" "\\b${USER:-nobody}\\b"
assert_absent "hostname" "\\b$(hostname | sed 's/\./\\./g')\\b"
assert_absent "session-id" "3f2a1b7c-9d4e-4f01-8a23-556677889900"
assert_absent "anthropic-key" "sk-ant-api03-[A-Za-z0-9]"
assert_absent "github-token" "ghp_[A-Za-z0-9]{16,}"
assert_absent "aws-key" "AKIAIOSFODNN7EXAMPLE"
assert_absent "bearer-token" "abcdef0123456789deadbeefcafe"
assert_absent "jwt" "eyJhbGciOiJIUzI1NiJ9\\."
assert_absent "slack-token" "xoxb-1234567890"
assert_absent "google-key" "AIzaSyA0123456789"
assert_absent "email" "engineer@corp\\.example\\.org"
assert_absent "foreign-repo-path" "/Users/someoneelse"
pass "sanitise-removes-every-seeded-category"

# The pseudonymised session id has to stay consistent within a file, or an event
# fixture stops pointing at its own transcript.
sid_after=$(jq -r '.session_id' "$sani")
tp_after=$(jq -r '.transcript_path' "$sani")
case "$tp_after" in *"$sid_after"*) ;; *) fail "sanitise-uuid-consistency" "session_id $sid_after no longer appears in transcript_path $tp_after" ;; esac
pass "sanitise-pseudonymises-uuids-consistently"

# Idempotent: re-running must be a no-op, so a fixture can be re-sanitised
# after a hand edit without drifting.
cp "$sani" "$TMPROOT/again.json"
bash tests/fixture-sanitise.sh "$TMPROOT/again.json" > /dev/null
cmp -s "$sani" "$TMPROOT/again.json" || fail "sanitise-idempotent" "second pass changed the file"
pass "sanitise-is-idempotent"

# JSONL path: every line must still parse.
sani_l="$TMPROOT/captured.jsonl"
{ seed_secrets | jq -c .; seed_secrets | jq -c .; } > "$sani_l"
bash tests/fixture-sanitise.sh "$sani_l" > /dev/null || fail "sanitise-jsonl-run" "fixture-sanitise failed on JSONL"
while IFS= read -r line; do
  printf '%s\n' "$line" | jq -e . > /dev/null || fail "sanitise-jsonl-valid" "sanitised JSONL line does not parse"
done < "$sani_l"
grep -q "$HOME" "$sani_l" && fail "sanitise-jsonl-home" "home path survived in JSONL"
pass "sanitise-handles-jsonl"

# =============================================================================
# 3. Event fixtures
# =============================================================================

for f in "$EVENTS_DIR"/*.json; do
  jq -e . "$f" > /dev/null || fail "event-fixture-json" "$f is not valid JSON"
  status=$(jq -r '._fixture.status // "MISSING"' "$f")
  [ "$status" != "MISSING" ] || fail "event-fixture-provenance" "$f has no _fixture.status - every event fixture must declare captured vs reconstructed"
  case "$status" in reconstructed|captured) ;; *) fail "event-fixture-status" "$f has _fixture.status=$status" ;; esac
done
pass "event-fixtures-parse-and-declare-provenance"

# event_fixture strips the provenance block, so it never reaches a hook.
jq -e 'has("_fixture") | not' <<< "$(event_fixture stop-plain)" > /dev/null \
  || fail "event-fixture-strip" "_fixture leaked into the payload"
pass "event-fixture-strips-provenance"

# stop_payload is layered over stop-plain, so the whole suite is fixture-driven.
sp=$(stop_payload "sid-x" "/tmp/t.jsonl" "/tmp")
jq -e '.hook_event_name == "Stop" and .session_id == "sid-x" and .stop_reason == "end_turn"' <<< "$sp" > /dev/null \
  || fail "stop-payload-fixture" "stop_payload no longer derives from stop-plain.json"
pass "stop-payload-derives-from-stop-plain"

# The fixtures drive the hooks they were reconstructed for.
sid_bg="fixev-bg-$$"
ev_bg=$(event_fixture stop-bg-tasks "{session_id:\"$sid_bg\", transcript_path:\"$big_enough\", cwd:\"$TMPROOT\"}")
run_stop "$ev_bg" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/bg.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/bgtmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
oc=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$oc" = "SKIP" ] || { cat "$TMPROOT/bg.log"; fail "event-bg-tasks" "expected SKIP from stop-bg-tasks.json, got $oc"; }
grep -q "background task(s) in flight (subagent,shell)" "$TMPROOT/bg.log" \
  || fail "event-bg-tasks-log" "background-task skip not logged"
pass "event-fixture-stop-bg-tasks-skips"

sid_echo="fixev-echo-$$"
echo_tmp="$TMPROOT/echotmp"
mkdir -p "$echo_tmp/sessions"
printf '%s\n' "$(iso_now)" > "$echo_tmp/sessions/echo-${sid_echo}"
ev_echo=$(event_fixture stop-echo "{session_id:\"$sid_echo\", transcript_path:\"$big_enough\", cwd:\"$TMPROOT\"}")
run_stop "$ev_echo" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/echo.log" CLAUDE_WATCHDOG_TMP="$echo_tmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
oc=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$oc" = "SKIP" ] || { cat "$TMPROOT/echo.log"; fail "event-echo" "expected SKIP from stop-echo.json, got $oc"; }
grep -q "our own analyzer echo" "$TMPROOT/echo.log" || fail "event-echo-log" "echo suppression not logged"
pass "event-fixture-stop-echo-suppresses"

sid_sub="fixev-sub-$$"
analyses="$TMPROOT/ev-analyses"
ev_sub=$(event_fixture subagent-stop "{session_id:\"$sid_sub\"}")
run_persist "$ev_sub" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$analyses" CLAUDE_WATCHDOG_TMP="$TMPROOT/subtmp" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/sub.log"
written=("$analyses/${sid_sub}-"*.md)
[ -f "${written[0]}" ] || fail "event-subagent-stop" "persist hook wrote no analysis from subagent-stop.json"
grep -q "### Recommendations" "${written[0]}" || fail "event-subagent-stop-body" "analysis body not persisted verbatim"
pass "event-fixture-subagent-stop-persists"

sid_ps="fixev-ps-$$"
ps_tmp="$TMPROOT/pstmp"
mkdir -p "$ps_tmp/sessions"
printf '%s\n' "$(iso_now)" > "$ps_tmp/sessions/pending-${sid_ps}"
ev_ps=$(event_fixture prompt-submit "{session_id:\"$sid_ps\"}")
run_hold "$ev_ps" \
  CLAUDE_WATCHDOG_HOLD_INPUT=1 CLAUDE_WATCHDOG_TMP="$ps_tmp" CLAUDE_WATCHDOG_LOG="$TMPROOT/ps.log"
grep -q '"decision":"block"' <<< "$HOLD_OUT" || fail "event-prompt-submit" "prompt-submit.json did not hit the hold path"
pass "event-fixture-prompt-submit-holds"

# =============================================================================
# 4. Transcript fixtures
# =============================================================================

extract_to() { run_condense extract "$1" > "$2"; }

# --- sidechain / subagent ----------------------------------------------------
out="$TMPROOT/subagent.txt"
extract_to tests/fixtures/subagent-session.jsonl "$out"
grep -q 'TOOL_USE: Task(' "$out" || fail "fx-sidechain-task" "Task tool_use missing"
grep -q 'TOOL_USE: Grep(' "$out" || fail "fx-sidechain-inner" "sidechain tool_use missing"
# Sidechain entries carry no marker in the condensed output: the analyzer sees
# the subagent's work inlined with the parent's. Pinned so a port cannot quietly
# start (or stop) distinguishing them.
grep -q 'sidechain' "$out" && fail "fx-sidechain-unmarked" "sidechain entries are now labelled; update this expectation deliberately"
pass "fx-subagent-session-inlines-sidechain-entries"

# --- post-compaction ---------------------------------------------------------
out="$TMPROOT/compacted.txt"
extract_to tests/fixtures/compacted-session.jsonl "$out"
grep -q '^SYSTEM\[summary\]: ' "$out" || fail "fx-compaction-summary" "compaction summary entry not rendered as SYSTEM[summary]"
grep -q 'This session is being continued from a previous conversation' "$out" \
  || fail "fx-compaction-carryover" "post-compaction carry-over message missing"
grep -q '^USER: This session is being continued' "$out" \
  || fail "fx-compaction-label" "the compact carry-over is labelled USER, not mid-turn"
pass "fx-compacted-session-renders-summary-and-carryover"

# --- thinking blocks ---------------------------------------------------------
out="$TMPROOT/thinking.txt"
extract_to tests/fixtures/thinking-session.jsonl "$out"
grep -q '^THINKING: Short thought' "$out" || fail "fx-thinking-short" "short thinking block missing"
long=$(grep -c 'BBBBBBBBBB-PAST-THE-300-CHAR-CAP' "$out" || true)
[ "$long" -eq 0 ] || fail "fx-thinking-cap" "thinking block was not capped at 300 chars"
# 'THINKING: ' + 300 chars
len=$(awk '/^THINKING: A/ {print length($0); exit}' "$out")
[ "$len" -eq 310 ] || fail "fx-thinking-cap-len" "expected a 310-char capped THINKING line, got $len"
grep -q 'redacted_thinking' "$out" && fail "fx-redacted-thinking" "redacted_thinking block is now emitted; it was silently dropped before"
pass "fx-thinking-session-caps-at-300-and-drops-redacted"

# --- MCP tool names ----------------------------------------------------------
out="$TMPROOT/mcp.txt"
extract_to tests/fixtures/mcp-tools-session.jsonl "$out"
grep -q '^TOOL_USE: mcp__github__create_issue(' "$out" || fail "fx-mcp-tool-use" "MCP tool_use name missing"
grep -q '^TOOL_RESULT\[mcp__github__create_issue\]: ' "$out" || fail "fx-mcp-tool-result" "MCP tool_result not attributed to its tool"
grep -q '^TOOL_RESULT\[mcp__plugin_context7_context7__query-docs\]: ' "$out" || fail "fx-mcp-hyphen" "hyphenated MCP tool name missing"
# is_error lives on the tool_result block, not inside `content`; the fixture has
# it inside content, so no [ERROR] label - that is the format, not a bug here.
grep -q '^TOOL_RESULT\[mcp__claude_ai_Todoist__add-tasks\]' "$out" || fail "fx-mcp-third" "third MCP tool_result missing"
pass "fx-mcp-tools-session-preserves-full-tool-names"

# --- image / non-text tool_result -------------------------------------------
out="$TMPROOT/image.txt"
extract_to tests/fixtures/image-result-session.jsonl "$out"
# Pinning the CURRENT behaviour, which is not what design/rewrite-readiness.md
# section 4 claims:
#   - content: [{type:"image",...}]  -> an EMPTY body (the text filter yields "")
#   - content: null                  -> the literal "(no content)"
# Both are lossy: the analyzer cannot tell that an image came back at all. See
# the FLAG in tests/fixtures/CAPTURE.md.
grep -qx 'TOOL_RESULT\[Read\]: ' "$out" || { grep -n 'TOOL_RESULT' "$out"; fail "fx-image-empty" "image-only tool_result no longer renders as an empty body"; }
grep -qx 'TOOL_RESULT\[Read\]: (no content)' "$out" || fail "fx-null-no-content" "null tool_result no longer renders as (no content)"
grep -qx 'TOOL_RESULT\[Bash\]: 1 failed' "$out" || fail "fx-mixed-blocks" "mixed text+image tool_result should keep the text and drop the image"
grep -q 'iVBORw0KGgo' "$out" && fail "fx-image-base64" "base64 image data leaked into the condensed transcript"
pass "fx-image-result-session-pins-non-text-block-rendering"

# --- generated large session -------------------------------------------------
large="$TMPROOT/large-session.jsonl"
bash tests/fixtures/gen-large-session.sh "$large" 1048576 > /dev/null
size=$(wc -c < "$large" | tr -d ' ')
[ "$size" -ge 1048576 ] || fail "fx-large-size" "generated ${size} B, expected >= 1 MB"
head -1 "$large" | jq -e . > /dev/null || fail "fx-large-json" "generated transcript is not valid JSONL"
tail -1 "$large" | jq -e . > /dev/null || fail "fx-large-json-tail" "last generated line is not valid JSON"
sid_lg="fixlg-$$"
run_stop "$(stop_payload "$sid_lg" "$large" "$TMPROOT")" \
  CLAUDE_WATCHDOG_LOG="$TMPROOT/lg.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/lgtmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0
oc=$(outcome "$STOP_OUT" "$STOP_RC")
[ "$oc" = "BLOCK" ] || { cat "$TMPROOT/lg.log"; fail "fx-large-trigger" "the 1 MB fixture should clear every gate, got $oc"; }
grep -q '\[TRUNCATED\]' "$TMPROOT/lgtmp/sessions/condensed-${sid_lg}.txt" \
  || fail "fx-large-truncated" "a 1 MB session should overflow the byte budget and carry the [TRUNCATED] notice"
pass "fx-large-session-generator-produces-a-usable-perf-fixture"

echo "--- all fixture tests passed ---"
