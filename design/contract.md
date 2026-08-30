# Claude Watchdog - Wire Contract

The behaviour a port has to reproduce, derived by reading `hooks/*.mjs` at
commit `0f83be5`, not by paraphrasing the README. Where the README and the code
disagree, the code wins and the disagreement is flagged.

Every statement here is meant to be testable. Statements the current suite does
not cover are tagged **[UNTESTED]** so a later station can turn them into tests.
Places where the implemented behaviour looks accidental rather than intended are
tagged **[OPEN QUESTION FOR THE PORT]** with the decision that needs making.

Conventions used below:

- "byte" means a UTF-8 byte (`Buffer.byteLength`).
- "char" means a JavaScript string index unit, that is a UTF-16 code unit
  (`String.prototype.slice`). The distinction matters and is called out where it
  does.
- File modes are stated as the code sets them, not as observed on disk.

---

## 1. Entry points

Three hooks, wired in `hooks/hooks.json`:

| Event | Matcher | Command | Timeout |
| --- | --- | --- | --- |
| `Stop` | `""` (all) | `node ${CLAUDE_PLUGIN_ROOT}/hooks/session-analysis.mjs` | 120 s |
| `UserPromptSubmit` | `""` (all) | `node ${CLAUDE_PLUGIN_ROOT}/hooks/hold-input.mjs` | 10 s |
| `SubagentStop` | `session-analyzer` | `node ${CLAUDE_PLUGIN_ROOT}/hooks/persist-analysis.mjs` | 10 s |

Two further files are libraries with a debug CLI attached, not hooks:
`hooks/condense.mjs` and `hooks/cursor-slice.mjs` (section 9).

### 1.1 Inputs

Each hook reads the whole of stdin, truncates it to a byte cap, then decodes it
as UTF-8 and `JSON.parse`s it.

| Hook | stdin cap | Behaviour past the cap |
| --- | --- | --- |
| Stop | 65536 bytes | Truncated buffer almost certainly fails `JSON.parse`, which is caught, logged as `ERROR:`, and exits 0. **[UNTESTED]** |
| UserPromptSubmit | 65536 bytes | Same, logged with the `[hold]` prefix. Garbage stdin is tested; the cap itself is not. |
| SubagentStop | 131072 bytes | Same, logged with the `[persist]` prefix. **[UNTESTED]** |

The cap slices *bytes* before decoding, so a multi-byte character straddling the
cap decodes to U+FFFD. This only ever makes the parse fail sooner, and the parse
failure path is fail-open.

**[OPEN QUESTION FOR THE PORT]** The cap is applied to a buffer that has already
been fully read into memory, so it bounds parse cost, not read cost. A port that
streams could either keep the same semantics (read all, then cap) or genuinely
stop reading at the cap. The observable difference is nil, so either is fine, but
pick one and say so.

### 1.2 Fields consumed

Stop event (`session-analysis.mjs`):

| Field | Type | Use |
| --- | --- | --- |
| `session_id` | string | Gate (must match `^[a-zA-Z0-9_-]+$`), names the marker, cursor, delta, condensed, echo, and pending files |
| `transcript_path` | string | Gate (must exist), read for the delta |
| `cwd` | string | Skip-file lookup, storage anchoring, relative-path base for touched files, `working directory` in the analyzer prompt |
| `stop_reason` | string | Gate; defaults to `end_turn` when absent |
| `agent_id` | string | Gate; any truthy value skips |
| `agent_type` | string | Log text only; rendered as `unknown` when absent |
| `stop_hook_active` | boolean | Echo suppression; only `=== true` counts |
| `background_tasks` | array | Gate; each element's `.type` goes into the log line |
| `session_crons` | array | Gate; each element's `.prompt` is regex-tested |
| `last_assistant_message` | string | Appended to the condensed transcript as the final assistant message |

The whole event is also re-serialised into the log after string values are capped
at 200 chars (see section 7.2).

UserPromptSubmit event (`hold-input.mjs`): `session_id` only. The prompt text is
never read and never logged, by design.

SubagentStop event (`persist-analysis.mjs`): `agent_type` (gate, must equal
`session-analyzer`), `session_id` (gate, same regex), and
`last_assistant_message` (the content written to disk).

See `design/formats.md` for what these fields look like on the wire and which
Claude Code version introduced them.

---

## 2. Stop hook gate order

This is the order in the source. It differs from the README's list, which is
listed at the end of this section.

Work that happens **before** the first gate, so it happens on every Stop
including a disabled one:

0. `mkdir -p` the log directory, `WATCHDOG_TMP`, `WATCHDOG_TMP/sessions`, and
   `ANALYSES_DIR`. `WATCHDOG_TMP` and `WATCHDOG_TMP/sessions` are `chmod 0700`;
   `ANALYSES_DIR` is not. **[UNTESTED]** for the chmod.
1. `cleanupSessionsDir(GLOBAL_SESSIONS_DIR)` and `capAnalyses()` run
   (section 6.6, 6.7).

   **[OPEN QUESTION FOR THE PORT]** Cleanup and the analyses cap run *before* the
   disabled gate, so a fully disabled watchdog still deletes the user's files
   every time Claude Code stops. That looks accidental. Decide whether the port
   moves both below the disabled gate.

Then, in order:

| # | Gate | Condition to skip | Log line |
| --- | --- | --- | --- |
| 1 | Disabled | `DISABLED` is `1` or `true` | `SKIP: disabled via configuration` |
| 2 | Session id | `session_id` fails `^[a-zA-Z0-9_-]+$` | `SKIP: invalid session_id format` |
| 3 | Subagent | `event.agent_id` is truthy | `SKIP: running inside subagent/teammate (agent_id=..., agent_type=...)` |
| 4 | Stop reason | `stop_reason !== 'end_turn'` | `SKIP: stop_reason is '<x>', not 'end_turn'` |
| 5 | Echo sentinel | `stop_hook_active === true` **and** the echo sentinel exists | `SKIP: our own analyzer echo (stop_hook_active + echo sentinel)` |
| 6 | Background tasks | `SKIP_WITH_BG` truthy and `background_tasks.length > 0` | `SKIP: <n> background task(s) in flight (<types>); deferring to a clean stop` |
| 7 | Session cron | `SKIP_WITH_BG` truthy and some `session_crons[].prompt` matches `/analyze-session\|session-analyzer/i` | `SKIP: analysis already scheduled via session cron` |
| 8 | Skip file | `<cwd>/.claude-watchdog-skip` exists | `SKIP: disabled via .claude-watchdog-skip in <cwd>` |
| 9 | Storage resolution | never skips; picks `SESSIONS_DIR` (section 6.1) | `LOCAL_STORAGE: ...` |
| 10 | Marker | `mkdir(MARKER)` fails with `EEXIST` | `SKIP: concurrent run already in progress for <sid>` |
| 11 | Transcript | `transcript_path` empty or missing on disk | `SKIP: transcript not found at '<path>'` |
| 12 | Cursor | never skips; reads and validates the cursor (section 6.2) | `CURSOR: ...` |
| 13 | Cooldown | `COOLDOWN_SECONDS > 0`, cursor file exists, and its mtime age is under the cooldown | `SKIP: cooldown active (<n>s < <m>s since last trigger)` |
| 14 | Delta size | `toolUses < MIN_TOOL_USES` | `SKIP: delta too small (<n> < <m>), cursor unchanged` |
| 15 | Edits | `edits === 0 && mutatingBash === 0` | `SKIP: delta has no file edits or mutating shell commands (read-only turn), cursor unchanged` |
| 16 | User messages | `userMessages === 0` | `SKIP: delta has no top-level user messages, cursor unchanged` |
| 17 | Empty condensed | condensed content is empty or all whitespace | `SKIP: condensed transcript is empty` |

