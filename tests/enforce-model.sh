#!/usr/bin/env bash
# The PreToolUse pinned-subagent-model hook.
#
# Agent definitions are real .md files under a hermetic $HOME and
# $CLAUDE_PROJECT_DIR, so the frontmatter reader and the lookup order are
# exercised end to end rather than stubbed.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

GHOME="$TMPROOT/home"
PROJ="$TMPROOT/project"
HOME_AGENTS="$GHOME/.claude/agents"
PROJ_AGENTS="$PROJ/.claude/agents"
mkdir -p "$HOME_AGENTS" "$PROJ_AGENTS"
LOG="$TMPROOT/log"

base_env() {
  echo "HOME=$GHOME" "CLAUDE_PROJECT_DIR=$PROJ" "CLAUDE_WATCHDOG_LOG=$LOG"
}

# enforce <payload> [ENV=VAL ...] - runs with the hermetic env prepended.
enforce() {
  local payload="$1"; shift
  # shellcheck disable=SC2046  # deliberate word splitting of the env list
  run_enforce "$payload" $(base_env) "$@"
}

mk_payload() {
  local tool="$1" subagent="$2" model="${3:-}"
  jq -n --arg tool "$tool" --arg sa "$subagent" --arg m "$model" \
    '{hook_event_name:"PreToolUse", tool_name:$tool,
      tool_input: ({subagent_type:$sa} + (if $m == "" then {} else {model:$m} end))}'
}

allow() {
  local name="$1"
  [ "$ENFORCE_RC" -eq 0 ] || fail "$name" "expected exit 0, got $ENFORCE_RC (stderr: $ENFORCE_ERR)"
  [ -z "$ENFORCE_ERR" ] || fail "$name" "expected empty stderr, got '$ENFORCE_ERR'"
  pass "$name"
}

# Agent fixtures.
printf -- '---\nname: pinned\nmodel: opus\n---\nbody\n' > "$HOME_AGENTS/pinned.md"
printf -- '---\nname: inheriting\nmodel: inherit\n---\n' > "$HOME_AGENTS/inheriting.md"
printf -- '---\nname: shouty\nmodel: INHERIT\n---\n' > "$HOME_AGENTS/shouty.md"
printf -- '---\nname: unpinned\ndescription: no model key\n---\n' > "$HOME_AGENTS/unpinned.md"
printf -- '---\nname: quoted\nmodel: "haiku"\n---\n' > "$HOME_AGENTS/quoted.md"
printf -- '---\r\nname: crlf\r\nmodel: sonnet\r\n---\r\n' > "$HOME_AGENTS/crlf.md"
printf -- '---\nname: shadowed\nmodel: haiku\n---\n' > "$HOME_AGENTS/shadowed.md"
printf -- '---\nname: shadowed\nmodel: opus\n---\n' > "$PROJ_AGENTS/shadowed.md"
mkdir -p "$PROJ_AGENTS/nested"
printf -- '---\nname: nested\nmodel: sonnet\n---\n' > "$PROJ_AGENTS/nested/nested.md"
# A `model:` outside the frontmatter block must not be read as a pin.
printf -- '---\nname: bodyonly\n---\nmodel: opus\n' > "$HOME_AGENTS/bodyonly.md"

# --- Test 1: flag off (the default) -> allow even a pinned agent ---
enforce "$(mk_payload Agent pinned)"
allow "default-off-allows"

# --- Test 2: flag on, non-dispatch tool -> allow ---
enforce "$(mk_payload Read pinned)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
allow "other-tool-allows"

