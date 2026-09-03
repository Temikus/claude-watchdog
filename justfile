set shell := ["bash", "-uc"]

default:
    @just --list

# Validate JSON manifests, shell scripts, justfile formatting, and JS syntax
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    jq empty .claude-plugin/plugin.json
    jq empty hooks/hooks.json
    # Syntax check for the current implementation. A port swaps this line for
    # whatever its own compiler/checker is; nothing else in the suite is
    # implementation-specific.
    for f in hooks/*.mjs; do node --check "$f"; done
    shellcheck -x tests/*.sh
    just --fmt --check
    # Fixture validation without a JS runtime: every JSON line must parse.
    for f in tests/fixtures/*.jsonl; do
      n=0
      while IFS= read -r line; do
        n=$((n + 1))
        case "$line" in "{"*) ;; *) continue ;; esac
        printf '%s\n' "$line" | jq -c . > /dev/null || { echo "$f:$n: invalid JSON"; exit 1; }
      done < "$f"
    done

# The suite lives in tests/*.sh; these recipes are thin wrappers so `just test`
# and `just test-<name>` keep working. Point HOOK_STOP / HOOK_HOLD /
# HOOK_PERSIST / HOOK_CONDENSE at another implementation to run the same suite
# against it - see tests/lib.sh.

# Smoke-test the Stop hook with a synthetic Stop event
smoke:
    bash tests/smoke.sh

# Cursor / delta-analysis behaviour
test-cursor:
    bash tests/cursor.sh

# SubagentStop persistence hook
test-persist:
    bash tests/persist.sh

# Transcript condensation and project-root anchoring
test-condense:
    bash tests/condense.sh

# UserPromptSubmit input-hold hook
test-hold:
    bash tests/hold.sh

# Condensed-transcript labels vs the analyzer prompt
test-agent-prompt:
    bash tests/agent-prompt.sh

# PreToolUse pinned-subagent-model hook
test-enforce-model:
    bash tests/enforce-model.sh

# Perf budgets (not part of `just test`)
test-perf:
    bash tests/perf.sh

# --- rewrite/fixtures block (section 4) -------------------------------------

# Event-dump capture, the sanitiser, and the reconstructed fixtures
test-fixtures:
    bash tests/fixtures.sh

# Strip secrets and machine-specific paths from a captured fixture, in place.
# See tests/fixtures/CAPTURE.md.
fixture-sanitise path:
    bash tests/fixture-sanitise.sh "{{ path }}"

# Generate the >1 MB perf transcript (gitignored; regenerate on demand)
fixture-large out="tests/fixtures/large-session.jsonl" bytes="1048576":
    bash tests/fixtures/gen-large-session.sh "{{ out }}" "{{ bytes }}"

# --- end rewrite/fixtures block ---------------------------------------------

# --- section 2: goldens (rewrite/goldens) ---------------------------------

# Byte-exact goldens vs the current implementation
test-golden:
    bash tests/golden.sh

# Regenerate every golden. Commit the diff with the behaviour change that caused it.
golden-regen:
    GOLDEN_REGEN=1 bash tests/golden.sh

# --- end section 2 --------------------------------------------------------

# --- rewrite/coverage-config ------------------------------------------------

# Config parsing, storage resolution, and on-disk permissions
test-config:
    bash tests/config.sh

# Log rotation, sessions-dir cleanup, analyses cap, marker/delta release
test-lifecycle:
    bash tests/lifecycle.sh

# --- end rewrite/coverage-config --------------------------------------------

# Run all tests
test: smoke test-cursor test-condense test-persist test-hold test-agent-prompt test-enforce-model test-gates test-fixtures test-golden test-config test-lifecycle

# Lint + all tests
check: lint test

# Create a release: just release [patch|minor|major]
release segment="patch":
    #!/usr/bin/env bash
    set -euo pipefail
    manifest=".claude-plugin/plugin.json"
    latest=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    IFS='.' read -r major minor patch <<< "${latest#v}"
    case "{{ segment }}" in
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

# --- rewrite/coverage-gates -------------------------------------------------

# Stop-hook gating and transcript handling
test-gates:
    bash tests/gates.sh

# --- end rewrite/coverage-gates ---------------------------------------------