Anything reaching the far side of gate 17 triggers (section 8).

Notes on individual gates:

- **Gate 1** runs before stdin is read at all. A disabled watchdog never parses
  the event. **[UNTESTED]** that stdin is left unread, though gate 12 of the
  suite covers the skip itself.
- **Gate 3** fires on any truthy `agent_id`, so it also catches a teammate
  session, not only a subagent one.
- **Gate 4** treats a missing `stop_reason` as `end_turn`, so older Claude Code
  builds that do not send it still trigger. Only compaction, `tool_use`, and
  `max_tokens` values were considered; anything other than `end_turn` skips.
  **[UNTESTED]** for every value.
- **Gate 5** deliberately requires *both* conditions. `stop_hook_active === true`
  with no sentinel of ours means some other plugin's Stop hook blocked, and the
  watchdog falls through to the remaining gates rather than suppressing.

### 2.1 Order-dependent side effects

These are the reasons the order is a contract and not an implementation detail.

1. **The echo sentinel is cleared before the skip-file check (gates 5 and 8).**
   Between them sits a third branch: if the sentinel exists but
   `stop_hook_active !== true`, both the echo sentinel *and* the pending sentinel
   are deleted and `ECHO: stale sentinel cleared (fresh turn, not a
   continuation)` is logged, then execution continues. Because that clearing
   happens at gate 5 and the skip-file check is gate 8, a session with
   `.claude-watchdog-skip` present still consumes its stale sentinels and still
   releases an input hold. A port that hoists the skip-file check earlier changes
   observable behaviour. **[UNTESTED]**: the interaction of a stale sentinel with
   a skip file.
2. **The cooldown is checked after the marker is acquired (gates 10 and 13).**
   Every cooldown skip therefore creates and then removes a marker directory, via
   the `process.on('exit')` handler. Two Stops arriving concurrently during a
   cooldown do not both log the cooldown skip: one logs the concurrency skip
   instead. Moving the cooldown above the marker would change which log line a
   user sees.
3. **The cursor is read and validated before the cooldown (gates 12 and 13).**
   So `CURSOR: malformed uuid, ignoring cursor` and `CURSOR: stale transcript
   path, ignoring cursor` can both appear on a turn that then skips for cooldown.
   **[UNTESTED]**.
4. **The delta file is written before `umask(0o077)` is set.** `process.umask` is
   called only after gate 16 passes. `delta-<sid>.tmp` is therefore created under
   whatever umask the hook inherited, typically `0644`, while
   `condensed-<sid>.txt`, `cursor-<sid>.txt`, `echo-<sid>`, and `pending-<sid>`
   are created after it and land `0600`.

   **[OPEN QUESTION FOR THE PORT]** The delta file holds the raw transcript
   slice, which is the most sensitive artefact of the lot. Its permissive mode
   looks accidental. Decide whether the port sets the umask (or an explicit mode)
   before the first write.
5. **`markerDir` and `deltaFile` are registered for cleanup at gate 10**, before
   the delta file is written. The exit handler unlinks a file that may never have
   existed; the failure is swallowed. Harmless, but a port must not treat the
   missing file as an error.

### 2.2 Where the README disagrees

README "When does the hook actually fire?" lists: disabled, skip file,
`stop_reason`, echo, background tasks, session cron, marker, transcript and
minimum tool calls, edits, user messages, cooldown, empty condensed.

Three differences from the code:

1. The skip-file check is listed second but is actually eighth, after the echo
   sentinel has already been cleared.
2. The cooldown is listed second-to-last but is actually checked before the
   delta-size, edits, and user-message gates.
3. The session-id and `agent_id` gates are not listed at all.

The README also describes the marker as "session has not already been analysed",
which reads as once-per-session; it is a concurrency lock with a two-hour stale
sweep, and a session can be analysed many times.

---

## 3. Configuration

### 3.1 The `cfg()` precedence chain

```js
function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[watchdogVar] ?? process.env[pluginVar] ?? defaultVal;
}
```

Precedence is `CLAUDE_WATCHDOG_*`, then `CLAUDE_PLUGIN_OPTION_*`, then the
built-in default. The operator is `??`, not `||`, so an environment variable set
to the empty string wins over the plugin option and over the default. Since the
empty string is neither `1` nor `true`, `CLAUDE_WATCHDOG_DISABLED=""` reads as
"not disabled" but still shadows `CLAUDE_PLUGIN_OPTION_DISABLED=true`.
**[UNTESTED]**.

**[OPEN QUESTION FOR THE PORT]** An empty-string override shadowing a plugin
option looks accidental. Most shells make it easy to export an empty variable by
accident. Decide whether empty-string is treated as unset.

The suite covers precedence for `MIN_TOOL_USES` only (justfile Tests 11 and 13).
Every other `cfg()` call site is **[UNTESTED]** for precedence.

### 3.2 Settings read through `cfg()`