# --- Test 3: flag on, pinned agent, no model -> block with the exact message ---
expected="BLOCKED: 'pinned' is pinned (model: opus) but this dispatch has no explicit 'model'. Re-dispatch with model: \"opus\". A deliberate different model also passes, but it must be explicit."
enforce "$(mk_payload Agent pinned)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
[ "$ENFORCE_RC" -eq 2 ] || fail "pinned-blocks" "expected exit 2, got $ENFORCE_RC"
[ "$ENFORCE_ERR" = "$expected" ] || fail "pinned-blocks-message" "got '$ENFORCE_ERR'"
[ -z "$ENFORCE_OUT" ] || fail "pinned-blocks-stdout" "expected empty stdout, got '$ENFORCE_OUT'"
grep -q "BLOCK: 'pinned' pinned to opus" "$LOG" || fail "pinned-blocks-log" "no BLOCK log line"
pass "pinned-blocks"

# --- Test 4: Task is enforced the same as Agent ---
enforce "$(mk_payload Task pinned)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
[ "$ENFORCE_RC" -eq 2 ] || fail "task-blocks" "expected exit 2, got $ENFORCE_RC"
pass "task-tool-blocks"

# --- Test 5: the plugin-config variable enables it too ---
enforce "$(mk_payload Agent pinned)" CLAUDE_PLUGIN_OPTION_ENFORCE_SUBAGENT_MODEL=true
[ "$ENFORCE_RC" -eq 2 ] || fail "plugin-option" "expected exit 2, got $ENFORCE_RC"
pass "plugin-option-enables"

# --- Test 6: explicit model -> allow, even a different one ---
enforce "$(mk_payload Agent pinned haiku)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
allow "explicit-model-allows"

# --- Test 7: inherit / INHERIT / no model key -> allow ---
for agent in inheriting shouty unpinned bodyonly; do
  enforce "$(mk_payload Agent "$agent")" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
  allow "unpinned-allows-$agent"
done

# --- Test 8: no subagent_type, or an unknown one -> allow ---
enforce "$(mk_payload Agent "")" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
allow "no-subagent-type-allows"
enforce "$(mk_payload Agent no-such-agent)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
allow "unknown-agent-allows"

# --- Test 9: path-ish subagent_type is refused before any lookup ---
printf -- '---\nname: evil\nmodel: opus\n---\n' > "$TMPROOT/evil.md"
printf -- '---\nname: hidden\nmodel: opus\n---\n' > "$HOME_AGENTS/.hidden.md"
for evil in "../evil" "nested/nested" ".hidden"; do
  enforce "$(mk_payload Agent "$evil")" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
  allow "path-traversal-allows-$evil"
done

# --- Test 10: project agents shadow personal ones ---
enforce "$(mk_payload Agent shadowed)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
[ "$ENFORCE_RC" -eq 2 ] || fail "shadowing" "expected exit 2, got $ENFORCE_RC"
case "$ENFORCE_ERR" in
  *"model: opus"*) ;;
  *) fail "shadowing" "project agent should win, got '$ENFORCE_ERR'" ;;
esac
pass "project-agent-shadows-home"

# --- Test 11: <agent>/<agent>.md is found ---
enforce "$(mk_payload Agent nested)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
[ "$ENFORCE_RC" -eq 2 ] || fail "nested-layout" "expected exit 2, got $ENFORCE_RC"
pass "nested-agent-layout"

# --- Test 12: quoted and CRLF frontmatter parse to a bare model name ---
enforce "$(mk_payload Agent quoted)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
case "$ENFORCE_ERR" in *"model: haiku)"*) ;; *) fail "quoted" "got '$ENFORCE_ERR'" ;; esac
pass "quoted-model-parses"
enforce "$(mk_payload Agent crlf)" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
case "$ENFORCE_ERR" in *"model: sonnet)"*) ;; *) fail "crlf" "got '$ENFORCE_ERR'" ;; esac
pass "crlf-frontmatter-parses"

# --- Test 13: fail-open on garbage stdin ---
enforce "not json" CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL=1
[ "$ENFORCE_RC" -eq 0 ] || fail "fail-open" "expected exit 0, got $ENFORCE_RC"
pass "fail-open"

echo "All enforce-model tests passed."
