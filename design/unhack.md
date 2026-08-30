# Claude Watchdog — Unhack Plan

Remove hacks and workarounds identified during the 2026-05-15 codebase audit.
Cross-referenced against the `reference/claude-code` plugin source to verify
idiomatic alternatives exist before proposing changes.

---

## 2. Invert `cfg()` priority — plugin option > legacy env var

**File:** `hooks/session-analysis.mjs:10-14`

**Current hack:** The `cfg()` shim checks `CLAUDE_WATCHDOG_*` before
`CLAUDE_PLUGIN_OPTION_*`:

```js
function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[watchdogVar] ?? process.env[pluginVar] ?? defaultVal;
}
```

This means a stale `CLAUDE_WATCHDOG_MIN_TOOL_USES=5` in a shell profile silently
overrides whatever the user sets in Claude Code's settings UI.

**Idiomatic replacement:** Swap the priority so the plugin API is authoritative:

```js
function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[pluginVar] ?? process.env[watchdogVar] ?? defaultVal;
}
```

Legacy vars become a fallback for users who haven't migrated. In a future
semver-major release, drop `CLAUDE_WATCHDOG_*` entirely — no reference plugin
uses dual env var namespaces.

**Effort:** Trivial (one-line swap per call site, or swap args in `cfg()`).

---

## 3. Directory-as-mutex — add PID staleness check + `SessionEnd` cleanup

**File:** `hooks/session-analysis.mjs:241-249, 162-165`

**Current hack:** `mkdirSync(MARKER)` is used as an atomic lock. If the process
is killed with SIGKILL, the marker directory persists and blocks all analysis for
that session until the 2-hour TTL cleanup runs.

**Idiomatic replacement — two changes:**

### 3a. PID-based staleness check on startup

Before creating the marker directory, check if a stale one exists and whether the
owning process is still alive:

```js
try {
  mkdirSync(MARKER);
} catch (err) {
  if (err.code === 'EEXIST') {
    const pidFile = join(MARKER, 'pid');
    try {
      const pid = parseInt(readFileSync(pidFile, 'utf8'), 10);
      process.kill(pid, 0); // throws if process doesn't exist
      process.exit(0);      // owner is alive, bail out
    } catch {
      rmdirSync(MARKER, { recursive: true }); // stale lock, reclaim
      mkdirSync(MARKER);
    }
  } else {
    throw err;
  }
}
writeFileSync(join(MARKER, 'pid'), String(process.pid));
```

This shrinks the stale-lock window from 2 hours to the next hook invocation.

### 3b. Move cleanup to `SessionEnd` hook

Add a `SessionEnd` hook entry in `hooks/hooks.json` that removes the marker
directory and prunes old session files. `SessionEnd` fires after session
termination and cannot block — ideal for housekeeping. This also addresses
backlog item 6.

The `mkdirSync` pattern itself is idiomatic POSIX — no better concurrency
primitive exists in the plugin API. The improvement is in stale-lock recovery,
not the lock mechanism.

**Effort:** Small-Medium.

---

## 4. Buffer.slice UTF-8 — truncate at line boundaries

**File:** `hooks/session-analysis.mjs:332-336`

**Current hack:** Transcript truncation uses `Buffer.slice()` at raw byte
offsets, which can split multi-byte UTF-8 characters:

```js
const userBuf = Buffer.from(userLines.join('\n'), 'utf8');
const userPart = userBuf.slice(0, USER_BUDGET).toString('utf8');
```

A split produces `�` replacement characters at the cut point.

**Idiomatic replacement:** Since the data is already split into lines
(`userLines`, `otherLines`), truncate by accumulating lines until the byte
budget is exhausted:

```js
function truncateLines(lines, maxBytes, fromEnd = false) {
  const ordered = fromEnd ? [...lines].reverse() : lines;
  const result = [];
  let bytes = 0;
  for (const line of ordered) {
    const lineBytes = Buffer.byteLength(line, 'utf8') + 1; // +1 for \n
    if (bytes + lineBytes > maxBytes) break;
    result.push(line);
    bytes += lineBytes;
  }
  return fromEnd ? result.reverse() : result;
}

const userPart = truncateLines(userLines, USER_BUDGET).join('\n');
const otherPart = truncateLines(otherLines, OTHER_BUDGET, true).join('\n');
```

This guarantees clean UTF-8 at truncation boundaries and is a drop-in
replacement with no behavioral change for ASCII content.

**Effort:** Trivial.

---

## 5. `/clear` boundary cursor reset

**File:** `hooks/session-analysis.mjs` (cursor logic)

**Current hack:** The session ID does not reset on `/clear`. The cursor file is
keyed to the session ID, so post-`/clear` analyses may read accumulated content
from before the clear boundary.

**Status:** No clean API exists. Investigation confirmed:

- `SessionEnd` does not document matcher support for `"clear"` — matchers
  filter on tool names, not payload fields.
- There is no `end_reason` field documented for `SessionEnd`.

**Approach:** Timestamp-based cursor file naming, as proposed in backlog item 2.
Include a monotonic counter or timestamp in the cursor filename so each logical
segment gets a distinct cursor. This doesn't depend on undocumented API behavior.

**Effort:** Medium.

---

## 6. Named constants + `userConfig` for TTL and retention cap

**Files:** `hooks/session-analysis.mjs`, `hooks/persist-analysis.mjs`

**Current hack:** Magic numbers scattered across two files with no shared
constant or user-facing configuration:

| Location | Value | Controls |
|---|---|---|
| `session-analysis.mjs:46` | `120 * 60 * 1000` | Session file TTL (2 hours) |
| `session-analysis.mjs:74` | `.slice(20)` | Max saved analysis files |
| `persist-analysis.mjs:51` | `.slice(20)` | Same cap, duplicated |
| `session-analysis.mjs:109,115,132` | `500, 500, 300` | Per-field truncation |
| `session-analysis.mjs:137` | `200` | SYSTEM message truncation |

**Approach:**

- Extract a shared constants module (or inline named constants in each file).
- Add `session_ttl_hours` and `max_saved_analyses` to `userConfig` in
  `plugin.json` for user-facing tunability.
- Per-field truncation limits are internal implementation details — named
  constants are sufficient, no need to expose to users.

**Effort:** Small.

---

## Sequencing

Numbering starts at 2: item 1 (exit code 2 to JSON `decision: block`) has
shipped and was removed. Item 2 should land first (highest impact, lowest
effort). Item 4 can land independently at any time. Items 3 and 6 can be
bundled. Item 5 is independent and lower priority.

| Phase | Items | Depends on |
|---|---|---|
| A | 2 (cfg priority), 4 (UTF-8) | - |
| B | 3 (mutex), 6 (constants) | - |
| C | 5 (/clear boundary) | - |