| Setting | Watchdog var | Plugin option var | Default | Parsed as |
| --- | --- | --- | --- | --- |
| Disabled | `CLAUDE_WATCHDOG_DISABLED` | `CLAUDE_PLUGIN_OPTION_DISABLED` | `0` | bool |
| Minimum tool uses | `CLAUDE_WATCHDOG_MIN_TOOL_USES` | `CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES` | `15` | int |
| Condensed byte cap | `CLAUDE_WATCHDOG_MAX_BYTES` | `CLAUDE_PLUGIN_OPTION_MAX_TRANSCRIPT_BYTES` | `51200` | int |
| Cooldown seconds | `CLAUDE_WATCHDOG_COOLDOWN_SECONDS` | `CLAUDE_PLUGIN_OPTION_COOLDOWN_SECONDS` | `600` | int |
| Local session storage | `CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE` | `CLAUDE_PLUGIN_OPTION_LOCAL_SESSION_STORAGE` | `1` | bool |
| Interactive recommendations | `CLAUDE_WATCHDOG_INTERACTIVE_RECOMMENDATIONS` | `CLAUDE_PLUGIN_OPTION_INTERACTIVE_RECOMMENDATIONS` | `0` | bool |
| Skip with background tasks | `CLAUDE_WATCHDOG_SKIP_WITH_BACKGROUND_TASKS` | `CLAUDE_PLUGIN_OPTION_SKIP_WITH_BACKGROUND_TASKS` | `1` | bool |
| Hold input | `CLAUDE_WATCHDOG_HOLD_INPUT` | `CLAUDE_PLUGIN_OPTION_HOLD_INPUT_DURING_ANALYSIS` | `0` | bool |
| Include rules | `CLAUDE_WATCHDOG_INCLUDE_RULES` | `CLAUDE_PLUGIN_OPTION_INCLUDE_RULES` | `1` | bool |
| Verbose | `CLAUDE_WATCHDOG_VERBOSE` | `CLAUDE_PLUGIN_OPTION_VERBOSE` | `0` | bool |
| Legacy exit-2 mode | `CLAUDE_WATCHDOG_LEGACY_HOOK` | `CLAUDE_PLUGIN_OPTION_legacy_hook` | `false` | see below |

Note the three name mismatches between the two columns: `MAX_BYTES` against
`MAX_TRANSCRIPT_BYTES`, `HOLD_INPUT` against `HOLD_INPUT_DURING_ANALYSIS`, and
`LEGACY_HOOK` against the lower-case `legacy_hook`.

**[OPEN QUESTION FOR THE PORT]** `CLAUDE_PLUGIN_OPTION_legacy_hook` is the only
plugin-option variable spelled in lower case, and `legacy_hook` is not declared
in `.claude-plugin/plugin.json` `userConfig` at all, so Claude Code never sets
it. It is almost certainly a typo for `CLAUDE_PLUGIN_OPTION_LEGACY_HOOK`. Decide
whether the port fixes the case, keeps the typo for compatibility, or drops the
plugin-option lookup for legacy mode entirely.

### 3.3 Settings read directly from the environment

These have no plugin option and no `cfg()` fallback.

| Variable | Default | Parsed as |
| --- | --- | --- |
| `CLAUDE_WATCHDOG_LOG` | `~/.claude/logs/claude-watchdog.log` | path |
| `CLAUDE_WATCHDOG_LOG_MAX_LINES` | `1000` | int |
| `CLAUDE_WATCHDOG_TMP` | `$CLAUDE_PLUGIN_DATA`, else `~/.claude/tmp/claude-watchdog` | path |
| `CLAUDE_WATCHDOG_ANALYSES_DIR` | `~/.claude/logs/claude-watchdog-analyses` | path |
| `CLAUDE_WATCHDOG_CURSOR_TTL_DAYS` | `7` | int |
| `CLAUDE_WATCHDOG_HOLD_TTL_SECONDS` | `240` | int (hold hook only) |

`CLAUDE_WATCHDOG_CURSOR_TTL_DAYS` and `CLAUDE_WATCHDOG_INTERACTIVE_RECOMMENDATIONS`
are not documented in the README's variable tables. **[UNTESTED]** that
`CLAUDE_WATCHDOG_LEGACY_HOOK` works at all.

### 3.4 Boolean parsing, as implemented

Every boolean except legacy mode is tested as:

```js
value === '1' || value === 'true'
```

So `1` and `true` are truthy, and **everything else is falsy**, including `TRUE`,
`True`, `yes`, `on`, `y`, and `0`. There is no trimming, so ` 1` with a leading
space is falsy.

Legacy mode is the exception. It is tested as `=== 'true'` alone, so
`CLAUDE_WATCHDOG_LEGACY_HOOK=1` does **not** enable legacy mode, unlike every
other boolean in the plugin. Its default is the string `'false'` rather than
`'0'` for the same reason.

**[OPEN QUESTION FOR THE PORT]** Two things look accidental here: (a) case
sensitivity, so a user setting `TRUE` silently gets the default, and (b) legacy
mode accepting a different truthy set from every other flag. Decide on one
parser: either keep the exact `'1' | 'true'` set everywhere for byte-compatible
behaviour, or normalise (trim plus lower-case, accepting `1/true/yes/on`) and
pin the new set with a test. Do not leave the two sets divergent.

Claude Code's plugin config passes booleans as the strings `true` and `false`, so
the plugin-option path is unaffected by the case question in practice; only
hand-set environment variables hit it.

### 3.5 Integer parsing, as implemented

Every integer is `parseInt(value, 10)`. That means:

- Leading whitespace is skipped, and a leading `+` or `-` is honoured, so
  negative values parse.
- Parsing stops at the first non-digit, so `15abc` is `15` and `1_000` is `1`.
- A value with no leading digits is `NaN`, and `NaN` is never reported: every
  comparison against it is `false`, so the gate it guards silently turns off.

The `NaN` consequences, per setting:

| Setting | Comparison | Effect of `NaN` |
| --- | --- | --- |
| `MIN_TOOL_USES` | `toolUseCount < MIN_TOOL_USES` | false, so the delta-size gate never skips: every turn is large enough |
| `COOLDOWN_SECONDS` | `COOLDOWN_SECONDS > 0` | false, so the cooldown is disabled entirely |
| `CONDENSED_MAX_BYTES` | `rawSize <= maxBytes` | false, so the truncation path is always taken; the per-part budgets are also `NaN`, `used + cost > NaN` is false, so `takeLines` never breaks and keeps *every* line. Net result: nothing is dropped, but the output gains a `[TRUNCATED] Original transcript was <n> bytes (~NaN KB dropped).` header and the head/tail separator |
| `LOG_MAX_LINES` | `lines.length > MAX_LINES` | false, so the log never rotates |
| `CURSOR_TTL_DAYS` | `age > cursorTtlMs` | false, so stale cursors are never pruned |
| `HOLD_TTL_SECONDS` | `TTL <= 0` then `ageSec > TTL` | both false, so the hold never expires and only the nudge releases it |

All six are **[UNTESTED]**.

**[OPEN QUESTION FOR THE PORT]** Silent gate-disabling on a typo is the single
most dangerous behaviour in this file: `CLAUDE_WATCHDOG_MIN_TOOL_USES=abc` turns
the watchdog from "fires on substantial turns" into "fires on every turn", and
nothing in the log says why. A strongly typed port cannot reproduce it without
going out of its way. The recommended resolution is: on an unparseable integer,
log `CONFIG: <var>=<value> is not an integer, using default <n>` and fall back to
the default. Whatever is chosen, pin it with a test per setting.

