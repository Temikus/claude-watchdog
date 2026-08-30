# Claude Watchdog — Node Runtime Availability

Graceful degradation when the host has no JavaScript runtime on `PATH`.
Drafted 2026-06-20, from a runtime-availability investigation cross-referenced
against the Claude Code hooks/plugins documentation.

---

## Problem

All three hooks are invoked as explicit `node` commands in `hooks/hooks.json`:

```json
"command": "node ${CLAUDE_PLUGIN_ROOT}/hooks/session-analysis.mjs"
```

Claude Code runs `command`-type hooks through the system shell (`sh -c` on
macOS/Linux, Git Bash on Windows) and **does not provide a JavaScript runtime**.
`node` is resolved from the user's `PATH`. But Claude Code's **native installer**
(the recommended install path) bundles **Bun** for its own internal use, does not
expose it to hooks, and does **not** guarantee `node` on `PATH`. A user who
installed Claude Code natively and never installed Node separately has no `node`.

For that user, every hook firing degrades badly:

- The shell resolves `node` → not found → exits **127**.
- A Stop hook exiting non-zero (and not `2`) is a **non-blocking error**: Claude
  Code surfaces a hook-failure notice to the user and continues.
- Result: a `node: command not found` (or "hook failed") message **on every
  Stop and every analyzer SubagentStop**, for a plugin that is silently inert.

The plugin doesn't crash the session, but it nags continuously and never explains
what's wrong or how to fix it.

> **To verify:** the exact exit code (127) and the precise framing Claude Code
> prints for a non-zero/non-2 Stop hook. The design below holds regardless — it
> removes the failing invocation rather than depending on how the failure reads.

---

## Goals

1. **No error spam.** A missing runtime must not produce a hook error on every
   Stop. Degrade to a quiet no-op.
2. **One clear, actionable notice.** Tell the user once per session that the
   plugin is inert and how to enable it (install Node 18+), rather than leaking a
   cryptic shell error.
3. **Never block or break the session.** Exit 0 on the degraded path.
4. **Zero overhead when a runtime is present.** One `command -v` check, then
   `exec` — no behavioral change for the common case.
5. **Cross-platform** within Claude Code's documented shell behavior.

---

## Design

Two pieces: a **runtime launcher** that replaces the bare `node` prefix (handles
Stop/SubagentStop quietly), and a **SessionStart preflight** that owns the
one-time, user-facing notice. Both are pure POSIX shell so they have **no
dependency on the very runtime they're guarding**.

### 1. Runtime launcher — `hooks/launch.sh`

A tiny POSIX launcher resolves a runtime and `exec`s the requested hook script.
If none is found, it exits 0 silently so Stop/SubagentStop never error-spam.

```sh
#!/bin/sh
# Resolve a JS runtime for claude-watchdog hooks and run the requested script.
# Hooks are plain ESM using only node: builtins, so node is preferred; bun is a
# best-effort fallback. With no runtime we exit 0 quietly — the SessionStart
# preflight surfaces the install hint once per session instead of erroring here.
set -eu
script="${CLAUDE_PLUGIN_ROOT}/hooks/$1"

if command -v node >/dev/null 2>&1; then
  exec node "$script"
elif command -v bun >/dev/null 2>&1; then
  exec bun "$script"
fi

exit 0
```

`hooks/hooks.json` changes to route through it:

```json
"command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/launch.sh\" session-analysis.mjs"
```

Invoking via `sh` (rather than relying on an executable bit, which can be lost on
plugin install) keeps it robust. `sh` is guaranteed on macOS/Linux and present in
the Git Bash environment Claude Code uses on Windows.

### 2. SessionStart preflight — `hooks/preflight.sh`

A new `SessionStart` hook, **also pure shell**, that warns exactly once per
session when no runtime exists. SessionStart is the right venue: it fires once at
the top of a session (naturally rate-limited, unlike Stop), and it supports
`additionalContext`/user-facing output that Stop hooks do not.

```sh
#!/bin/sh
# If a JS runtime exists, stay silent. Otherwise emit a single, user-facing
# notice that the plugin is inert and how to enable it.
set -eu
if command -v node >/dev/null 2>&1 || command -v bun >/dev/null 2>&1; then
  exit 0
fi

printf '%s\n' '{"systemMessage":"claude-watchdog is inert: no Node.js runtime was found on PATH. Install Node 18+ (https://nodejs.org) — or `brew install node` / your package manager — to enable automatic session post-mortems."}'
exit 0
```

```json
"SessionStart": [
  {
    "matcher": "",
    "hooks": [
      { "type": "command", "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/preflight.sh\"" }
    ]
  }
]
```

