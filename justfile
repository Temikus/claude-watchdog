set shell := ["bash", "-uc"]

default:
    @just --list

# Validate JSON manifests and JS syntax
lint:
    jq empty .claude-plugin/plugin.json
    jq empty hooks/hooks.json
    node --check hooks/session-analysis.mjs
    node --check hooks/persist-analysis.mjs
    node --check hooks/cursor-slice.mjs
    node --check hooks/condense.mjs
    node --check hooks/hold-input.mjs
    for f in tests/fixtures/*.jsonl; do node -e 'const p=process.argv[1]; require("fs").readFileSync(p,"utf8").split("\n").forEach((s,i)=>{ if(!s.startsWith("{")) return; try { JSON.parse(s) } catch (e) { console.error(`${p}:${i+1}: ${e.message}`); process.exit(1) } })' "$f"; done

# Smoke-test the hook with a synthetic Stop event
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    tmpdir=$(mktemp -d)
    session_id="smoketest-$$"
    hold_sid="smokehold-$$"
    # Default storage is project-local ($PWD/.claude); the hook receives cwd=$PWD below.
    sessions="$PWD/.claude/tmp/claude-watchdog/sessions"
    # The echo sentinel always lives in the global sessions dir (it must resolve before
    # the local/global decision), so clean it from there regardless of local storage.
    trap 'rm -rf "$tmpdir"; rmdir "$sessions/${session_id}" "$sessions/${hold_sid}" 2>/dev/null || true; rm -f "$sessions/condensed-${session_id}.txt" "$sessions/raw-${session_id}.txt" "$sessions/cursor-${session_id}.txt" "$sessions/delta-${session_id}.tmp" "$sessions/condensed-${hold_sid}.txt" "$sessions/raw-${hold_sid}.txt" "$sessions/cursor-${hold_sid}.txt" "$sessions/delta-${hold_sid}.tmp" "$HOME/.claude/tmp/claude-watchdog/sessions/echo-${session_id}" "$HOME/.claude/logs/claude-watchdog-analyses/${session_id}-"*.md "$HOME/.claude/logs/claude-watchdog-analyses/${hold_sid}-"*.md 2>/dev/null || true' EXIT
    transcript="$tmpdir/transcript.jsonl"
    for i in $(seq 1 5); do
      printf '{"type":"user","message":{"content":"do task %s"}}\n' "$i" >> "$transcript"
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on task %s"},{"type":"tool_use","id":"toolu_%s","name":"Edit","input":{"file_path":"/tmp/test","old_string":"a","new_string":"b"}}]}}\n' "$i" "$i" >> "$transcript"
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_%s","content":"file contents here"}]}}\n' "$i" >> "$transcript"
    done
    payload=$(jq -n --arg sid "$session_id" --arg tp "$transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    out=$(echo "$payload" | CLAUDE_WATCHDOG_LOG="$tmpdir/log" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) && rc=$? || rc=$?
    echo "hook exit: $rc (expected 0)"
    echo "--- stdout ---"
    echo "$out"
    echo "--- log ---"
    cat "$tmpdir/log"
    echo "--- condensed ---"
    cat "$sessions/condensed-${session_id}.txt" 2>/dev/null || echo "(not found)"
    # Default protocol: analysis is signalled via a JSON `decision:block` on stdout with exit 0.
    [ "$rc" -eq 0 ] || { echo "FAIL: expected exit 0, got $rc"; exit 1; }
    echo "$out" | grep -q '"decision":"block"' || { echo "FAIL: expected decision:block on stdout"; exit 1; }
    echo "$out" | grep -q 'This is the first analysis for this session.' || { echo "FAIL: expected first-analysis marker in prompt"; exit 1; }
    echo "$out" | grep -q 'Files touched this slice: /tmp/test' || { echo "FAIL: expected touched files in prompt"; exit 1; }
    # Input-hold is opt-in: the default run above must not write a pending sentinel.
    [ ! -f "$HOME/.claude/tmp/claude-watchdog/sessions/pending-${session_id}" ] || { echo "FAIL: pending sentinel written without opt-in"; exit 1; }
    # With the option on, a trigger writes a timestamped pending sentinel. Use a
    # hermetic CLAUDE_WATCHDOG_TMP so the sentinel lands in the tmpdir.
    wtmp="$tmpdir/wtmp"
    payload_hold=$(jq -n --arg sid "$hold_sid" --arg tp "$transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    out_hold=$(echo "$payload_hold" | CLAUDE_WATCHDOG_LOG="$tmpdir/log" CLAUDE_WATCHDOG_TMP="$wtmp" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/session-analysis.mjs 2>/dev/null)
    echo "$out_hold" | grep -q '"decision":"block"' || { echo "FAIL: hold-enabled run should still trigger"; exit 1; }
    pending="$wtmp/sessions/pending-${hold_sid}"
    [ -f "$pending" ] || { echo "FAIL: pending sentinel missing with CLAUDE_WATCHDOG_HOLD_INPUT=1"; exit 1; }
    node -e 'const l = require("fs").readFileSync(process.argv[1], "utf8").split("\n")[0]; if (Number.isNaN(Date.parse(l))) process.exit(1);' "$pending" || { echo "FAIL: pending sentinel timestamp not parseable"; exit 1; }
    echo "pending sentinel OK: $pending"

# Cursor / delta-analysis behaviour tests
test-cursor:
    #!/usr/bin/env bash
    set -euo pipefail
    export WATCHDOG_DIR="$HOME/.claude/tmp/claude-watchdog/sessions"
    mkdir -p "$WATCHDOG_DIR"
    # Storage defaults to project-local; pin these generic cursor/delta tests to the
    # global path so they can anchor on WATCHDOG_DIR. The project-local default is
    # covered explicitly by the local-storage tests (15/16), which override this.
    export CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0

    mk_msg() {
      # $1 type (user|assistant), $2 uuid, $3 text (for user: plain; for assistant: text block + tool_use)
      local kind="$1" uuid="$2" text="$3"
      if [ "$kind" = "user" ]; then
        jq -nc --arg u "$uuid" --arg t "$text" '{type:"user",uuid:$u,message:{content:$t}}'
      else
        jq -nc --arg u "$uuid" --arg t "$text" '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:$t},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:"a",new_string:"b"}}]}}'
      fi
    }

    mk_transcript() {
      # $1 path, $2 start idx, $3 end idx, $4 marker
      local path="$1" start="$2" end="$3" marker="$4"
      : > "$path"
      for i in $(seq "$start" "$end"); do
        mk_msg user "u-${marker}-${i}" "${marker} user ${i}" >> "$path"
        mk_msg assistant "a-${marker}-${i}" "${marker} assistant ${i}" >> "$path"
      done
    }

    # Classify the hook result by its real wire protocol: an "analyze this session"
    # decision is a JSON `decision:block` on stdout with exit 0 (BLOCK); any other
    # clean exit is a skip (SKIP); a non-zero exit is surfaced as ERR:<code>.
    hook_outcome() {
      local out="$1" rc="$2"
      if [ "$rc" -ne 0 ]; then
        echo "ERR:$rc"
      elif printf '%s' "$out" | grep -q '"decision":"block"'; then
        echo BLOCK
      else
        echo SKIP
      fi
    }

    run_hook() {
      # $1 session_id, $2 transcript_path -> prints outcome (BLOCK | SKIP | ERR:<code>)
      local sid="$1" tp="$2"
      local payload
      payload=$(jq -n --arg sid "$sid" --arg tp "$tp" --arg cwd "$PWD" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
      local rc=0 out
      out=$(echo "$payload" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
      hook_outcome "$out" "$rc"
    }

    cleanup_session() {
      local sid="$1"
      rm -f "$WATCHDOG_DIR/cursor-${sid}.txt" \
            "$WATCHDOG_DIR/condensed-${sid}.txt" \
            "$WATCHDOG_DIR/raw-${sid}.txt" \
            "$WATCHDOG_DIR/delta-${sid}.tmp" \
            "$WATCHDOG_DIR/echo-${sid}" \
            "$WATCHDOG_DIR/pending-${sid}" \
            "$HOME/.claude/logs/claude-watchdog-analyses/${sid}-"*.md 2>/dev/null || true
      rmdir "$WATCHDOG_DIR/${sid}" 2>/dev/null || true
    }

    pass() { echo "PASS: $1"; }
    fail() { echo "FAIL: $1 - $2" >&2; exit 1; }

    TMPROOT=$(mktemp -d)
    TEST_LOG="$TMPROOT/log"
    trap 'rm -rf "$TMPROOT"' EXIT

    # --- Test 1: node-helper-unit (slice subcommand) ---
    t1_transcript="$TMPROOT/t1.jsonl"
    mk_transcript "$t1_transcript" 1 5 OLD
    # fast-path hit: line 3 is user uuid u-OLD-2, hint=3 -> DELTA_START=4
    out=$(node hooks/cursor-slice.mjs slice "$t1_transcript" "u-OLD-2" 3)
    [ "$out" = "DELTA_START=4" ] || fail "node-helper-slice-fast" "expected DELTA_START=4 got '$out'"
    # fast-path miss (wrong hint) but uuid exists -> fallback scan
    out=$(node hooks/cursor-slice.mjs slice "$t1_transcript" "u-OLD-2" 9999)
    [ "$out" = "DELTA_START=4" ] || fail "node-helper-slice-fallback" "expected DELTA_START=4 got '$out'"
    # uuid not found -> DELTA_START=1
    out=$(node hooks/cursor-slice.mjs slice "$t1_transcript" "missing-uuid" 3)
    [ "$out" = "DELTA_START=1" ] || fail "node-helper-slice-missing" "expected DELTA_START=1 got '$out'"
    # last-uuid on a delta file
    out=$(node hooks/cursor-slice.mjs last-uuid "$t1_transcript")
    echo "$out" | grep -q "^UUID=a-OLD-5$" || fail "node-helper-last-uuid" "expected UUID=a-OLD-5 got '$out'"
    echo "$out" | grep -q "^REL_LINE=10$" || fail "node-helper-last-uuid-line" "expected REL_LINE=10 got '$out'"
    pass "node-helper-unit"

    # --- Test 2: first-run (no cursor, full transcript processed) ---
    sid2="cursor-t2-$$"
    cleanup_session "$sid2"
    t2_transcript="$TMPROOT/t2.jsonl"
    mk_transcript "$t2_transcript" 1 5 OLD
    outcome=$(run_hook "$sid2" "$t2_transcript")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "first-run-exit" "expected BLOCK got $outcome"; }
    [ -f "$WATCHDOG_DIR/cursor-${sid2}.txt" ] || fail "first-run-cursor-exists" "cursor file missing"
    line1=$(sed -n '1p' "$WATCHDOG_DIR/cursor-${sid2}.txt")
    [ "$line1" = "a-OLD-5" ] || fail "first-run-cursor-uuid" "expected a-OLD-5 got $line1"
    line3=$(sed -n '3p' "$WATCHDOG_DIR/cursor-${sid2}.txt")
    [ "$line3" = "$t2_transcript" ] || fail "first-run-cursor-path" "expected $t2_transcript got $line3"
    cleanup_session "$sid2"
    pass "first-run"

    # --- Test 3: trivial-delta (below MIN_TOOL_USES, cursor unchanged) ---
    sid3="cursor-t3-$$"
    cleanup_session "$sid3"
    t3_transcript="$TMPROOT/t3.jsonl"
    mk_transcript "$t3_transcript" 1 5 OLD
    # seed cursor at line 10 (last line, a-OLD-5)
    printf 'a-OLD-5\n10\n%s\n' "$t3_transcript" > "$WATCHDOG_DIR/cursor-${sid3}.txt"
    # append 1 new round (2 messages, 1 tool_use) -> below MIN_TOOL_USES=3
    mk_msg user "u-NEW-1" "NEW user 1" >> "$t3_transcript"
    mk_msg assistant "a-NEW-1" "NEW assistant 1" >> "$t3_transcript"
    outcome=$(run_hook "$sid3" "$t3_transcript")
    [ "$outcome" = "SKIP" ] || { cat "$TEST_LOG"; fail "trivial-delta-exit" "expected SKIP got $outcome"; }
    grep -q "SKIP: delta too small" "$TEST_LOG" || fail "trivial-delta-log" "no SKIP log"
    line1=$(sed -n '1p' "$WATCHDOG_DIR/cursor-${sid3}.txt")
    [ "$line1" = "a-OLD-5" ] || fail "trivial-delta-cursor-unchanged" "cursor moved: $line1"
    cleanup_session "$sid3"
    pass "trivial-delta"

    # --- Test 4: substantial-delta (cursor advances, condensed contains only new) ---
    sid4="cursor-t4-$$"
    cleanup_session "$sid4"
    t4_transcript="$TMPROOT/t4.jsonl"
    mk_transcript "$t4_transcript" 1 3 OLDMARK
    # cursor at last OLD message (line 6, a-OLDMARK-3)
    printf 'a-OLDMARK-3\n6\n%s\n' "$t4_transcript" > "$WATCHDOG_DIR/cursor-${sid4}.txt"
    # append 3 new rounds (3 tool_uses total) - passes MIN_TOOL_USES
    for i in 1 2 3; do
      mk_msg user "u-NEWMARK-$i" "NEWMARK user $i" >> "$t4_transcript"
      mk_msg assistant "a-NEWMARK-$i" "NEWMARK assistant $i" >> "$t4_transcript"
    done
    outcome=$(run_hook "$sid4" "$t4_transcript")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "substantial-delta-exit" "expected BLOCK got $outcome"; }
    condensed="$WATCHDOG_DIR/condensed-${sid4}.txt"
    [ -f "$condensed" ] || fail "substantial-delta-condensed" "no condensed file"
    grep -q "NEWMARK" "$condensed" || fail "substantial-delta-has-new" "NEWMARK missing"
    if grep -q "OLDMARK" "$condensed"; then fail "substantial-delta-no-old" "OLDMARK leaked into condensed"; fi
    line1=$(sed -n '1p' "$WATCHDOG_DIR/cursor-${sid4}.txt")
    [ "$line1" = "a-NEWMARK-3" ] || fail "substantial-delta-cursor-advanced" "expected a-NEWMARK-3 got $line1"
    cleanup_session "$sid4"
    pass "substantial-delta"

    # --- Test 5: stale-transcript (cursor points to missing file) ---
    sid5="cursor-t5-$$"
    cleanup_session "$sid5"
    t5_transcript="$TMPROOT/t5.jsonl"
    mk_transcript "$t5_transcript" 1 5 OLD
    printf 'a-OLD-5\n10\n%s\n' "$TMPROOT/nonexistent.jsonl" > "$WATCHDOG_DIR/cursor-${sid5}.txt"
    outcome=$(run_hook "$sid5" "$t5_transcript")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "stale-transcript-exit" "expected BLOCK got $outcome"; }
    grep -q "CURSOR: stale transcript path" "$TEST_LOG" || fail "stale-transcript-log" "no stale log"
    cleanup_session "$sid5"
    pass "stale-transcript"

    # --- Test 6: uuid-fallback (wrong line hint, uuid scan resolves) ---
    sid6="cursor-t6-$$"
    cleanup_session "$sid6"
    t6_transcript="$TMPROOT/t6.jsonl"
    mk_transcript "$t6_transcript" 1 3 OLDMARK
    # cursor uuid correct, line hint wrong
    printf 'a-OLDMARK-3\n9999\n%s\n' "$t6_transcript" > "$WATCHDOG_DIR/cursor-${sid6}.txt"
    for i in 1 2 3; do
      mk_msg user "u-NEWMARK-$i" "NEWMARK user $i" >> "$t6_transcript"
      mk_msg assistant "a-NEWMARK-$i" "NEWMARK assistant $i" >> "$t6_transcript"
    done
    outcome=$(run_hook "$sid6" "$t6_transcript")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "uuid-fallback-exit" "expected BLOCK got $outcome"; }
    condensed="$WATCHDOG_DIR/condensed-${sid6}.txt"
    if grep -q "OLDMARK" "$condensed"; then fail "uuid-fallback-isolation" "OLDMARK leaked despite fallback"; fi
    cleanup_session "$sid6"
    pass "uuid-fallback"

    # --- Test 7: concurrency (second invocation skips via lock) ---
    sid7="cursor-t7-$$"
    cleanup_session "$sid7"
    t7_transcript="$TMPROOT/t7.jsonl"
    mk_transcript "$t7_transcript" 1 5 OLD
    # Pre-create the marker dir to simulate an in-progress run
    mkdir -p "$WATCHDOG_DIR/${sid7}"
    outcome=$(run_hook "$sid7" "$t7_transcript")
    [ "$outcome" = "SKIP" ] || { cat "$TEST_LOG"; fail "concurrency-exit" "expected SKIP got $outcome"; }
    grep -q "SKIP: concurrent run already in progress" "$TEST_LOG" || fail "concurrency-log" "no concurrent-run log"
    # The second invocation should not delete the marker dir it didn't acquire
    [ -d "$WATCHDOG_DIR/${sid7}" ] || fail "concurrency-marker-preserved" "marker dir was removed"
    rmdir "$WATCHDOG_DIR/${sid7}"
    cleanup_session "$sid7"
    pass "concurrency"

    # --- Test 8: ttl-cleanup (stale cursor pruned) ---
    sid8="cursor-t8-$$"
    cleanup_session "$sid8"
    stale_cursor="$WATCHDOG_DIR/cursor-${sid8}.txt"
    printf 'stale\n0\n/nope\n' > "$stale_cursor"
    touch -t 202001010000 "$stale_cursor"
    t8_transcript="$TMPROOT/t8.jsonl"
    mk_transcript "$t8_transcript" 1 5 OLD
    # run the hook (under any session_id); cleanup runs at top regardless
    run_hook "fresh-$$" "$t8_transcript" >/dev/null || true
    if [ -f "$stale_cursor" ]; then fail "ttl-cleanup" "stale cursor was not deleted"; fi
    cleanup_session "fresh-$$"
    pass "ttl-cleanup"

    # --- Test 9: malformed-cursor (bogus uuid / non-integer line is rejected, no shell injection) ---
    sid9="cursor-t9-$$"
    cleanup_session "$sid9"
    t9_transcript="$TMPROOT/t9.jsonl"
    mk_transcript "$t9_transcript" 1 3 OLDMARK
    # Adversarial cursor: shell metacharacters in uuid, non-integer line number
    printf 'evil; touch %s/pwned\nnot-a-number\n%s\n' "$TMPROOT" "$t9_transcript" > "$WATCHDOG_DIR/cursor-${sid9}.txt"
    for i in 1 2 3; do
      mk_msg user "u-NEWMARK-$i" "NEWMARK user $i" >> "$t9_transcript"
      mk_msg assistant "a-NEWMARK-$i" "NEWMARK assistant $i" >> "$t9_transcript"
    done
    outcome=$(run_hook "$sid9" "$t9_transcript")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "malformed-cursor-exit" "expected BLOCK got $outcome"; }
    [ ! -f "$TMPROOT/pwned" ] || fail "malformed-cursor-injection" "shell injection succeeded: pwned file exists"
    grep -q "CURSOR: malformed uuid" "$TEST_LOG" || fail "malformed-cursor-log" "no malformed-uuid log"
    cleanup_session "$sid9"
    pass "malformed-cursor"

    # --- Test 10: cooldown (second trigger within window is skipped) ---
    sid10="cursor-t10-$$"
    cleanup_session "$sid10"
    t10_transcript="$TMPROOT/t10.jsonl"
    mk_transcript "$t10_transcript" 1 5 OLD
    payload10=$(jq -n --arg sid "$sid10" --arg tp "$t10_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    # First run: no cursor yet, should trigger
    rc=0
    out=$(echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=60 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "cooldown-first-run" "expected BLOCK got $outcome"; }
    # Append enough new tool uses to clear MIN_TOOL_USES
    for i in 1 2 3; do
      mk_msg user "u-COOL-$i" "COOL user $i" >> "$t10_transcript"
      mk_msg assistant "a-COOL-$i" "COOL assistant $i" >> "$t10_transcript"
    done
    # Second run: cursor mtime is fresh, cooldown=60s should skip
    rc=0
    out=$(echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=60 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "SKIP" ] || { cat "$TEST_LOG"; fail "cooldown-second-run" "expected SKIP got $outcome"; }
    grep -q "SKIP: cooldown active" "$TEST_LOG" || fail "cooldown-log" "no cooldown log"
    # Third run with cooldown=0 should trigger again, proving the gate is the only thing blocking
    rc=0
    out=$(echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "cooldown-disabled" "expected BLOCK got $outcome"; }
    cleanup_session "$sid10"
    pass "cooldown"

    # --- Test 11: userConfig fallback (CLAUDE_PLUGIN_OPTION_* used when legacy var unset) ---
    sid11="cursor-t11-$$"
    cleanup_session "$sid11"
    t11_transcript="$TMPROOT/t11.jsonl"
    mk_transcript "$t11_transcript" 1 5 OLD
    payload11=$(jq -n --arg sid "$sid11" --arg tp "$t11_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload11" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES=3 CLAUDE_PLUGIN_OPTION_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "userconfig-fallback" "expected BLOCK got $outcome"; }
    cleanup_session "$sid11"
    pass "userconfig-fallback"

    # --- Test 12: userConfig disabled=true skips analysis ---
    sid12="cursor-t12-$$"
    cleanup_session "$sid12"
    t12_transcript="$TMPROOT/t12.jsonl"
    mk_transcript "$t12_transcript" 1 5 OLD
    payload12=$(jq -n --arg sid "$sid12" --arg tp "$t12_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload12" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_PLUGIN_OPTION_DISABLED=true node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "SKIP" ] || { cat "$TEST_LOG"; fail "userconfig-disabled" "expected SKIP got $outcome"; }
    grep -q "SKIP: disabled via configuration" "$TEST_LOG" || fail "userconfig-disabled-log" "no disabled log"
    cleanup_session "$sid12"
    pass "userconfig-disabled"

    # --- Test 13: legacy env var overrides CLAUDE_PLUGIN_OPTION_* ---
    sid13="cursor-t13-$$"
    cleanup_session "$sid13"
    t13_transcript="$TMPROOT/t13.jsonl"
    mk_transcript "$t13_transcript" 1 5 OLD
    payload13=$(jq -n --arg sid "$sid13" --arg tp "$t13_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    # Legacy MIN_TOOL_USES=3 should win over CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES=999
    rc=0
    out=$(echo "$payload13" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES=999 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "legacy-overrides-plugin" "expected BLOCK got $outcome (legacy var should win over plugin option)"; }
    cleanup_session "$sid13"
    pass "legacy-overrides-plugin"

    # --- Test 14: CLAUDE_WATCHDOG_VERBOSE=1 adds truncation header ---
    sid14="cursor-t14-$$"
    cleanup_session "$sid14"
    t14_transcript="$TMPROOT/t14.jsonl"
    # Generate enough data to exceed a tiny MAX_BYTES budget
    mk_transcript "$t14_transcript" 1 20 VERBOSE
    payload14=$(jq -n --arg sid "$sid14" --arg tp "$t14_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload14" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_MAX_BYTES=512 CLAUDE_WATCHDOG_VERBOSE=1 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "verbose-trigger" "expected BLOCK got $outcome"; }
    condensed14="$WATCHDOG_DIR/condensed-${sid14}.txt"
    [ -f "$condensed14" ] || fail "verbose-condensed-exists" "condensed file not found"
    grep -q "\\[TRUNCATED\\]" "$condensed14" || { cat "$condensed14"; fail "verbose-header" "truncation header not found in condensed output"; }
    cleanup_session "$sid14"
    pass "verbose-truncation-header"

    # --- Test 15: local-storage stores files in project-local path ---
    sid15="cursor-t15-$$"
    cleanup_session "$sid15"
    t15_cwd="$TMPROOT/fake-project"
    mkdir -p "$t15_cwd"
    t15_transcript="$TMPROOT/t15.jsonl"
    mk_transcript "$t15_transcript" 1 5 LOCAL
    payload15=$(jq -n --arg sid "$sid15" --arg tp "$t15_transcript" --arg cwd "$t15_cwd" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload15" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "local-storage-exit" "expected BLOCK got $outcome"; }
    local_sessions="$t15_cwd/.claude/tmp/claude-watchdog/sessions"
    [ -f "$local_sessions/condensed-${sid15}.txt" ] || fail "local-storage-file" "condensed not in local path"
    if [ -f "$WATCHDOG_DIR/condensed-${sid15}.txt" ]; then fail "local-storage-global-leaked" "condensed found in global path"; fi
    grep -q "LOCAL_STORAGE: using project-local path" "$TEST_LOG" || fail "local-storage-log" "no local storage log"
    rm -rf "$t15_cwd/.claude"
    cleanup_session "$sid15"
    pass "local-storage"

    # --- Test 16: local-storage fallback on invalid cwd ---
    sid16="cursor-t16-$$"
    cleanup_session "$sid16"
    t16_transcript="$TMPROOT/t16.jsonl"
    mk_transcript "$t16_transcript" 1 5 FALLBACK
    payload16=$(jq -n --arg sid "$sid16" --arg tp "$t16_transcript" --arg cwd "$TMPROOT/nonexistent-dir" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload16" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$TEST_LOG"; fail "local-fallback-exit" "expected BLOCK got $outcome"; }
    [ -f "$WATCHDOG_DIR/condensed-${sid16}.txt" ] || fail "local-fallback-global" "condensed not in global path"
    grep -q "LOCAL_STORAGE: hook_cwd empty or invalid" "$TEST_LOG" || fail "local-fallback-log" "no fallback log"
    cleanup_session "$sid16"
    pass "local-storage-fallback"

    # --- Test 17: subagent/teammate skip (agent_id present) ---
    sid17="cursor-t17-$$"
    cleanup_session "$sid17"
    t17_transcript="$TMPROOT/t17.jsonl"
    mk_transcript "$t17_transcript" 1 5 OLD
    payload17=$(jq -n --arg sid "$sid17" --arg tp "$t17_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", agent_id:"some-agent-id", agent_type:"general-purpose"}')
    rc=0
    out=$(echo "$payload17" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "SKIP" ] || { cat "$TEST_LOG"; fail "subagent-skip-exit" "expected SKIP got $outcome"; }
    grep -q "SKIP: running inside subagent/teammate" "$TEST_LOG" || fail "subagent-skip-log" "no subagent skip log"
    [ ! -f "$WATCHDOG_DIR/condensed-${sid17}.txt" ] || fail "subagent-skip-no-condensed" "condensed file should not exist"
    cleanup_session "$sid17"
    pass "subagent-teammate-skip"

    # --- Test 18: echo-cycle (suppress our own analyzer echo exactly once) ---
    sid18="cursor-t18-$$"
    cleanup_session "$sid18"
    t18_transcript="$TMPROOT/t18.jsonl"
    mk_transcript "$t18_transcript" 1 5 OLD
    # Phase 1: substantial delta, fresh turn (stop_hook_active:false) -> TRIGGER and
    # the self-owned echo sentinel must now exist.
    log18p1="$TMPROOT/log-t18p1"
    payload18p1=$(jq -n --arg sid "$sid18" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", stop_hook_active:false}')
    rc=0
    echo "$payload18p1" | CLAUDE_WATCHDOG_LOG="$log18p1" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { cat "$log18p1"; fail "echo-cycle-p1-exit" "expected 0 got $rc"; }
    grep -q "TRIGGER:" "$log18p1" || { cat "$log18p1"; fail "echo-cycle-p1-trigger" "expected TRIGGER on the first (fresh) turn"; }
    [ -f "$WATCHDOG_DIR/echo-${sid18}" ] || fail "echo-cycle-p1-sentinel" "echo sentinel not written after TRIGGER"
    # Phase 2: same sid, the analyzer's resulting Stop carries stop_hook_active:true.
    # Fresh log so the assertion can't match Phase 1. Cooldown=0 proves the echo
    # sentinel (not the cooldown) is what suppresses this turn.
    log18p2="$TMPROOT/log-t18p2"
    payload18p2=$(jq -n --arg sid "$sid18" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", stop_hook_active:true}')
    rc=0
    echo "$payload18p2" | CLAUDE_WATCHDOG_LOG="$log18p2" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { cat "$log18p2"; fail "echo-cycle-p2-exit" "expected 0 got $rc"; }
    grep -q "SKIP: our own analyzer echo" "$log18p2" || { cat "$log18p2"; fail "echo-cycle-p2-skip" "expected our-own-echo skip log"; }
    if grep -q "TRIGGER:" "$log18p2"; then fail "echo-cycle-p2-no-trigger" "must not trigger on our own echo"; fi
    [ ! -f "$WATCHDOG_DIR/echo-${sid18}" ] || fail "echo-cycle-p2-sentinel-cleared" "echo sentinel must be removed after the skip"
    cleanup_session "$sid18"
    pass "echo-cycle"

    # --- Test 19: foreign continuation still fires (encodes the #8 fix) ---
    # stop_hook_active:true but NO echo sentinel => the continuation came from another
    # plugin's Stop hook, not ours. The watchdog MUST NOT suppress it. (Under #8's
    # flag-only guard this would have been wrongly skipped.)
    sid19="cursor-t19-$$"
    cleanup_session "$sid19"
    t19_transcript="$TMPROOT/t19.jsonl"
    mk_transcript "$t19_transcript" 1 5 OLD
    log19="$TMPROOT/log-t19"
    payload19=$(jq -n --arg sid "$sid19" --arg tp "$t19_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", stop_hook_active:true}')
    rc=0
    echo "$payload19" | CLAUDE_WATCHDOG_LOG="$log19" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { cat "$log19"; fail "foreign-continuation-exit" "expected 0 got $rc"; }
    grep -q "TRIGGER:" "$log19" || { cat "$log19"; fail "foreign-continuation-trigger" "expected TRIGGER for a foreign continuation"; }
    if grep -q "SKIP: our own analyzer echo" "$log19"; then fail "foreign-continuation-no-skip" "must not treat a foreign continuation as our echo"; fi
    cleanup_session "$sid19"
    pass "foreign-continuation"

    # --- Test 20: stale sentinel + fresh turn clears, then still fires ---
    # A leftover sentinel (we blocked but the analyzer's echo Stop never arrived, e.g.
    # the session closed). On a fresh end_turn it must be cleared, not treated as an
    # echo, and the substantial delta must still TRIGGER.
    sid20="cursor-t20-$$"
    cleanup_session "$sid20"
    t20_transcript="$TMPROOT/t20.jsonl"
    mk_transcript "$t20_transcript" 1 5 OLD
    printf 'stale-marker\n' > "$WATCHDOG_DIR/echo-${sid20}"
    # A leftover input-hold sentinel must be cleared on the same stale path,
    # regardless of whether the hold option is currently enabled.
    printf 'stale-pending\n' > "$WATCHDOG_DIR/pending-${sid20}"
    log20="$TMPROOT/log-t20"
    payload20=$(jq -n --arg sid "$sid20" --arg tp "$t20_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", stop_hook_active:false}')
    rc=0
    echo "$payload20" | CLAUDE_WATCHDOG_LOG="$log20" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { cat "$log20"; fail "stale-sentinel-exit" "expected 0 got $rc"; }
    grep -q "ECHO: stale sentinel cleared" "$log20" || { cat "$log20"; fail "stale-sentinel-log" "expected stale-sentinel-cleared log"; }
    grep -q "TRIGGER:" "$log20" || { cat "$log20"; fail "stale-sentinel-trigger" "expected TRIGGER after clearing the stale sentinel"; }
    # The stale sentinel was removed; the TRIGGER then writes a fresh timestamped one,
    # so the file exists but no longer holds the stale marker.
    if grep -q "stale-marker" "$WATCHDOG_DIR/echo-${sid20}" 2>/dev/null; then fail "stale-sentinel-not-cleared" "stale sentinel content survived"; fi
    [ ! -f "$WATCHDOG_DIR/pending-${sid20}" ] || fail "stale-pending-cleared" "stale pending sentinel survived the fresh turn"
    cleanup_session "$sid20"
    pass "stale-sentinel"

    # --- Test 21: background_tasks in flight -> SKIP (session paused, not done) ---
    sid21="cursor-t21-$$"
    cleanup_session "$sid21"
    log21="$TMPROOT/log-t21"
    # Substantial delta (same transcript Test 22 fires on), but a non-empty
    # background_tasks array means the session is merely paused -> defer.
    payload21=$(jq -n --arg sid "$sid21" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", background_tasks:[{type:"subagent",id:"a1"},{type:"shell",id:"s1"}]}')
    rc=0
    out=$(echo "$payload21" | CLAUDE_WATCHDOG_LOG="$log21" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "SKIP" ] || { cat "$log21"; fail "bg-tasks-skip-exit" "expected SKIP got $outcome"; }
    grep -q "SKIP: 2 background task(s) in flight (subagent,shell)" "$log21" || { cat "$log21"; fail "bg-tasks-skip-log" "no background-task skip log"; }
    [ ! -f "$WATCHDOG_DIR/condensed-${sid21}.txt" ] || fail "bg-tasks-no-condensed" "condensed file should not exist"
    [ ! -f "$WATCHDOG_DIR/cursor-${sid21}.txt" ] || fail "bg-tasks-no-cursor" "cursor should not be created"
    cleanup_session "$sid21"
    pass "background-tasks-skip"

    # --- Test 22: background_tasks absent (old Claude Code) -> TRIGGER (feature-detect) ---
    sid22="cursor-t22-$$"
    cleanup_session "$sid22"
    log22="$TMPROOT/log-t22"
    # No background_tasks field at all, as on Claude Code < 2.1.145: must behave as before.
    payload22=$(jq -n --arg sid "$sid22" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    rc=0
    out=$(echo "$payload22" | CLAUDE_WATCHDOG_LOG="$log22" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$log22"; fail "bg-tasks-absent-exit" "expected BLOCK got $outcome"; }
    if grep -q "background task(s) in flight" "$log22"; then fail "bg-tasks-absent-no-skip" "must not skip when background_tasks is absent"; fi
    cleanup_session "$sid22"
    pass "background-tasks-absent-triggers"

    # --- Test 23: opt-out (CLAUDE_WATCHDOG_SKIP_WITH_BACKGROUND_TASKS=0) -> TRIGGER ---
    sid23="cursor-t23-$$"
    cleanup_session "$sid23"
    log23="$TMPROOT/log-t23"
    payload23=$(jq -n --arg sid "$sid23" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", background_tasks:[{type:"subagent",id:"a1"}]}')
    rc=0
    out=$(echo "$payload23" | CLAUDE_WATCHDOG_LOG="$log23" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_SKIP_WITH_BACKGROUND_TASKS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "BLOCK" ] || { cat "$log23"; fail "bg-tasks-optout-exit" "expected BLOCK got $outcome (opt-out should let it fire)"; }
    if grep -q "background task(s) in flight" "$log23"; then fail "bg-tasks-optout-no-skip" "must not skip when opted out"; fi
    cleanup_session "$sid23"
    pass "background-tasks-opt-out"

    # --- Test 24: session cron already scheduled for the analyzer -> SKIP ---
    sid24="cursor-t24-$$"
    cleanup_session "$sid24"
    log24="$TMPROOT/log-t24"
    payload24=$(jq -n --arg sid "$sid24" --arg tp "$t18_transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn", session_crons:[{prompt:"/loop /analyze-session"}]}')
    rc=0
    out=$(echo "$payload24" | CLAUDE_WATCHDOG_LOG="$log24" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 node hooks/session-analysis.mjs 2>/dev/null) || rc=$?
    outcome=$(hook_outcome "$out" "$rc")
    [ "$outcome" = "SKIP" ] || { cat "$log24"; fail "session-cron-skip-exit" "expected SKIP got $outcome"; }
    grep -q "SKIP: analysis already scheduled via session cron" "$log24" || { cat "$log24"; fail "session-cron-skip-log" "no session-cron skip log"; }
    [ ! -f "$WATCHDOG_DIR/condensed-${sid24}.txt" ] || fail "session-cron-no-condensed" "condensed file should not exist"
    cleanup_session "$sid24"
    pass "session-cron-skip"

    echo "--- all cursor tests passed ---"

# Test the SubagentStop persistence hook
test-persist:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT
    export CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses"
    export CLAUDE_WATCHDOG_LOG="$TMPROOT/log"
    export CLAUDE_WATCHDOG_TMP="$TMPROOT/tmp"
    SESSIONS="$CLAUDE_WATCHDOG_TMP/sessions"
    mkdir -p "$SESSIONS"

    pass() { echo "PASS: $1"; }
    fail() { echo "FAIL: $1 - $2" >&2; exit 1; }

    # --- Test 1: session-analyzer payload writes a file ---
    sid1="persist-t1-$$"
    payload=$(jq -n --arg sid "$sid1" --arg msg $'### Goals\nSome analysis.' \
      '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')
    echo "$payload" | node hooks/persist-analysis.mjs
    out=$(ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid1}-*.md 2>/dev/null | head -1)
    [ -n "$out" ] || fail "analyzer-writes" "no analysis file written"
    grep -q "### Goals" "$out" || fail "analyzer-content" "file missing content"
    pass "analyzer-writes"

    # --- Test 2: other subagent types are ignored ---
    sid2="persist-t2-$$"
    payload=$(jq -n --arg sid "$sid2" --arg msg "ignored" \
      '{session_id:$sid, agent_type:"general-purpose", last_assistant_message:$msg}')
    echo "$payload" | node hooks/persist-analysis.mjs
    if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid2}-*.md >/dev/null 2>&1; then
      fail "other-agent-ignored" "wrote file for non-analyzer subagent"
    fi
    pass "other-agent-ignored"

    # --- Test 3: empty message skips without error ---
    sid3="persist-t3-$$"
    payload=$(jq -n --arg sid "$sid3" \
      '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:""}')
    echo "$payload" | node hooks/persist-analysis.mjs
    if ls "$CLAUDE_WATCHDOG_ANALYSES_DIR"/${sid3}-*.md >/dev/null 2>&1; then
      fail "empty-message" "wrote file for empty message"
    fi
    grep -q "empty last_assistant_message" "$CLAUDE_WATCHDOG_LOG" || fail "empty-log" "no empty log"
    pass "empty-message"

    # --- Test 4: invalid session_id is rejected ---
    payload=$(jq -n --arg msg "x" \
      '{session_id:"evil; rm -rf /", agent_type:"session-analyzer", last_assistant_message:$msg}')
    echo "$payload" | node hooks/persist-analysis.mjs
    grep -q "invalid session_id" "$CLAUDE_WATCHDOG_LOG" || fail "bad-sid" "no invalid-sid log"
    pass "invalid-session-id"

    # --- Test 5: pending sentinel cleared on analyzer completion ---
    sid5="persist-t5-$$"
    touch "$SESSIONS/pending-${sid5}"
    payload=$(jq -n --arg sid "$sid5" --arg msg "analysis text" \
      '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:$msg}')
    echo "$payload" | node hooks/persist-analysis.mjs
    [ ! -f "$SESSIONS/pending-${sid5}" ] || fail "pending-cleared" "pending sentinel not removed"
    pass "pending-cleared"

    # --- Test 6: pending sentinel cleared even when the message is empty ---
    sid6="persist-t6-$$"
    touch "$SESSIONS/pending-${sid6}"
    payload=$(jq -n --arg sid "$sid6" \
      '{session_id:$sid, agent_type:"session-analyzer", last_assistant_message:""}')
    echo "$payload" | node hooks/persist-analysis.mjs
    [ ! -f "$SESSIONS/pending-${sid6}" ] || fail "pending-cleared-empty" "pending sentinel not removed on empty message"
    pass "pending-cleared-empty-message"

    echo "--- all persist tests passed ---"

# Transcript condensation: mid-turn user input, noise filtering, byte budget,
# project-root anchoring. Fixture is sanitised from a real session that lost four
# mid-turn user messages (see tests/fixtures/midturn-session.jsonl).
test-condense:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT

    pass() { echo "PASS: $1"; }
    fail() { echo "FAIL: $1 - $2" >&2; exit 1; }

    FIXTURE="tests/fixtures/midturn-session.jsonl"
    out="$TMPROOT/extracted.txt"
    node hooks/condense.mjs extract "$FIXTURE" > "$out"

    # count_fixed <literal> -> number of lines containing it
    count_fixed() { grep -cF "$1" "$out" || true; }

    # --- Test 1: every mid-turn user message survives, labelled, exactly once ---
    # These four are verbatim from the session that regressed. Each arrives in a
    # different encoding: queue-operation + attachment, attachment only, and
    # queue-operation 'remove' with no attachment.
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
    node hooks/condense.mjs condense "$flood" 51200 > "$budgeted"
    raw_bytes=$(node hooks/condense.mjs extract "$flood" | wc -c | tr -d ' ')
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
    node hooks/condense.mjs condense "$many" 8192 > "$clamped"
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
    payload=$(jq -n --arg sid "$e2e_sid" --arg tp "$FIXTURE" --arg cwd "$e2e_cwd" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    hook_out=$(echo "$payload" | CLAUDE_WATCHDOG_LOG="$TMPROOT/hook.log" CLAUDE_WATCHDOG_TMP="$e2e_tmp" \
      CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
      CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 CLAUDE_WATCHDOG_VERBOSE=1 \
      node hooks/session-analysis.mjs 2>/dev/null)
    echo "$hook_out" | grep -q '"decision":"block"' || { cat "$TMPROOT/hook.log"; fail "e2e-trigger" "hook did not trigger"; }
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
    payload_a=$(jq -n --arg sid "$anchor_sid" --arg tp "$FIXTURE" --arg cwd "$deep" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload_a" | CLAUDE_WATCHDOG_LOG="$TMPROOT/anchor.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/atmp" \
      CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
      CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
      node hooks/session-analysis.mjs >/dev/null 2>&1
    [ -f "$repo/.claude/tmp/claude-watchdog/sessions/condensed-${anchor_sid}.txt" ] || { cat "$TMPROOT/anchor.log"; fail "anchor-root" "condensed not written to the project root"; }
    [ ! -d "$deep/.claude" ] || fail "anchor-subdir" "hook created .claude inside the subdirectory"
    grep -q "LOCAL_STORAGE: anchored to project root" "$TMPROOT/anchor.log" || fail "anchor-log" "no anchoring log line"
    pass "local-storage-anchors-to-project-root"

    # --- Test 14: a stray .claude in a subdirectory does not re-anchor there ---
    # The old bug left one behind; .git must still win, or the fix perpetuates it.
    stray_sid="condense-stray-$$"
    mkdir -p "$deep/.claude/tmp/claude-watchdog/sessions"
    payload_s=$(jq -n --arg sid "$stray_sid" --arg tp "$FIXTURE" --arg cwd "$deep" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload_s" | CLAUDE_WATCHDOG_LOG="$TMPROOT/stray.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/stmp" \
      CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
      CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
      node hooks/session-analysis.mjs >/dev/null 2>&1
    [ -f "$repo/.claude/tmp/claude-watchdog/sessions/condensed-${stray_sid}.txt" ] || { cat "$TMPROOT/stray.log"; fail "stray-claude-root" "did not anchor to the git root"; }
    [ ! -f "$deep/.claude/tmp/claude-watchdog/sessions/condensed-${stray_sid}.txt" ] || fail "stray-claude-subdir" "re-anchored to the stray .claude directory"
    pass "stray-claude-dir-does-not-win-over-git"

    # --- Test 15: no .git, but a .claude marker -> anchor there ---
    nogit_sid="condense-nogit-$$"
    nogit="$TMPROOT/no-git-project"
    mkdir -p "$nogit/.claude" "$nogit/nested/dir"
    payload_n=$(jq -n --arg sid "$nogit_sid" --arg tp "$FIXTURE" --arg cwd "$nogit/nested/dir" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload_n" | CLAUDE_WATCHDOG_LOG="$TMPROOT/nogit.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/ntmp" \
      CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
      CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
      node hooks/session-analysis.mjs >/dev/null 2>&1
    [ -f "$nogit/.claude/tmp/claude-watchdog/sessions/condensed-${nogit_sid}.txt" ] || { cat "$TMPROOT/nogit.log"; fail "nogit-claude" "did not anchor to the .claude marker"; }
    pass "claude-marker-anchors-when-no-git"

    # --- Test 16: no project marker -> cwd is used, as before ---
    plain_sid="condense-plain-$$"
    plain="$TMPROOT/no-markers/work"
    mkdir -p "$plain"
    payload_p=$(jq -n --arg sid "$plain_sid" --arg tp "$FIXTURE" --arg cwd "$plain" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload_p" | CLAUDE_WATCHDOG_LOG="$TMPROOT/plain.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/ptmp" \
      CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=1 \
      CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
      node hooks/session-analysis.mjs >/dev/null 2>&1
    [ -f "$plain/.claude/tmp/claude-watchdog/sessions/condensed-${plain_sid}.txt" ] || { cat "$TMPROOT/plain.log"; fail "no-marker-cwd" "condensed not written under the cwd"; }
    pass "no-marker-falls-back-to-cwd"

    echo "--- all condense tests passed ---"

# Test the UserPromptSubmit input-hold hook
test-hold:
    #!/usr/bin/env bash
    set -euo pipefail
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT
    export CLAUDE_WATCHDOG_TMP="$TMPROOT/tmp"
    export CLAUDE_WATCHDOG_LOG="$TMPROOT/log"
    SESSIONS="$CLAUDE_WATCHDOG_TMP/sessions"
    mkdir -p "$SESSIONS"

    pass() { echo "PASS: $1"; }
    fail() { echo "FAIL: $1 - $2" >&2; exit 1; }

    mk_payload() { jq -n --arg sid "$1" '{session_id:$sid, hook_event_name:"UserPromptSubmit", cwd:"/tmp"}'; }
    now_iso() { node -e 'process.stdout.write(new Date().toISOString())'; }
    # 400s in the past: safely beyond the 240s default TTL, portable across Linux/macOS
    old_iso() { node -e 'process.stdout.write(new Date(Date.now() - 400000).toISOString())'; }

    # --- Test 1: option off -> allow even with a fresh sentinel present ---
    sid1="hold-t1-$$"
    printf '%s\n' "$(now_iso)" > "$SESSIONS/pending-${sid1}"
    out=$(mk_payload "$sid1" | node hooks/hold-input.mjs)
    [ -z "$out" ] || fail "default-off" "expected empty stdout, got '$out'"
    [ -f "$SESSIONS/pending-${sid1}" ] || fail "default-off-sentinel" "sentinel must be left untouched"
    pass "default-off"

    # --- Test 2: option on, no sentinel -> allow ---
    sid2="hold-t2-$$"
    out=$(mk_payload "$sid2" | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs)
    [ -z "$out" ] || fail "no-sentinel" "expected empty stdout, got '$out'"
    pass "no-sentinel-allows"

    # --- Test 3: fresh sentinel -> block and mark nudged ---
    sid3="hold-t3-$$"
    printf '%s\n' "$(now_iso)" > "$SESSIONS/pending-${sid3}"
    out=$(mk_payload "$sid3" | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs)
    echo "$out" | grep -q '"decision":"block"' || fail "fresh-blocks" "expected decision:block, got '$out'"
    sed -n '2p' "$SESSIONS/pending-${sid3}" | grep -qx 'nudged' || fail "fresh-nudged" "sentinel not marked nudged"
    grep -q "HOLD: blocked prompt" "$CLAUDE_WATCHDOG_LOG" || fail "fresh-log" "no HOLD log"
    pass "fresh-sentinel-blocks"

    # --- Test 4: nudged sentinel -> next prompt overrides and releases ---
    out=$(mk_payload "$sid3" | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs)
    [ -z "$out" ] || fail "override" "expected empty stdout, got '$out'"
    [ ! -f "$SESSIONS/pending-${sid3}" ] || fail "override-cleared" "sentinel should be deleted"
    grep -q "RELEASE: user override" "$CLAUDE_WATCHDOG_LOG" || fail "override-log" "no override log"
    pass "override-releases"

    # --- Test 5: expired sentinel -> TTL releases ---
    sid5="hold-t5-$$"
    printf '%s\n' "$(old_iso)" > "$SESSIONS/pending-${sid5}"
    out=$(mk_payload "$sid5" | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs)
    [ -z "$out" ] || fail "ttl" "expected empty stdout, got '$out'"
    [ ! -f "$SESSIONS/pending-${sid5}" ] || fail "ttl-cleared" "sentinel should be deleted"
    grep -q "RELEASE: hold expired" "$CLAUDE_WATCHDOG_LOG" || fail "ttl-log" "no expiry log"
    pass "ttl-expiry-releases"

    # --- Test 6: fail-open on garbage stdin ---
    rc=0
    out=$(echo "not json" | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs) || rc=$?
    [ "$rc" -eq 0 ] || fail "fail-open-exit" "expected exit 0, got $rc"
    [ -z "$out" ] || fail "fail-open-stdout" "expected empty stdout, got '$out'"
    pass "fail-open"

    # --- Test 7: invalid session_id -> allow, no shell injection surface ---
    rc=0
    out=$(jq -n '{session_id:"evil; rm -rf /"}' | CLAUDE_WATCHDOG_HOLD_INPUT=1 node hooks/hold-input.mjs) || rc=$?
    [ "$rc" -eq 0 ] || fail "bad-sid-exit" "expected exit 0, got $rc"
    [ -z "$out" ] || fail "bad-sid-stdout" "expected empty stdout, got '$out'"
    pass "invalid-session-id"

    echo "--- all hold tests passed ---"

# Every transcript label condense.mjs emits must be documented in the analyzer prompt,
# and the prompt assembly must hand the analyzer the final assistant message.
# Labels are derived from the source, so a new output.push label fails here until the prompt covers it.
test-agent-prompt:
    #!/usr/bin/env bash
    set -euo pipefail
    src="hooks/condense.mjs"
    prompt="agents/session-analyzer.md"
    labels=$( {
      # literal prefix of each output.push template, cut at the first ':' or '[' (inclusive)
      grep -oE 'output\.push\(`[^`$]+' "$src" | sed -E 's/^output\.push\(`//; s/^([^:[]*[:[]).*/\1/'
      # USER label string constants (USER, USER (mid-turn), ...)
      grep -oE "'USER[^']*'" "$src" | tr -d "'"
      grep -oE '`\[TRUNCATED\]' "$src" | tr -d '`'
    } | sed 's/ *$//' | sort -u )
    [ "$(echo "$labels" | wc -l)" -ge 8 ] || { echo "FAIL: label extraction found too few labels:"; echo "$labels"; exit 1; }
    rc=0
    while IFS= read -r label; do
      if grep -qF -- "$label" "$prompt"; then echo "PASS: $label"; else echo "FAIL: $label missing from $prompt" >&2; rc=1; fi
    done <<< "$labels"

    # --- The condensed file the hook writes must end with the final assistant message ---
    # The delta ends on tool results, so without this the analyzer is asked to judge
    # whether the deliverable was produced while never being shown it.
    TMPROOT=$(mktemp -d)
    trap 'rm -rf "$TMPROOT"' EXIT
    FIXTURE="tests/fixtures/midturn-session.jsonl"
    HEADER='=== FINAL ASSISTANT MESSAGE (session ended here) ==='
    FINAL_TEXT='Renamed the stack components to bre-remote-cache and pushed the branch.'

    run_hook() { # run_hook <session-id> <payload-json> -> echoes condensed file path
      local sid="$1" payload="$2" tmp="$TMPROOT/w-$1"
      echo "$payload" | CLAUDE_WATCHDOG_LOG="$TMPROOT/hook-$sid.log" CLAUDE_WATCHDOG_TMP="$tmp" \
        CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
        CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
        node hooks/session-analysis.mjs >/dev/null 2>&1
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
    payload2=$(jq -n --arg sid "$sid2" --arg tp "$FIXTURE" --arg cwd "$cwd" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    f2=$(run_hook "$sid2" "$payload2")
    if [ -f "$f2" ] && grep -qF "$HEADER" "$f2"; then
      echo "FAIL: header emitted with no last_assistant_message" >&2; rc=1
    else
      echo "PASS: no final-message header when the event carries none"
    fi
    exit $rc

# Run all tests
test: smoke test-cursor test-condense test-persist test-hold test-agent-prompt

# Lint + all tests
check: lint test

# Create a release: just release [patch|minor|major]
release segment="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    manifest=".claude-plugin/plugin.json"
    latest=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    IFS='.' read -r major minor patch <<< "${latest#v}"
    case "{{segment}}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "Usage: just release [patch|minor|major]"; exit 1 ;;
    esac
    new="v${major}.${minor}.${patch}"
    bare="${new#v}"
    jq --arg v "$bare" '.version = $v' "$manifest" > "${manifest}.tmp" && mv "${manifest}.tmp" "$manifest"
    git add "$manifest"
    git commit -m "release: bump version to ${bare}"
    echo "Tagging ${latest} -> ${new}"
    git tag -a "$new" -m "Release ${new}"
    git push origin HEAD --follow-tags
    echo "Released ${new}"

# Install instructions
install-hint:
    @echo "In Claude Code, run:"
    @echo "  /plugin marketplace add Temikus/claude-plugins"
    @echo "  /plugin install claude-watchdog@temikus"

# Install the current working copy locally via a transient marketplace.
# Uninstall with `just uninstall-dev`. Restart Claude Code after running.
install-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    MP_NAME="claude-watchdog-dev"
    MP_DIR="${TMPDIR:-/tmp}/${MP_NAME}-marketplace"
    rm -rf "$MP_DIR"
    mkdir -p "$MP_DIR/.claude-plugin"
    # Symlink the plugin into the marketplace tree so the marketplace source
    # can be a relative path (which is what the schema validator accepts).
    ln -s "$PWD" "$MP_DIR/claude-watchdog"
    jq -n --arg name "$MP_NAME" '{
      name: $name,
      owner: {name: "local-dev"},
      plugins: [{
        name: "claude-watchdog",
        description: "Local dev build (transient)",
        source: "./claude-watchdog"
      }]
    }' > "$MP_DIR/.claude-plugin/marketplace.json"
    # Refresh: remove prior install + marketplace if present (idempotent)
    claude plugin uninstall "claude-watchdog@${MP_NAME}" 2>/dev/null || true
    claude plugin marketplace remove "$MP_NAME" 2>/dev/null || true
    claude plugin marketplace add "$MP_DIR"
    claude plugin install "claude-watchdog@${MP_NAME}" --scope user
    echo ""
    echo "Installed claude-watchdog from $PWD via transient marketplace '$MP_NAME'."
    echo "Restart Claude Code to pick up the new hook."
    echo "Run 'just uninstall-dev' to clean up."

# Install the published version from the Temikus/claude-plugins marketplace
install-public:
    #!/usr/bin/env bash
    set -euo pipefail
    MP_NAME="temikus"
    # Refresh: remove prior install if present (idempotent)
    claude plugin uninstall "claude-watchdog@${MP_NAME}" 2>/dev/null || true
    # Add marketplace if not already registered
    if ! claude plugin marketplace list 2>/dev/null | grep -q "^  ❯ ${MP_NAME}$"; then
      claude plugin marketplace add "Temikus/claude-plugins"
    fi
    claude plugin install "claude-watchdog@${MP_NAME}" --scope user
    echo ""
    echo "Installed claude-watchdog from Temikus/claude-plugins marketplace."
    echo "Restart Claude Code to pick up the plugin."
    echo "Run 'just uninstall-public' to remove."

# Remove the public install (keeps the marketplace registered)
uninstall-public:
    #!/usr/bin/env bash
    set -euo pipefail
    claude plugin uninstall "claude-watchdog@temikus" 2>/dev/null || true
    echo "Removed public install. Restart Claude Code."

# Remove the dev install (and its transient marketplace)
uninstall-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    MP_NAME="claude-watchdog-dev"
    MP_DIR="${TMPDIR:-/tmp}/${MP_NAME}-marketplace"
    claude plugin uninstall "claude-watchdog@${MP_NAME}" 2>/dev/null || true
    claude plugin marketplace remove "$MP_NAME" 2>/dev/null || true
    rm -rf "$MP_DIR"
    echo "Removed dev install. Restart Claude Code."