Note also that the `min`/`max` bounds declared in `plugin.json` `userConfig`
(`min_tool_uses >= 0`, `cooldown_seconds >= 0`, `max_transcript_bytes` between
4096 and 512000) are enforced by Claude Code's config UI only. The hooks never
range-check, so an environment variable can set any value, including a negative
one. `CLAUDE_WATCHDOG_MAX_BYTES=0` makes `rawSize <= 0` false and drives the
truncation path with zero-byte budgets, producing a header, blank parts, and the
separator; that content is non-empty so gate 17 does not catch it. **[UNTESTED]**

---

## 4. Delta statistics

Computed over the parsed delta lines, in `deltaStats()`.

`parseLines` keeps only lines whose first character is `{` and which parse as
JSON. Everything else, including blank lines and the trailing empty string from
the final newline, is skipped silently.

- **`toolUses`**: every `tool_use` block in an `assistant` entry whose
  `message.content` is an array. This is the number compared against
  `MIN_TOOL_USES`.
- **`userMessages`**: entries passing `isUserMessage()`, that is `type === 'user'`
  and either a non-empty trimmed string `message.content`, or an array content
  that contains at least one `text` block and **no** `tool_result` block. A text
  block sharing an entry with a `tool_result` is mid-turn input and does not
  count. **[UNTESTED]** through the Stop hook gate, though the condenser's
  labelling of the same case is covered by test-condense Test 2.
- **`edits`**: `tool_use` blocks whose `name` is in
  `{Edit, Write, MultiEdit, NotebookEdit}`. `MultiEdit` and `NotebookEdit` are
  **[UNTESTED]**.
- **`mutatingBash`**: `tool_use` blocks named `Bash` whose `input.command` does
  **not** match

  ```
  /^\s*(git diff|git log|git status|git show|ls|cat|grep|rg|find|head|tail|wc|sed -n)\b/
  ```

  Leading whitespace is tolerated, `\b` means `sed -n` matches but `sed -i` does
  not, and `git diff` matches but `git push` does not. The regex only inspects
  the start of the command, so `cat x && rm -rf y` is classified read-only.
  **[UNTESTED]** in full, and the `&&` case is a known false negative.

  **[OPEN QUESTION FOR THE PORT]** Prefix-only matching means any mutating
  command chained behind a read-only one is invisible to the edits gate. Decide
  whether the port keeps the prefix heuristic verbatim (simplest, and the gate is
  only an optimisation) or splits on `;`, `&&`, and `||` first.
- **`files`**: a de-duplicated, insertion-ordered list of touched paths, drawn
  from `input.file_path`, then `input.notebook_path` for edit tools, plus
  `attachment.filename` for `attachment` entries whose `attachment.type` is
  `edited_text_file`. Each path is made relative to the hook `cwd` when it is
  absolute and the relative form does not start with `..`; then every `\n` is
  stripped. Both the relativisation and the newline stripping are **[UNTESTED]**.

---

## 5. Cursor and delta slicing

The cursor records where the last *successful trigger* stopped, so each analysis
sees only new work.

`slice(transcriptPath, cursorUuid, hintStr)` in `cursor-slice.mjs`:

1. If the hint parses as a finite integer, is `> 0`, and is `<= lines.length`,
   and the JSON on line `hint` has `uuid === cursorUuid`, return
   `deltaStart = hint + 1`. This is the fast path.
2. Otherwise scan from line 1 for the first line whose `uuid` matches, and return
   `deltaStart = index + 2`.
3. Otherwise return `deltaStart = 1`, that is the whole transcript.

`uuidOf(line)` returns `null` unless the line starts with `{`, parses as JSON,
and has a string `uuid`.

`lastUuid(deltaPath)` scans backwards for the last line with a usable `uuid` and
returns `{ uuid, relLine }` where `relLine` is 1-based within the delta. The
absolute line written back to the cursor is `(deltaStart - 1) + relLine`.

The delta itself is `allLines.slice(deltaStart - 1)` joined with `\n`, where
`allLines` is the transcript split on `\n`. Note that a CRLF transcript leaves a
trailing `\r` on every line; `line[0] !== '{'` still passes and `JSON.parse`
tolerates the trailing `\r`, so CRLF works by accident. **[UNTESTED]**

---

## 6. File formats and storage

### 6.1 Storage root resolution

```
WATCHDOG_TMP          = $CLAUDE_WATCHDOG_TMP
                     ?? $CLAUDE_PLUGIN_DATA
                     ?? ~/.claude/tmp/claude-watchdog
GLOBAL_SESSIONS_DIR   = <WATCHDOG_TMP>/sessions
```

`GLOBAL_SESSIONS_DIR` is always created and always holds the echo and pending
sentinels, regardless of the local-storage setting, so those two files resolve to
the same path on the block turn and the echo turn.

When `LOCAL_SESSION_STORAGE` is truthy **and** `cwd` is non-empty, is not the
literal four-character string `"null"`, and exists on disk:

```
SESSIONS_DIR = <projectRoot(cwd)>/.claude/tmp/claude-watchdog/sessions
```

created with `mkdir -p` and `chmod 0700`, then swept by `cleanupSessionsDir`. If
any of that throws, the log records `LOCAL_STORAGE: cannot create local dir,
falling back to global` and `SESSIONS_DIR` stays global. If the `cwd` test fails,
the log records `LOCAL_STORAGE: hook_cwd empty or invalid, falling back to
global`. When the resolved root differs from `resolve(cwd)`, an extra line is
logged first: `LOCAL_STORAGE: anchored to project root <root> (cwd was <cwd>)`.

The literal `"null"` guard exists because some callers stringify a null `cwd`.
**[UNTESTED]**

`projectRoot(startDir)`:

```
home  = resolve(homedir())
start = resolve(startDir)
root  = filesystem root of start
dir   = start
claudeDir = null
while dir !== root and dir !== home:
    if <dir>/.git exists:      return dir
    if not claudeDir and <dir>/.claude exists: claudeDir = dir
    parent = dirname(dir)
    if parent === dir: break
    dir = parent
return claudeDir ?? start
```

So: `.git` wins immediately and at the *lowest* ancestor that has one; `.claude`
is only a fallback and records the lowest match without stopping the walk; the
walk stops *below* `$HOME` and below the filesystem root, meaning a `.git` or
`.claude` sitting directly in `$HOME` or at `/` is never considered; and when
nothing matches, the resolved start directory is returned unchanged.

`.git` is tested with `existsSync`, so a worktree's `.git` *file* counts the same
as a `.git` directory. The `$HOME` and filesystem-root stops are **[UNTESTED]**.

### 6.2 Per-session files

All names below live in `SESSIONS_DIR` unless stated otherwise.

