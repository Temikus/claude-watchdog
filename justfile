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
    trap 'rm -rf "$tmpdir"; rmdir "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-${session_id}" 2>/dev/null; rm -f "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-condensed-${session_id}.txt" "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-raw-${session_id}.txt"' EXIT
    transcript="$tmpdir/transcript.jsonl"
    for i in $(seq 1 5); do
      printf '{"type":"user","message":{"content":"do task %s"}}\n' "$i" >> "$transcript"
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Working on task %s"},{"type":"tool_use","id":"toolu_%s","name":"Read","input":{"file_path":"/tmp/test"}}]}}\n' "$i" "$i" >> "$transcript"
      printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_%s","content":"file contents here"}]}}\n' "$i" >> "$transcript"
    done
    payload=$(jq -n --arg sid "$session_id" --arg tp "$transcript" --arg cwd "$PWD" \
      '{session_id:$sid, transcript_path:$tp, cwd:$cwd, stop_reason:"end_turn"}')
    echo "$payload" | CLAUDE_WATCHDOG_LOG="$tmpdir/log" bash hooks/session-analysis.sh && rc=$? || rc=$?
    echo "hook exit: $rc (expected 2)"
    echo "--- log ---"
    cat "$tmpdir/log"
    echo "--- condensed ---"
    cat "$HOME/.claude/tmp/claude-watchdog/claude-watchdog-condensed-${session_id}.txt" 2>/dev/null || echo "(not found)"
    [ "$rc" -eq 2 ] || { echo "FAIL: expected exit 2, got $rc"; exit 1; }

# Run all tests
test: smoke

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
