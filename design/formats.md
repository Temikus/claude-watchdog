# External Formats the Hooks Depend On

Two formats owned by Claude Code, neither of them documented publicly, both
load-bearing for this plugin: the session transcript JSONL, and the hook event
payloads delivered on stdin. This document records what the hooks actually read,
so a port has something to code against and so a Claude Code change that breaks
us can be recognised as such rather than debugged from scratch.

Derived from `hooks/*.mjs` and `tests/fixtures/midturn-session.jsonl` at commit
`0f83be5`. `design/contract.md` covers what the plugin *does* with these fields;
this document covers their shape on the wire.

## On version attribution

Only one field in either format can be dated from anything in this repository:
`background_tasks` and `session_crons`, which a code comment in
`hooks/session-analysis.mjs` pins to Claude Code >= 2.1.145. For every other
field and entry type below, **this repository contains no evidence of when it
appeared**, and no version is claimed. The plugin's own git history dates when
*the plugin* started reading a field, which is an upper bound on when Claude Code
introduced it and nothing more; that date is given where it is useful.

Feature detection, not version detection, is the pattern the hooks use, and the
port should keep it: an absent array is treated as empty, an absent `stop_reason`
is treated as `end_turn`, and an unknown transcript entry type falls through to a
visible `SYSTEM[...]` line rather than being dropped.

---

## 1. Transcript JSONL

One JSON object per line, at `event.transcript_path`. The hooks parse it with a
deliberately forgiving reader: a line is skipped unless its first character is
`{` and it parses as JSON. Blank lines, the trailing empty string after the final
newline, and any non-JSON line are silently ignored, so the format tolerates
corruption in the middle of a file.

The fixture includes a deliberate non-JSON line (`this is not JSON and must be
skipped`) to pin that behaviour.

### Fields common to real entries

Message entries carried by the harness (not the hand-written bookkeeping ones)
have been observed with: `parentUuid`, `isSidechain`, `type`, `uuid`,
`timestamp`, `userType`, `cwd`, `sessionId`, `version`, and `gitBranch`. The
hooks read only `type`, `uuid`, `message`, and `attachment`. Everything else is
ignored, including `version`, which would be the obvious place to read the Claude
Code version from and is currently unused.

`uuid` is the only field outside `type`/`message` the hooks depend on: it is the
cursor's anchor. `cursor-slice.mjs` requires it to be a string and, when writing
the cursor, requires it to match `^[A-Za-z0-9_-]+$`.

### 1.1 `user`

```json
{"type":"user","uuid":"u-0001","message":{"content":"I want to add bazel-compatible caching..."}}
```

`message.content` is either a string or an array of blocks. Block types the hooks
handle:

- `{"type":"text","text":"..."}`
- `{"type":"tool_result","tool_use_id":"toolu_07","content":<string or array of blocks>,"is_error":<bool>}`

A `tool_result`'s `content` array is filtered to `text` blocks; other block types
(images) are known to occur and contribute nothing. `is_error` is compared
strictly against `true`.

The structural rule the plugin relies on: a `text` block that shares an entry with
a `tool_result` block was typed while the turn was running, so it is mid-turn
input rather than a prompt that started a turn. This is an inference about how
Claude Code batches blocks, not a documented guarantee, and it is the single most
fragile assumption in the plugin.

**Version**: not determinable from this repository.

### 1.2 `assistant`

```json
{"type":"assistant","uuid":"a-0008","message":{"content":[{"type":"tool_use","id":"toolu_08","name":"Bash","input":{"command":"..."}}]}}
```

Block types the hooks handle: `text`, `thinking` (read from `block.thinking`),
and `tool_use` (`id`, `name`, `input`). `id` is what links a later `tool_result`
back to its tool name; a `tool_use` without an `id` is not registered, and its
result renders as an unlabelled `TOOL_RESULT:`.

For edit detection the hooks read `input.file_path` and, for `NotebookEdit`,
`input.notebook_path`. For the read-only Bash heuristic they read `input.command`.

`thinking` blocks are handled but appear in no fixture. **[No fixture coverage]**

**Version**: not determinable. `thinking` blocks and MCP-style tool names
(`mcp__server__tool`) are both handled generically and neither is dated.

### 1.3 `attachment`

```json
{"parentUuid":"...","isSidechain":false,"attachment":{...},"type":"attachment","uuid":"...","timestamp":"...","sessionId":"..."}
```

The payload is `entry.attachment`, keyed by its own `type`. Observed and handled:

| `attachment.type` | Shape | Plugin use |
| --- | --- | --- |
| `queued_command` | `{type, prompt, source_uuid, commandMode, origin:{kind}, timestamp}` | The authoritative mid-turn record. `prompt` is preferred; `content` is accepted as a string fallback. `origin.kind` is `human` for a person and something else (`cron` in the fixture) for automation |
| `edited_text_file` | `{type, filename, snippet}` | Emits `USER (edited file): <filename>` and adds the filename to the touched-file list. The `snippet` is deliberately not used: it is large and the diff shows the content anyway |
| `hook_blocking_error` | `{type, hookName, hookEvent, blockingError:{blockingError}}` | Rendered as `SYSTEM[hook-blocked ...]`. Note the doubly nested `blockingError`; the code accepts either nesting depth |
| `plan_mode`, `plan_mode_exit` | not in the fixture | Rendered as a bare `SYSTEM[plan_mode]` line. **[No fixture coverage]** |
| `task_reminder` | `{type, content, itemCount}` | Dropped as noise |
| `deferred_tools_delta`, `agent_listing_delta`, `mcp_instructions_delta`, `skill_listing` | not in the fixture | Dropped as noise. **[No fixture coverage]** |

Anything else becomes `SYSTEM[attachment:<type>]` with the attachment JSON cut at
200 characters, so a new attachment type is noisy but never invisible.

`commandMode` and `source_uuid` are read by nothing.

**Version**: not determinable. The plugin started reading `queued_command` in
commit `d6bb24e` (v0.14.2), which only bounds it from above.

### 1.4 `queue-operation`

```json
{"type":"queue-operation","operation":"remove","timestamp":"...","sessionId":"...","content":"You can check ../base-infrastructure..."}
```

`operation` is one of `enqueue`, `dequeue`, or `remove`, at least. The plugin
treats:

- `remove` as "the queued prompt was pulled out and injected into the running
  turn", so its `content` is a mid-turn user message,
- `dequeue` as "it became the next turn's own user message", already captured as
  a `user` entry, so nothing is emitted,
- `enqueue` as bookkeeping, so nothing is emitted.

`remove` is only used when the same trimmed text is *not* already present as a
`queued_command` attachment, which is what prevents the same mid-turn message
being counted twice. Some builds appear to log only one of the two records, hence
the fallback.

**Version**: not determinable. Same commit-based upper bound as `queued_command`.

### 1.5 Bookkeeping entries

All dropped as noise, because each duplicates a real message entry or is UI-only.
Their shapes, from the fixture:

```json
{"type":"last-prompt","lastPrompt":"...","leafUuid":"u-0001","sessionId":"..."}
{"type":"mode","mode":"normal","sessionId":"..."}
{"type":"pr-link","sessionId":"...","prNumber":877,"prUrl":"https://...","prRepository":"org/repo","timestamp":"..."}
{"type":"custom-title","customTitle":"...","sessionId":"..."}
{"type":"ai-title","aiTitle":"...","sessionId":"..."}
```

`last-prompt` duplicates the `user` entry that `leafUuid` points at.
`custom-title` and `ai-title` are window titles. `mode` records a mode ping
(`normal` observed; other values presumably exist for plan mode and similar).
`pr-link` records a PR the session opened.

Note that these entries carry **no `uuid`**, so they can never become the
cursor's anchor. `lastUuid()` scanning backwards skips them, which is why a
transcript ending in a `pr-link` still produces a usable cursor.

**Version**: not determinable for any of the five.

### 1.6 Sidechain entries

`isSidechain` is present on harness-written entries and is `false` throughout the
fixture. **The hooks never read it.** A sidechain (subagent) session's entries
are therefore condensed exactly like main-thread ones.

In practice this rarely bites, because the Stop hook skips any event carrying
`agent_id`, so a subagent's own Stop never reaches the condenser. What is not
covered is a *main-thread* transcript that has sidechain entries interleaved into
it. No fixture exercises that. **[No fixture coverage]**

**[OPEN QUESTION FOR THE PORT]** Whether sidechain entries should be filtered out
of the delta, or labelled, is undecided. Today they are silently treated as
first-class session content, which can make a subagent's tool calls count towards
`MIN_TOOL_USES` and its text count as an assistant message.

**Version**: not determinable.

### 1.7 Compaction summaries

Claude Code writes a summary entry when a session is compacted. **No fixture
contains one, and the hooks have no branch for it**, so whatever its `type` is,
it falls through to the generic `SYSTEM[<type>]: <json cut at 200 chars>` line.
Its shape is not recorded anywhere in this repository, and nothing here
determines it.

The related behaviour that *is* handled: a Stop fired by compaction carries a
`stop_reason` other than `end_turn` and is skipped at gate 4, so the plugin never
analyses the compaction turn itself. The transcript *after* a compaction is a
different matter: the cursor's uuid will no longer be found in the rewritten
file, `slice()` falls through to `deltaStart = 1`, and the whole post-compaction
transcript is treated as the delta. That is a graceful failure, not a designed
one. **[No fixture coverage]**

### 1.8 Unknown types

The fixture deliberately contains:

```json
{"type":"totally-unknown-future-type","uuid":"x-0001","payload":"kept as SYSTEM so a new user-bearing type is never invisible"}
```

Emitted as `SYSTEM[totally-unknown-future-type]: <json cut at 200 chars>`. This
is the format's forward-compatibility contract, and it is worth keeping in a
port: an unrecognised entry that carries user text degrades to noisy, never to
invisible.

---

## 2. Hook event payloads