| Name | Kind | Contents |
| --- | --- | --- |
| `<session_id>` | directory | Marker. Empty. Created with plain `mkdir` (not recursive) so a second concurrent run gets `EEXIST` |
| `cursor-<session_id>.txt` | file | Cursor, three lines (below) |
| `delta-<session_id>.tmp` | file | The raw transcript slice, verbatim, joined with `\n` |
| `condensed-<session_id>.txt` | file | The condensed transcript handed to the analyzer |
| `raw-<session_id>.txt` | file | **Never written by the current code.** See below |
| `echo-<session_id>` | file, always in `GLOBAL_SESSIONS_DIR` | Echo sentinel |
| `pending-<session_id>` | file, always in `GLOBAL_SESSIONS_DIR` | Input-hold sentinel |

**Cursor file.** Written as:

```
<uuid>\n<absolute line number>\n<transcript path>\n
```

Three content lines plus a trailing newline, so splitting on `\n` yields four
elements with an empty fourth. On read:

- Line 1 must match `^[A-Za-z0-9_-]+$`, otherwise `CURSOR: malformed uuid,
  ignoring cursor` and the cursor is ignored.
- Line 2 must match `^[0-9]+$` to be used as the line hint; a non-matching line 2
  leaves the hint at 0, which fails the `hint > 0` test in `slice()` and falls
  through to the uuid scan. It does **not** invalidate the uuid.
- Line 3, when non-empty and pointing at a path that does not exist, logs
  `CURSOR: stale transcript path, ignoring cursor` and clears both the uuid and
  the line number. An empty line 3 is accepted without a check.

The cursor's **mtime is the cooldown clock**. Because the cursor is only written
on a successful trigger, "cooldown since the last analysis" and "cooldown since
the cursor was last written" are the same thing.

**`raw-` files.** `session-analysis.mjs` computes `RAW_FILE` and never writes it.
Only `cleanupSessionsDir`'s regex still knows the prefix, so the sweep is dead
code for anything this version created. **[OPEN QUESTION FOR THE PORT]** The
variable is unused; drop it, or start writing the pre-condensation extract for
debuggability. Keeping the cleanup pattern is cheap either way, since users may
still have `raw-` files from an older version on disk.

**Echo sentinel.** A single line: `new Date().toISOString()` plus `\n`, so the
full millisecond form, for example `2026-08-30T12:34:56.789Z`. Only its
*existence* is ever tested; the timestamp is never parsed. Written just before
the hook blocks, in both the JSON and the legacy exit-2 paths. Deleted on the
echo turn (gate 5) or on the stale-sentinel branch. Written best-effort: a
failure is swallowed, and the cooldown, cursor, and `MIN_TOOL_USES` gates remain
as the backstop.

**Pending sentinel.** Line 1 is the same ISO timestamp. After the hold hook
blocks a prompt once, the file is rewritten as:

```
<original line 1>\nnudged\n
```

so line 2 is the exact string `nudged` when the hold has already blocked once.
The TTL is anchored to line 1, not to mtime, precisely so the nudge rewrite does
not extend the hold. When line 1 does not parse as a date, `Date.parse` returns
`NaN` and the code falls back to the file's mtime. **[UNTESTED]**

The pending sentinel is written only when `HOLD_INPUT` is truthy. It is **not**
cleared on the echo-suppress turn, because that Stop fires exactly when the
analyzer was backgrounded and the input box reopened, which is when the hold is
still needed. It is cleared by `persist-analysis.mjs` on analyzer completion, on
the stale-sentinel branch of gate 5, or by the hold hook's TTL or nudge release.

### 6.3 Analysis files

Written by `persist-analysis.mjs` into `ANALYSES_DIR`:

```
<session_id>-<YYYYMMDD>T<HHMMSS>Z.md
```

The timestamp is `new Date().toISOString()` with all `-` and `:` removed and the
`.mmm` dropped, giving for example `20260830T123456Z`. Content is
`last_assistant_message` plus a trailing `\n`. Format is **[UNTESTED]**; that a
file appears is tested.

`latestAnalysis(sessionId)` in the Stop hook lists `ANALYSES_DIR`, keeps names
beginning `<session_id>-` and ending `.md`, sorts them lexicographically, and
takes the last. The timestamp format sorts correctly under a plain string sort,
which is why the sort works.

### 6.4 The log

`CLAUDE_WATCHDOG_LOG`, default `~/.claude/logs/claude-watchdog.log`. Appended to;
each line is:

```
[<ISO timestamp, milliseconds stripped>] <message>
```

for example `[2026-08-30T12:34:56Z] SKIP: disabled via configuration`. The hold
hook and persist hook insert their own tag after the timestamp: `[hold] ` and
`[persist] ` respectively.

### 6.5 Log rotation

`rotateLog()` runs once per Stop invocation, after the session header lines are
written and only on invocations that pass gates 1 to 4. It reads the whole file,
splits on `\n`, and when the line count exceeds `MAX_LINES` writes back the last
`MAX_LINES` elements, ensuring a trailing newline, then appends
`LOG ROTATED (was <n> lines)`. **[UNTESTED]**

### 6.6 Cleanup sweep

`cleanupSessionsDir(dir)` runs over `GLOBAL_SESSIONS_DIR` on every invocation and
over the local sessions directory when one is used. For each entry:

- A **file** matching `^(condensed|raw|delta|echo|pending)-` older than 120
  minutes by mtime is deleted.
- A **file** matching `^cursor-` older than `CURSOR_TTL_DAYS` days is deleted.
- A **directory** older than 120 minutes by mtime is `rmdir`ed. A non-empty
  directory fails and is left alone. This is what expires a stale marker.

Every failure, per entry and for the directory listing as a whole, is swallowed.
Only the cursor TTL is tested. **[UNTESTED]** for the two-hour file sweep and the
stale-marker sweep.

### 6.7 Analyses cap

`capAnalyses()` runs on every Stop invocation, and the same logic runs again at
the end of `persist-analysis.mjs`. It lists `ANALYSES_DIR`, keeps `.md` files,
sorts by mtime descending, and deletes everything from index 20 onward. So at
most 20 analysis files survive, newest by mtime. **[UNTESTED]** in the Stop hook;
**[UNTESTED]** for the pruning order in the persist hook.

---

## 7. Outputs

### 7.1 stdout and exit codes

| Hook | Path | stdout | Exit |
| --- | --- | --- | --- |
| Stop | any skip | nothing | 0 |
| Stop | trigger, default mode | `{"decision":"block","reason":"<instruction>"}`, no trailing newline | 0 |
| Stop | trigger, legacy mode | nothing on stdout; the instruction plus `\n` on **stderr** | **2** |
| Stop | unexpected error | nothing | 0 |
| UserPromptSubmit | allow, any reason | nothing | 0 |
| UserPromptSubmit | block | `{"decision":"block","reason":"<hold message>"}`, no trailing newline | 0 |
| SubagentStop | any | nothing | 0 |

