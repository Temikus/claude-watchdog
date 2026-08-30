# shellcheck shell=bash
# Shared harness for the claude-watchdog test suite.
#
# Source this from tests/*.sh. It is not executable on its own.
#
# Implementation-agnostic by design: every hook invocation goes through the
# HOOK_* variables below, so a port can run the same suite unchanged with
#
#   HOOK_STOP=./bin/watchdog-stop HOOK_HOLD=./bin/watchdog-hold \
#   HOOK_PERSIST=./bin/watchdog-persist HOOK_CONDENSE=./bin/watchdog \
#   just test
#
# Nothing in tests/ may reference `node` or `hooks/*.mjs` directly.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The suite passes every setting explicitly per invocation. A CLAUDE_WATCHDOG_*
# left in the ambient environment (a plugin config, an export for a capture run)
# would otherwise reach the hooks and fail tests that never opted into it.
while IFS='=' read -r _var _; do
  case "$_var" in CLAUDE_WATCHDOG_*) unset "$_var" ;; esac
done < <(env)

: "${HOOK_STOP:=node hooks/session-analysis.mjs}"
: "${HOOK_HOLD:=node hooks/hold-input.mjs}"
: "${HOOK_PERSIST:=node hooks/persist-analysis.mjs}"
# Debug CLI: `<binary> condense <jsonl> [bytes]` / `<binary> extract <jsonl>`.
# See tests/CONDENSE-CLI.md - this is a supported interface, not an internal.
: "${HOOK_CONDENSE:=node hooks/condense.mjs}"

read -r -a HOOK_STOP_CMD <<< "$HOOK_STOP"
read -r -a HOOK_HOLD_CMD <<< "$HOOK_HOLD"
read -r -a HOOK_PERSIST_CMD <<< "$HOOK_PERSIST"
read -r -a HOOK_CONDENSE_CMD <<< "$HOOK_CONDENSE"

FIXTURE="${FIXTURE:-tests/fixtures/midturn-session.jsonl}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 - $2" >&2; exit 1; }

# --- hook invocation -------------------------------------------------------
#
# run_stop <payload-json> [ENV=VAL ...]
#   Feeds the payload on stdin. Sets STOP_OUT (stdout, stderr discarded) and
#   STOP_RC. Never aborts on a non-zero exit; assert on STOP_RC instead.
STOP_OUT=""; STOP_RC=0
run_stop() {
  local payload="$1"; shift
  STOP_RC=0
  # shellcheck disable=SC2034  # read by the sourcing test scripts
  STOP_OUT=$(printf '%s' "$payload" | env ${1+"$@"} "${HOOK_STOP_CMD[@]}" 2>/dev/null) || STOP_RC=$?
}

HOLD_OUT=""; HOLD_RC=0
run_hold() {
  local payload="$1"; shift
  HOLD_RC=0
  # shellcheck disable=SC2034  # read by the sourcing test scripts
  HOLD_OUT=$(printf '%s' "$payload" | env ${1+"$@"} "${HOOK_HOLD_CMD[@]}" 2>/dev/null) || HOLD_RC=$?
}

PERSIST_OUT=""; PERSIST_RC=0
run_persist() {
  local payload="$1"; shift
  PERSIST_RC=0
  # shellcheck disable=SC2034  # read by the sourcing test scripts
  PERSIST_OUT=$(printf '%s' "$payload" | env ${1+"$@"} "${HOOK_PERSIST_CMD[@]}" 2>/dev/null) || PERSIST_RC=$?
}

run_condense() { "${HOOK_CONDENSE_CMD[@]}" "$@"; }

# Classify a Stop-hook result by its wire protocol: "analyze this session" is a
# JSON `decision:block` on stdout with exit 0 (BLOCK); any other clean exit is a
# skip (SKIP); a non-zero exit surfaces as ERR:<code>.
outcome() {
  local out="$1" rc="$2"
  if [ "$rc" -ne 0 ]; then
    echo "ERR:$rc"
  elif printf '%s' "$out" | grep -q '"decision":"block"'; then
    echo BLOCK
  else
    echo SKIP
  fi
}

# --- payloads and transcripts ----------------------------------------------

# event_fixture <name> [jq-object-fragment]
# Loads tests/fixtures/events/<name>.json as the base event, strips the
# `_fixture` provenance block, and merges the fragment over it. Tests build
# payloads from these files rather than from inline literals so that replacing a
# reconstructed fixture with a real capture updates the whole suite at once.
# See tests/fixtures/CAPTURE.md.
event_fixture() {
  local name="$1" extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -c "with_entries(select(.key | startswith(\"_\") | not)) + $extra" \
    "tests/fixtures/events/${name}.json"
}

# stop_payload <session-id> <transcript-path> <cwd> [jq-object-fragment]
# Layered over the stop-plain event fixture, so every Stop-hook test runs
# against the real event shape rather than a four-field literal. The fragment is
# a jq object expression merged last, e.g. '{stop_hook_active:true}'.
stop_payload() {
  local sid="$1" tp="$2" cwd="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  event_fixture stop-plain \
    "$(jq -n --arg sid "$sid" --arg tp "$tp" --arg cwd "$cwd" \
        '{session_id:$sid, transcript_path:$tp, cwd:$cwd}')  + $extra"
}

# mk_msg <user|assistant> <uuid> <text>
# An assistant message carries a text block plus one Edit tool_use, so message
# count and tool-use count move together.
mk_msg() {
  local kind="$1" uuid="$2" text="$3"
  if [ "$kind" = "user" ]; then
    jq -nc --arg u "$uuid" --arg t "$text" '{type:"user",uuid:$u,message:{content:$t}}'
  else
    jq -nc --arg u "$uuid" --arg t "$text" '{type:"assistant",uuid:$u,message:{content:[{type:"text",text:$t},{type:"tool_use",id:("t_"+$u),name:"Edit",input:{file_path:"/tmp/x",old_string:"a",new_string:"b"}}]}}'
  fi
}

# mk_transcript <path> <start> <end> <marker> - truncates and writes N rounds
mk_transcript() {
  local path="$1" start="$2" end="$3" marker="$4" i
  : > "$path"
  for i in $(seq "$start" "$end"); do
    mk_msg user "u-${marker}-${i}" "${marker} user ${i}" >> "$path"
    mk_msg assistant "a-${marker}-${i}" "${marker} assistant ${i}" >> "$path"
  done
}

# --- portable time ---------------------------------------------------------

# iso_now / iso_ago <seconds> - UTC ISO 8601, GNU and BSD date.
iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_ago() {
  local secs="$1" epoch
  epoch=$(( $(date +%s) - secs ))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}