Delivered as one JSON object on stdin. Every test in the suite builds these by
hand with `jq -n`; **none was captured from a real Claude Code run**, so the
shapes below are what the hooks read, cross-checked against the code comments
written when each was added, and not against a recorded payload.

`design/rewrite-readiness.md` section 4 proposes `CLAUDE_WATCHDOG_DUMP_EVENTS` to
fix exactly this. Until that lands, treat this section as the plugin's belief
about the format rather than an observation of it.

### 2.1 `Stop`

| Field | Type | Notes |
| --- | --- | --- |
| `session_id` | string | Assumed to match `^[a-zA-Z0-9_-]+$`; anything else is rejected outright, both as a sanity check and to keep the value safe to interpolate into a path |
| `transcript_path` | string | Absolute path to the JSONL |
| `cwd` | string | The shell's working directory at stop time, which is **not** necessarily the project root; `projectRoot()` exists because of that. Also known to arrive as the literal string `"null"` in some circumstance, which the code guards against |
| `stop_reason` | string | `end_turn` is the only value that proceeds. Others named in the README: compaction, `tool_use`, `max_tokens`. Absent on some builds, defaulted to `end_turn` |
| `stop_hook_active` | boolean | `true` when this Stop is itself the result of a Stop hook blocking, including another plugin's hook. Compared strictly against `true` |
| `background_tasks` | array | Each element has a `.type`, joined into the log line. Only the length is gated on |
| `session_crons` | array | Each element has a `.prompt` string, regex-tested for `analyze-session` or `session-analyzer` |
| `agent_id` | string | Present when the Stop belongs to a subagent or teammate rather than the main session. Any truthy value skips |
| `agent_type` | string | Logged alongside `agent_id`; rendered as `unknown` when absent |
| `last_assistant_message` | string | The concluding assistant text. It is on the event before it is reliably on disk in the transcript, which is the whole reason the hook reads it |

**Versions.**

- `background_tasks` and `session_crons`: **Claude Code >= 2.1.145**, per the
  comment in `hooks/session-analysis.mjs` added in commit `f97692c`. This is the
  only version number in the repository, and the code explicitly feature-detects
  so older builds behave as before.
- `stop_hook_active`: not determinable. The plugin started reading it in commit
  `cd1949f`.
- `agent_id` and `agent_type`: not determinable. The plugin started reading them
  in commit `873a027`.
- `last_assistant_message` on the **Stop** event: not determinable. The plugin
  started reading it in commit `044cf65`, and the fix in `afc4d73` shows it can
  arrive either before or after the message reaches the transcript, so it races
  the disk flush. That race is the reason the hook probes for the message's last
  200 characters before appending it.
- `session_id`, `transcript_path`, `cwd`, `stop_reason`: not determinable;
  assumed to predate the plugin.

### 2.2 `UserPromptSubmit`

Only `session_id` is read. The submitted prompt text is present on the event and
is deliberately never read, never logged, and never written anywhere: this hook
runs on every prompt submission, so it exits before reading stdin when the
feature is off, and its log lines carry only the session id and an age in
seconds.

**Version**: not determinable. The plugin started using the event in commit
`d1acfab`.

### 2.3 `SubagentStop`

| Field | Type | Notes |
| --- | --- | --- |
| `agent_type` | string | Must equal `session-analyzer` exactly, or the hook exits 0 having done nothing. Note this is the bare agent name, **not** the namespaced `claude-watchdog:session-analyzer` used in the `subagent_type` the Stop hook asks for |
| `session_id` | string | Same regex as the Stop hook. Names the output file and the pending sentinel to clear |
| `last_assistant_message` | string | The analyzer's final message, written verbatim to the analysis file with a trailing newline |

`hooks.json` also sets a `matcher` of `session-analyzer` on this hook, so Claude
Code filters on the agent type before the hook runs; the in-hook `agent_type`
check is a second line of defence in case the matcher semantics differ from what
is assumed.

**[OPEN QUESTION FOR THE PORT]** The bare-name versus namespaced-name asymmetry
(`matcher: "session-analyzer"` and `agent_type === 'session-analyzer'` against
`subagent_type: "claude-watchdog:session-analyzer"`) is undocumented behaviour we
are relying on. Capturing one real `SubagentStop` payload would settle it, and it
belongs in the first batch of captured fixtures.

**Version**: not determinable for any of the three fields.

---

## 3. What to capture first

If only a handful of real payloads can be sanitised and committed, these five
resolve the most uncertainty, in priority order:

1. A `SubagentStop` from a real analyzer run, to settle the `agent_type` naming
   question in section 2.3.
2. A `Stop` with `background_tasks` non-empty, to confirm the element shape
   beyond `.type`.
3. A `Stop` from a post-compaction session, plus the transcript, to record the
   compaction summary entry type that section 1.7 cannot describe.
4. A transcript containing `thinking` blocks and a non-text `tool_result`, since
   both have handling code and no fixture.
5. A transcript with sidechain entries interleaved into the main thread, to
   decide the open question in section 1.6.