Exit code 2 in legacy mode is the only non-zero exit any hook produces. Every
error path in all three hooks is fail-open: the exception is caught, an `ERROR:`
line is logged, and the process exits 0. Legacy mode is **[UNTESTED]**.

The debug CLIs do use other codes; see section 9.

### 7.2 Log line prefixes

The complete set, per hook.

**Stop hook**, no tag:

| Prefix | When |
| --- | --- |
| `--- session=<sid> stop_reason=<reason> ---` | Session header, once per invocation past gate 3 |
| `event: <json>` | The whole event re-serialised, with every string value truncated to 200 chars and given a `...[truncated]` suffix. If serialisation throws, the first 500 chars of the raw stdin are logged instead |
| `SKIP: ...` | Every gate that skips (section 2) |
| `TRIGGER: injecting session-analyzer subagent request (mode=json\|exit2)` | The trigger |
| `CURSOR: ...` | `malformed uuid, ignoring cursor`, `stale transcript path, ignoring cursor`, `uuid=<u> hint=<n> -> delta starts at line <n>`, `updated to uuid=<u> line=<n>`, `invalid last-uuid output, cursor unchanged` |
| `ECHO: stale sentinel cleared (fresh turn, not a continuation)` | Sentinel present but this Stop is not a continuation |
| `RULES: skipped <path> (<n>B, over 8KB\|total cap)` | An instruction file was excluded |
| `LOCAL_STORAGE: ...` | Storage resolution, three variants (section 6.1) |
| `LOG ROTATED (was <n> lines)` | Rotation fired |
| `tool_use count (delta): <n> (edits=<n> mutating_bash=<n> user_messages=<n>)` | Always, after the delta stats |
| `condensed file: <path> (<n> bytes)` | On the trigger path |
| `ERROR: unexpected failure: <message>` | Any uncaught exception |

**Hold hook**, tagged `[hold]`: `RELEASE: hold expired for session=<sid> (<n>s >
<m>s)`, `RELEASE: user override for session=<sid>`, `HOLD: blocked prompt for
session=<sid> (age=<n>s)`, `ERROR: unexpected failure: <message>`.

**Persist hook**, tagged `[persist]`: `WROTE: <path> (<n> bytes)`, `SKIP: invalid
session_id`, `SKIP: empty last_assistant_message for session=<sid>`,
`ERROR: unexpected failure: <message>`.

The README says "every decision is logged" and users grep this file, so these
lines are a de facto API. Only a handful are asserted today.

### 7.3 The instruction string

On the trigger path the `reason` (or, in legacy mode, the stderr payload) is
exactly:

```
Please spawn a session-analyzer agent to critically analyze this session.

Use the Agent tool with:
- subagent_type: "claude-watchdog:session-analyzer"
- model: "sonnet"
- prompt: "<safePrompt>"

<postAnalysis>
```

`safePrompt` is these lines joined with `\n`, with every `"` replaced by `'`:

1. `Read and analyze the condensed session transcript at '<condensed path>'. The working directory is '<cwd>'.`
2. Either `This is a continuation: the transcript covers only work since the previous analysis.` when a valid cursor uuid was in play, or `This is the first analysis for this session.`
3. `Files touched this slice: <comma-joined list>` or `Files touched this slice: none`
4. Optional: `Previous analysis (optional context, read only if useful): <path>` when `latestAnalysis()` found one. **[UNTESTED]**
5. Optional: `User instruction files: <comma-joined list>` when `INCLUDE_RULES` is truthy and at least one file survived the size filter. **[UNTESTED]**
6. `Provide your critical analysis.`

Both the `cwd` and the condensed path have `\n` stripped before interpolation.

`postAnalysis` is `Present the analysis to the user, then stop.` by default. When
`INTERACTIVE_RECS` is truthy it is instead the multi-paragraph
`AskUserQuestion` block that names the todo path `<cwd>/.claude/watchdog-todo.md`
(also `\n`-stripped) and specifies the `## Rules to add` and `## Tasks` headings.
**[UNTESTED]**

### 7.4 Instruction files

`instructionFiles(rootDir)` builds candidates in this order:

1. `<rootDir>/CLAUDE.md`
2. `<rootDir>/.claude/rules/*.md`, sorted by filename
3. `~/.claude/CLAUDE.md`
4. `~/.claude/rules/*.md`, sorted by filename

`rootDir` is `projectRoot(cwd)` when `cwd` exists, otherwise `null`, in which
case only the two global entries are candidates. Then, walking the list in order:
a file whose size cannot be `stat`ed is skipped silently; a file over 8192 bytes,
or one that would push the running total over 16384 bytes, is skipped with a
`RULES:` log line; anything else is accepted and its size added to the total.

Note the total cap is checked before accretion, so it is a hard 16384-byte
ceiling on the sum of accepted files, and one oversized file part-way down the
list does not stop later smaller files from being accepted.

### 7.5 The hold message

```
claude-watchdog: a session analysis is still in flight, so your prompt was held to keep it from interleaving with the analysis (press up-arrow to restore it). Resubmit to override and continue anyway, or wait for the analysis — the hold auto-expires in ~<n>s.
```

`<n>` is `Math.max(0, Math.ceil(HOLD_TTL_SECONDS - ageSec))`. The message
contains a literal em-dash; it is user-facing text, quoted here verbatim.

The hold hook's own order is: opt-out (before stdin is read), stdin read and
parse, session-id regex, sentinel existence, TTL, nudge, block. Because the nudge
rewrite is wrapped in its own try/catch, a failed rewrite still blocks this once
and the TTL remains the backstop. **[UNTESTED]**

---

## 8. Trigger path, in order

Once gate 16 passes:

1. `process.umask(0o077)`.
2. `extractTranscript(deltaLines)` produces the raw text (section 9).
3. `condense(raw, CONDENSED_MAX_BYTES)` produces `{ content, rawSize }`.
4. `last_assistant_message`, trimmed, is appended as
   `\n\n=== FINAL ASSISTANT MESSAGE (session ended here) ===\n<message>\n`,
   **unless** the condensed content already contains the message's last 200
   characters. The tail probe exists so a message split across several text
   blocks still matches its own last `ASSISTANT:` line. Appending after
   `condense()` means the final message is never truncated away.
5. When verbose, a diagnostics header is prepended:
   `[DIAGNOSTICS] raw=<n>B condensed=<n>B tool_uses=<n> user_messages=<n> mid_turn_messages=<n> delta_start=<n>` followed by a blank line. Note
   `condensed=` is measured *before* the header is added, and the user and
   mid-turn counts are taken *after* the final message was appended.
