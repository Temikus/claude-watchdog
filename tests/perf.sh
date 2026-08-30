#!/usr/bin/env bash
# Perf budgets. Separate from `just test` - run with `just test-perf`.
#
# Startup cost is one of the motivations for porting the hooks off Node, so
# these numbers are the before/after measurement as much as they are a gate.
# Budgets are deliberately loose relative to the README's claims: they catch an
# order-of-magnitude regression, not a 10% one, so they do not flake on CI.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# elapsed_ms <cmd...> -> wall-clock milliseconds. Uses the bash `time` keyword
# so no clock subprocess is forked into the measurement; `date +%s%N` is not
# portable to macOS.
elapsed_ms() {
  local t
  TIMEFORMAT='%3R'
  t=$( { time "$@" >/dev/null 2>&1; } 2>&1 )
  t="${t//./}"          # 0.123 -> 0123, 1.234 -> 1234 (always 3 decimals)
  t="${t#"${t%%[1-9]*}"}"  # strip leading zeros
  echo "${t:-0}"
}

# --- Budget 1: the hold hook runs on every prompt -> < 100 ms ---
# Measured with the option enabled (the path that actually touches the
# filesystem); the default-off path can only be faster. Best of 10 runs, so a
# scheduler hiccup on a shared CI runner does not fail the build.
HOLD_BUDGET_MS=100
hold_payload="$TMPROOT/hold.json"
jq -n --arg sid "perf-hold-$$" '{session_id:$sid, hook_event_name:"UserPromptSubmit", cwd:"/tmp"}' > "$hold_payload"
best=99999
for _ in $(seq 1 10); do
  ms=$(elapsed_ms env CLAUDE_WATCHDOG_HOLD_INPUT=1 CLAUDE_WATCHDOG_TMP="$TMPROOT/htmp" \
    CLAUDE_WATCHDOG_LOG="$TMPROOT/hold.log" "${HOOK_HOLD_CMD[@]}" < "$hold_payload")
  if [ "$ms" -lt "$best" ]; then best="$ms"; fi
done
echo "hold hook: ${best} ms (budget ${HOLD_BUDGET_MS} ms)"
[ "$best" -lt "$HOLD_BUDGET_MS" ] || fail "hold-perf" "hold hook took ${best} ms, budget is ${HOLD_BUDGET_MS} ms"
pass "hold-hook-under-${HOLD_BUDGET_MS}ms"

# --- Budget 2: the Stop hook on a 5 MB transcript -> < 2 s ---
STOP_BUDGET_MS=2000
big="$TMPROOT/big.jsonl"
awk 'BEGIN {
  pad = ""
  for (i = 0; i < 200; i++) pad = pad "x"
  for (i = 1; i <= 7800; i++) {
    printf "{\"type\":\"user\",\"uuid\":\"u-p%d\",\"message\":{\"content\":\"ask %d %s\"}}\n", i, i, pad
    printf "{\"type\":\"assistant\",\"uuid\":\"a-p%d\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply %d %s\"},{\"type\":\"tool_use\",\"id\":\"t_p%d\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/tmp/x\",\"old_string\":\"a\",\"new_string\":\"b\"}}]}}\n", i, i, pad, i
  }
}' > "$big"
size=$(wc -c < "$big" | tr -d ' ')
[ "$size" -ge 5242880 ] || fail "perf-fixture" "generated transcript is ${size} B, expected at least 5 MB"
echo "transcript: ${size} bytes"

perf_sid="perf-stop-$$"
payload="$TMPROOT/stop.json"
stop_payload "$perf_sid" "$big" "$TMPROOT" > "$payload"
ms=$(elapsed_ms env CLAUDE_WATCHDOG_LOG="$TMPROOT/stop.log" CLAUDE_WATCHDOG_TMP="$TMPROOT/stmp" \
  CLAUDE_WATCHDOG_ANALYSES_DIR="$TMPROOT/analyses" CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE=0 \
  CLAUDE_WATCHDOG_MIN_TOOL_USES=3 CLAUDE_WATCHDOG_COOLDOWN_SECONDS=0 \
  "${HOOK_STOP_CMD[@]}" < "$payload")
# The measurement is only meaningful if the hook actually did the work rather
# than short-circuiting on a gate.
grep -q "TRIGGER:" "$TMPROOT/stop.log" || { cat "$TMPROOT/stop.log"; fail "stop-perf-trigger" "hook skipped instead of analysing the 5 MB transcript"; }
echo "stop hook on 5 MB: ${ms} ms (budget ${STOP_BUDGET_MS} ms)"
[ "$ms" -lt "$STOP_BUDGET_MS" ] || fail "stop-perf" "Stop hook took ${ms} ms on a 5 MB transcript, budget is ${STOP_BUDGET_MS} ms"
pass "stop-hook-5mb-under-${STOP_BUDGET_MS}ms"

echo "--- all perf budgets met ---"