> **To verify (schema):** the exact field that renders to the user. Candidates,
> in order of preference: a top-level `systemMessage`; `hookSpecificOutput`
> `.additionalContext` (documented for SessionStart, but injects into *Claude's*
> context rather than showing the user); or plain stderr. Pick whichever the
> current docs confirm is user-visible; the shell guard is unaffected by the
> choice.

---

## Runtime fallback — how far to go

| Runtime | Runs our ESM + `node:` builtins? | Worth it? |
|---|---|---|
| `node` | Yes (target) | Primary. |
| `bun`  | Yes — Bun implements `node:` builtins and runs `.mjs` | Cheap one-line fallback; include it. |
| `deno` | Partial — needs `deno run --allow-read --allow-write --allow-env` and `node:` compat; our hooks do FS + env | Marginal. The broad permission flags and compat risk outweigh the payoff. **Skip** unless a user asks. |

Note Claude Code's **own** bundled Bun is not reachable (not on `PATH`, no env
var points at it), so the `bun` fallback only helps users who independently
installed Bun. That's rare but free to support.

---

## Edge cases & details

- **Windows without Git Bash.** Claude Code falls back to PowerShell when Git
  Bash is absent, where a `.sh` launcher won't run. Either (a) accept this as a
  documented limitation — native-Windows users without Git Bash already lack the
  POSIX tooling these hooks assume — or (b) ship parallel `launch.ps1` /
  `preflight.ps1` and let `hooks.json` select per-OS. Recommend (a) for v1; treat
  (b) as a follow-up only if Windows demand appears. **Open question.**
- **`CLAUDE_PLUGIN_ROOT` unset.** A known Claude Code gap (the var isn't always
  populated). The launcher should tolerate it; consider a `${CLAUDE_PLUGIN_ROOT:?}`
  guard that exits 0 with a one-line log rather than running `sh … /hooks/…` with
  an empty root. Coordinate with any fix for the same issue elsewhere.
- **stdin.** Hooks receive JSON on stdin. The degraded path exits 0 without
  reading it — harmless. The `exec` path hands stdin straight to the runtime.
- **No double-warn.** SessionStart scoping already limits the notice to once per
  session. If even that is too chatty, gate on a per-day flag file under
  `${CLAUDE_PLUGIN_DATA}` (e.g. `runtime-warned-YYYYMMDD`).

---

## Documentation (ships alongside)

There is **no machine-readable way** to declare a runtime requirement for a
Claude Code plugin (no `engines` field; no validation). The only mechanism is
prose:

- **README:** add a "Requirements" section — "Node.js 18+ on `PATH` (or Bun).
  Claude Code's native installer does not include Node; install it separately."
- **`plugin.json` `description`:** a short "(requires Node 18+)" nudge so it
  shows in the plugin list.

---

## Testing

Add a `just` target (e.g. `test-runtime`) that exercises the launcher and
preflight with the runtime stripped from `PATH`:

```sh
# Degraded launcher path: no runtime -> exit 0, no output, stdin drained.
out=$(printf '{}' | env PATH=/var/empty CLAUDE_PLUGIN_ROOT="$PWD" /bin/sh hooks/launch.sh session-analysis.mjs 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] || fail "launcher-degraded" "expected silent exit 0"

# Happy path: runtime present -> script actually runs (reuse smoke payload).
# (PATH intact; assert decision:block on stdout as in `smoke`.)

# Preflight notice: no runtime -> emits the user notice, exit 0.
out=$(env PATH=/var/empty /bin/sh hooks/preflight.sh 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no Node.js runtime' || fail "preflight-notice" "expected install hint"
```

`env PATH=/var/empty` makes `command -v node` fail deterministically while
`/bin/sh` and shell builtins still work. Wire `test-runtime` into the `test`
aggregate in `justfile`.

---

## Effort & sequencing

| Item | Effort | Notes |
|---|---|---|
| `launch.sh` + route all 3 hooks through it | Small | Core fix; removes the error spam. |
| `preflight.sh` + SessionStart entry | Small | User-facing notice; confirm the user-visible output field. |
| `bun` fallback | Trivial | One `elif` in `launch.sh`. |
| README + `plugin.json` description note | Trivial | Pairs with backlog docs work. |
| `just test-runtime` | Small | PATH-stripped degradation + happy-path. |
| Windows `.ps1` parity | Medium | Deferred; open question above. |

**Phase A** (launcher + preflight + docs + test) delivers the whole user-visible
win and is all Small/Trivial. **Phase B** (Windows parity) is conditional on
demand.