6. Gate 17 (empty condensed).
7. Write `condensed-<sid>.txt` and log its size.
8. Compute the instruction (section 7.3).
9. Write the cursor from `lastUuid(DELTA_FILE)`, if the returned uuid matches
   `^[A-Za-z0-9_-]+$`. A `null` result leaves the cursor untouched with no log
   line at all.
10. Write the echo sentinel; write the pending sentinel when `HOLD_INPUT` is
    truthy.
11. Emit (legacy: stderr plus exit 2; default: stdout JSON plus exit 0).
12. The exit handler removes the marker directory and the delta file.

Step 9 happening before step 11 matters: the cursor advances even if the model
ignores the block.

---

## 9. Condensed transcript grammar

Produced by `extractTranscript()` in `hooks/condense.mjs`. One line per emitted
item, joined with `\n`. No trailing newline is added by the function itself.

### 9.1 Pre-pass

Before emitting anything, the entry list is walked once to build:

- `toolNames`: a map from `tool_use.id` to `tool_use.name`, over `assistant`
  entries with array content. Used to label tool results and choose their cap.
- `attachmentPrompts`: the set of trimmed prompts from `attachment` entries whose
  `attachment.type` is `queued_command`, taking `attachment.prompt` when it is a
  string, else `attachment.content` when it is a string, else the empty string.

### 9.2 Labels

| Line | Emitted for |
| --- | --- |
| `USER: <text>` | `user` entry with string content that does not match the mid-turn framing, or a `text` block in an array-content entry with no `tool_result` sibling and no framing |
| `USER (mid-turn): <text>` | The same, when the framing regex matches, or when a `tool_result` block shares the entry, or for a `queued_command` attachment whose `origin.kind` is missing or `human` |
| `USER (mid-turn, origin=<kind>): <text>` | A `queued_command` attachment whose `origin.kind` is present and is not `human` |
| `USER (edited file): <filename>` | An `edited_text_file` attachment. Falls back to `(unknown)` with no filename |
| `ASSISTANT: <text>` | A `text` block in an `assistant` entry. **Never truncated** |
| `THINKING: <text>` | A `thinking` block, cut at 300 chars |
| `TOOL_USE: <name>(<json>)` | A `tool_use` block. The JSON is `JSON.stringify(block.input)` cut at 500 chars, so a long input yields an unbalanced, unparseable fragment inside the parentheses. That is intentional: it is for a reader, not a parser |
| `TOOL_RESULT: <text>` | A `tool_result` block whose `tool_use_id` is not in the pre-pass map |
| `TOOL_RESULT[<name>]: <text>` | A `tool_result` block with a known tool |
| `TOOL_RESULT[ERROR]: <text>` / `TOOL_RESULT[<name>][ERROR]: <text>` | The same, with `is_error === true`. The `[ERROR]` marker is in the *label* so it is read before a body that may run 800 chars |
| `SYSTEM[hook-blocked <hookName\|hookEvent\|hook>]: <error>` | A `hook_blocking_error` attachment. The error is `attachment.blockingError.blockingError`, else `attachment.blockingError`, else empty, stringified and cut at 200 chars |
| `SYSTEM[plan_mode]` / `SYSTEM[plan_mode_exit]` | Those two attachment types. **No colon and no body** |
| `SYSTEM[attachment:<type>]: <json>` | Any other attachment type not in the noise set. `<type>` falls back to `unknown`; the JSON is the whole attachment cut at 200 chars |
| `SYSTEM[<entry type>]: <json>` | Any top-level entry type that is not `user`, `assistant`, `attachment`, or `queue-operation`, and is not in the noise set. `<type>` falls back to `unknown`; the JSON is the whole entry cut at 200 chars |

Every one of the numbers above was checked against the source: `TOOL_RESULT_MAX`
500, `TOOL_RESULT_MAX_BROWSE` 80, `TOOL_RESULT_MAX_VERBOSE` 800,
`TOOL_INPUT_MAX` 500, `THINKING_MAX` 300, `SYSTEM_MAX` 200.

The labels are duplicated as prose in `agents/session-analyzer.md`, which is what
the analyzer reads to interpret them. The two must stay in step; today the suite
enforces that by grepping the JS source for `output.push(\``, which a port
breaks.

### 9.3 Tool result caps

```
cap = 800  if is_error === true or name === 'Bash'
    = 80   if name in {Read, Glob, Grep, LS}
    = 500  otherwise
```

The error and Bash cases are checked first, so an errored `Read` gets 800, not
80. Content handling: a string `content` is cut at the cap; an array `content`
has its `text` blocks joined with `\n` and *then* cut at the cap, so non-text
blocks (images) contribute nothing; anything else renders as the literal
`(no content)`, which is emitted un-capped and regardless of the tool.

**[OPEN QUESTION FOR THE PORT]** An image-only `tool_result` renders as an empty
body rather than `(no content)`, because the array branch is taken and the filter
leaves an empty string. Only a `content` that is neither string nor array reaches
the `(no content)` fallback. Decide whether an empty filter result should also
say `(no content)`, so the analyzer can tell "the tool returned an image" from
"the tool returned nothing".

### 9.4 Caps are character-based, not byte-based

Every cap above uses `String.prototype.slice`, which counts UTF-16 code units. A
cut can land between the two halves of a surrogate pair, producing a lone
surrogate that encodes to U+FFFD on write. The UTF-8 safety noted in
`design/unhack.md` applies to the byte-budget path in section 9.7, which is
line-wise, and not to these per-kind caps. **[UNTESTED]**, and nothing non-ASCII
appears in any fixture.

**[OPEN QUESTION FOR THE PORT]** A language whose strings are byte slices or
Unicode scalar values cannot reproduce UTF-16 code-unit truncation exactly, and
should not try. The sensible port target is "cut at N Unicode scalar values,
never splitting a character". That changes the cut position for astral text only.
Decide it explicitly rather than discovering it in a golden-file diff.

### 9.5 Noise sets

Dropped entirely, emitting no line.

Top-level entry types (`NOISE_TYPES`):
`last-prompt`, `custom-title`, `ai-title`, `pr-link`, `mode`.

Attachment types (`NOISE_ATTACHMENTS`):
`task_reminder`, `deferred_tools_delta`, `agent_listing_delta`,
`mcp_instructions_delta`, `skill_listing`.

Unknown types are deliberately **not** dropped: they fall through to a
`SYSTEM[...]` line, so a future entry type carrying user text degrades to noisy
rather than invisible.

### 9.6 Mid-turn detection

Three independent signals, all producing the same `USER (mid-turn)` label:

1. A `queued_command` attachment (the authoritative record).
2. A `queue-operation` entry with `operation === 'remove'` and non-empty trimmed
   `content` that is **not** already in `attachmentPrompts`. `dequeue` and
   `enqueue` operations emit nothing. This is a fallback for builds that do not
   log the attachment, and the set membership test is what stops the same message
   appearing twice.
