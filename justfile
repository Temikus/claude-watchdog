set shell := ["bash", "-uc"]

default:
    @just --list

# Validate JSON manifests and bash syntax
lint:
    jq empty .claude-plugin/plugin.json
    jq empty hooks/hooks.json
    bash -n hooks/session-analysis.sh

# Smoke-test the hook with a synthetic Stop event
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    tmpdir=$(mktemp -d)
    session_id="smoketest-$$"
    sessions="$HOME/.claude/tmp/claude-watchdog/sessions"
    trap 'rm -rf "$tmpdir"; rmdir "$sessions/${session_id}" 2>/dev/null || true; rm -f "$sessions/condensed-${session_id}.txt" "$sessions/raw-${session_id}.txt" "$sessions/cursor-${session_id}.txt" "$sessions/delta-${session_id}.tmp" "$HOME/.claude/logs/claude-watchdog-analyses/${session_id}-"*.md 2>/dev/null || true' EXIT
    transcript="$tmpdir/transcript.jsonl"
    for i in $(seq 1 5); do
      printf '{"type":"user","message":{"content":"do task %s"}}\n' "$i" >> "$transcript"
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on task %s"},{"type":"tool_use","id":"toolu_%s","name":"Read","input":{"file_path":"/tmp/test"}}]}}\n' "$i" "$i" >> "$transcript"
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_%s","content":"file contents here"}]}}\n' "$i" >> "$transcript"
    done
    payload=$(jq -n --arg sid "$session_id" --arg tp "$transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload" | CLAUDE_WATCHDOG_LOG="$tmpdir/log" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 bash hooks/session-analysis.sh && rc=$? || rc=$?
    echo "hook exit: $rc (expected 2)"
    echo "--- log ---"
    cat "$tmpdir/log"
    echo "--- condensed ---"
    cat "$sessions/condensed-${session_id}.txt" 2>/dev/null || echo "(not found)"
    [ "$rc" -eq 2 ] || { echo "FAIL: expected exit 2, got $rc"; exit 1; }

# Cursor / delta-analysis behaviour tests
test-cursor:
    #!/usr/bin/env bash
    set -euo pipefail
    export WATCHDOG_DIR="$HOME/.claude/tmp/claude-watchdog/sessions"
    mkdir -p "$WATCHDOG_DIR"

    mk_msg() {
      # $1 type (user|assistant), $2 uuid, $3 text (for user: plain; for assistant: text block + tool_use)
      local kind="$1" uuid="$2" text="$3"
      if [ "$kind" = "user" ]; then
        jq -nc --arg u "$uuid" --arg t "$text" '{type:"user",uuid:$u,message:{content:$t}}'
      else
        jq -nc --arg u "$uuid" --arg t "$text" '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:$t},{type:"tool_use",id:("t_"+$u),name:"Read",input:{file_path:"/tmp/x"}}]}}'
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

    run_hook() {
      # $1 session_id, $2 transcript_path -> prints "<exit_code>"
      local sid="$1" tp="$2"
      local payload
      payload=$(jq -n --arg sid "$sid" --arg tp "$tp" --arg cwd "$PWD" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
      local rc=0
      echo "$payload" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 bash hooks/session-analysis.sh >/dev/null 2>&1 || rc=$?
      echo "$rc"
    }

    cleanup_session() {
      local sid="$1"
      rm -f "$WATCHDOG_DIR/cursor-${sid}.txt" \
            "$WATCHDOG_DIR/condensed-${sid}.txt" \
            "$WATCHDOG_DIR/raw-${sid}.txt" \
            "$WATCHDOG_DIR/delta-${sid}.tmp" \
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
    rc=$(run_hook "$sid2" "$t2_transcript")
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "first-run-exit" "expected 2 got $rc"; }
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
    rc=$(run_hook "$sid3" "$t3_transcript")
    [ "$rc" = "0" ] || { cat "$TEST_LOG"; fail "trivial-delta-exit" "expected 0 got $rc"; }
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
    rc=$(run_hook "$sid4" "$t4_transcript")
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "substantial-delta-exit" "expected 2 got $rc"; }
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
    rc=$(run_hook "$sid5" "$t5_transcript")
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "stale-transcript-exit" "expected 2 got $rc"; }
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
    rc=$(run_hook "$sid6" "$t6_transcript")
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "uuid-fallback-exit" "expected 2 got $rc"; }
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
    rc=$(run_hook "$sid7" "$t7_transcript")
    [ "$rc" = "0" ] || { cat "$TEST_LOG"; fail "concurrency-exit" "expected 0 got $rc"; }
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
    rc=$(run_hook "$sid9" "$t9_transcript")
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "malformed-cursor-exit" "expected 2 got $rc"; }
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
    echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=60 bash hooks/session-analysis.sh >/dev/null 2>&1 || rc=$?
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "cooldown-first-run" "expected 2 got $rc"; }
    # Append enough new tool uses to clear MIN_TOOL_USES
    for i in 1 2 3; do
      mk_msg user "u-COOL-$i" "COOL user $i" >> "$t10_transcript"
      mk_msg assistant "a-COOL-$i" "COOL assistant $i" >> "$t10_transcript"
    done
    # Second run: cursor mtime is fresh, cooldown=60s should skip
    rc=0
    echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=60 bash hooks/session-analysis.sh >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || { cat "$TEST_LOG"; fail "cooldown-second-run" "expected 0 got $rc"; }
    grep -q "SKIP: cooldown active" "$TEST_LOG" || fail "cooldown-log" "no cooldown log"
    # Third run with cooldown=0 should trigger again, proving the gate is the only thing blocking
    rc=0
    echo "$payload10" | CLAUDE_WATCHDOG_LOG="$TEST_LOG" CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 bash hooks/session-analysis.sh >/dev/null 2>&1 || rc=$?
    [ "$rc" = "2" ] || { cat "$TEST_LOG"; fail "cooldown-disabled" "expected 2 got $rc"; }
    cleanup_session "$sid10"
    pass "cooldown"

    echo "--- all cursor tests passed ---"

# Run all tests
test: smoke test-cursor

# Lint + all tests
check: lint test

# Create a release: just release [patch|minor|major]
release segment="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    latest=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    IFS='.' read -r major minor patch <<< "${latest#v}"
    case "{{segment}}" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) echo "Usage: just release [patch|minor|major]"; exit 1 ;;
    esac
    new="v${major}.${minor}.${patch}"
    echo "Tagging ${latest} -> ${new}"
    git tag -a "$new" -m "Release ${new}"
    git push origin "$new"
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