3. The framing regex

   ```
   /^\s*\[?\s*The user sent (?:a |an |another )?new message while you were working:?\s*\]?\s*/i
   ```

   which is both a detector and a stripper: the matched prefix is removed from
   the emitted text so the message reads as the user's own words.

Plus the structural signal: any `text` block sharing a `user` entry with a
`tool_result` block is mid-turn, because it was typed while the turn was running.

### 9.7 The byte budget

`condense(rawContent, maxBytes)`:

- If `Buffer.byteLength(rawContent) <= maxBytes`, the content is returned
  unchanged with `truncated: false`. No header, no separators.
- Otherwise the raw lines are partitioned by `USER_LINE = /^USER(?: \([^)]*\))?: /`,
  which matches all four `USER` variants and nothing else.

  - The **user** part gets `Math.floor(maxBytes / 5)` bytes, that is 20%.
  - The **other** part gets `Math.floor(maxBytes * 4 / 5)` bytes, that is 80%,
    taken from the **tail** so the most recent tool traffic survives.

  The two budgets are computed independently and the framing lines are not
  charged to either, so the final output can exceed `maxBytes` by the header, the
  separator, the blank lines, and up to one byte of flooring per part.

`takeLines(lines, budget, from)` accumulates whole lines from one end, charging
`Buffer.byteLength(line) + 1` per line for the newline, and stops at the first
line that would exceed the budget rather than skipping it and trying the next.
Cutting line-wise is what guarantees no cut lands mid-line or splits a UTF-8
character.

`clampUserLines(userLines, budget)`:

- If the joined user lines already fit the budget, they are returned unchanged
  and no elision marker appears.
- Otherwise `room = max(0, budget - byteLength(ELISION) - 1)`, the head takes
  `Math.floor(room * 0.4)` bytes (40%), and the tail takes `room - head.used`
  bytes (the remaining 60% plus whatever the head left unspent) from the lines
  *after* the head selection. Result:
  `[...head, ELISION, ...tail]`.

  `ELISION` is exactly `--- [earlier user messages elided] ---`.

The head-plus-tail shape exists because the head carries the session goal and the
tail carries the most recent asks, which is where mid-turn corrections land.

The assembled output when truncation happened, in order:

```
[TRUNCATED] Original transcript was <rawSize> bytes (~<droppedKb>KB dropped). Early context may be incomplete.
<blank>
<user part>
<blank>
--- [above: user messages in order, mid-turn ones labelled; below: recent tool calls and responses] ---
<blank>
<other part>
```

`droppedKb` is `Math.floor((rawSize - maxBytes) / 1024)`, so it is the bytes over
the *budget*, not the bytes actually discarded, and it reads low whenever the
parts underspend their budgets.

The `[TRUNCATED]` header is unconditional, not verbose-only: without it a
truncated file reads to the analyzer as a session that ended early, and it cannot
tell that a missing instruction was elided rather than never given.

### 9.8 `counts()`

Returns `{ user, midTurn }`: the number of lines matching `USER_LINE` and the
number matching `MIDTURN_LINE = /^USER \(mid-turn/`. Note `MIDTURN_LINE` matches
both `USER (mid-turn):` and `USER (mid-turn, origin=...):`, so automation-injected
prompts are counted as mid-turn in the diagnostics header. Used only for the
verbose header.

---

## 10. The condense debug CLI

`hooks/condense.mjs` runs as a CLI when invoked directly. A sibling station is
keeping this as a supported interface, so it is part of the contract.

```
<binary> condense <transcript.jsonl> [maxBytes]
<binary> extract  <transcript.jsonl>
```

- `extract`: reads the file, splits on `\n`, runs `extractTranscript`, writes the
  result plus a trailing `\n` to stdout, exits 0.
- `condense`: the same, then runs `condense()` with `maxBytes` parsed by
  `parseInt(arg ?? '51200', 10)`, writes `.content` plus a trailing `\n`, exits 0.
  A non-numeric `maxBytes` yields `NaN` with the consequences in section 3.5.
- Any other first argument, including none: writes
  `usage: condense.mjs extract <transcript.jsonl> | condense <transcript.jsonl> [maxBytes]`
  to stderr and exits **2**.
- Any thrown error: writes `condense error: <message>` to stderr and exits **1**.

Note the trailing newline the CLI adds is not present in the string the Stop hook
writes to `condensed-<sid>.txt`. A golden file generated through the CLI differs
from the on-disk artefact by exactly that byte.

The usage string names `condense.mjs` specifically. A port shipping a differently
named binary must decide whether to keep the literal text (so any test asserting
on it keeps passing) or use the real program name.

`hooks/cursor-slice.mjs` has a parallel CLI (`slice`, `last-uuid`) with the same
exit-code scheme, printing `DELTA_START=<n>` and `UUID=<u>\nREL_LINE=<n>`
respectively, and exiting 1 when `last-uuid` finds nothing. Section 1's
recommendation in `design/rewrite-readiness.md` is to drop the tests that drive
it, and it is **not** proposed as a supported interface.

---

## 11. Summary of what has no test today

Collected from the tags above, for whoever writes section 3 of
`design/rewrite-readiness.md`:

- Stop-hook stdin cap and garbage-stdin fail-open (the hold hook has this test).
- Every `stop_reason` value other than the tested one.
- Legacy exit-2 mode, end to end.
- Boolean parsing edge cases (`TRUE`, `yes`, `on`, empty string) at any call site.
- Integer parsing of a non-numeric value, for all six integer settings.
- `cfg()` precedence at every call site except `MIN_TOOL_USES`.
- `MultiEdit`, `NotebookEdit`, and the `edited_text_file` attachment as edits.
- The `READ_ONLY_BASH` regex, per pattern.
- Touched-file relativisation and newline stripping.
- Top-level user-message counting through the Stop hook gate.
- `projectRoot` stopping at `$HOME` and at the filesystem root.
- `cwd` arriving as the literal string `"null"`.
- The two-hour cleanup sweep, the stale-marker sweep, log rotation, and the
  analyses cap in the Stop hook.
- Directory and file modes in both storage locations, including the delta file's
  pre-umask mode.
- The `Previous analysis:` prompt line, the `User instruction files:` line, and
  the whole `include_rules` size-filter path.
- `interactive_recommendations` and its todo path.
- Marker and delta removal on the SKIP paths.
- Multi-byte UTF-8 at any truncation boundary, and CRLF transcripts.
- The cursor and analysis file formats byte for byte.
- The hold hook's mtime fallback and its failed-nudge-still-blocks path.
- The persist hook's 20-file prune and its stdin cap.
