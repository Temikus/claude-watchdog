# Claude Watchdog - Rewrite Readiness

What has to be true of the tests, CI, and docs before the hooks are ported to
another language, so the port can be proven equivalent rather than trusted.
Drafted 2026-08-30 from a full read of the hooks, `justfile`, README, agent and
skill prompts, the design notes, CI config, and the fixture.

Status legend: `[ ]` open, `[x]` done. Tick items off in place as they land.

---

## TL;DR

The test suite already has the right shape for a port: black-box bash + jq that
feeds JSON on stdin and asserts on stdout, exit code, log lines, and files on
disk. That is the asset to protect. What blocks a bulletproof rewrite:

1. The suite hardcodes `node hooks/*.mjs` (~50 call sites), tests internal
   helper CLIs, and greps JS source for labels. It cannot run against a second
   implementation as-is.
2. Assertions are `grep -q` for substrings. No byte-exact goldens, so a port can
   change whitespace, ordering, truncation boundaries, or prompt wording and
   still pass.
3. Roughly 20 documented behaviours have zero coverage (section 3).
4. No written contract for the gate order, file formats, env var parsing, or the
   hook event fields consumed. That knowledge lives in code comments only.
5. Docs drift in several places (section 7).

Suggested order: sections 1 and 6 (macOS CI) first, then 2, 3, 4, 5, 7, and only
then start the port with a parity job as the merge gate.

---

## 1. Make the suite implementation-agnostic

Do this before writing any code in the new language. The point is one suite
that runs unchanged against both implementations.

- [x] Parametrise the hook binaries. Introduce `HOOK_STOP`, `HOOK_HOLD`, and
      `HOOK_PERSIST` env vars, defaulting to `node hooks/session-analysis.mjs`
      etc. Every invocation in the tests goes through them. The parity run is
      then `HOOK_STOP=./bin/watchdog-stop ... just test`.
- [x] Move the cases out of `justfile` into `tests/*.sh` with a shared
      `tests/lib.sh` (`run_stop`, `outcome`, `mk_transcript`, `fail`). The
      1100-line justfile hides which lines are harness and which are assertions,
      and `just test-<name>` should stay as thin wrappers.
- [x] Replace the node-coupled tests:
  - [x] `test-cursor` Test 1 drives `cursor-slice.mjs slice|last-uuid`
        directly. Internal API. Drop it: Tests 4, 5, and 6 cover the same
        behaviour end to end through the Stop hook.
  - [x] `test-condense` drives `condense.mjs extract|condense`. Worth keeping
        as a stable, documented debug CLI (`<binary> condense <jsonl> [bytes]`)
        because it is useful for humans debugging a bad analysis too. Decide,
        then document it in the contract (section 5).
        Decided: kept and promoted to a supported interface. The decision and
        the exact wire format are written up in `tests/CONDENSE-CLI.md` for the
        contract station to fold into `design/contract.md`.
  - [x] `test-agent-prompt` greps `output.push(\`` in the JS to derive the
        transcript labels. Breaks on day one of a port. Replace with an explicit
        `tests/labels.txt` listing every label and assert both that each appears
        in `agents/session-analyzer.md` and that each appears in the golden
        condensed output (so the list cannot go stale).
        `tests/labels.txt` lands with the prompt assertion. The second half -
        asserting each label against the golden condensed output - waits on the
        section 2 goldens; add it there so the list cannot go stale.
  - [x] `lint` uses `node --check` and `node -e` for fixture validation. Swap
        the fixture check to `jq -c . < fixture` per line; the syntax check
        becomes whatever the target language's compiler does.
- [x] Make `smoke` hermetic. It currently writes to the real `$PWD/.claude/tmp`
      because the hook receives `cwd=$PWD`. Use a mktemp cwd like every other
      test.

## 2. Golden files, not greps

Generate byte-exact outputs from the current Node implementation before the
port and commit them. The port must reproduce them with `diff -u`. Any
intentional change updates the golden in the same PR.

- [ ] `tests/golden/midturn.extract.txt` - `extract` output for the fixture.
- [ ] `tests/golden/midturn.condense-4096.txt` and `-8192.txt` - the truncation
      path: both user-thread ends, the elision marker, the unconditional
      `[TRUNCATED]` notice, and the 20/80 and 40/60 splits.
- [ ] `tests/golden/stop.prompt.txt` - the `reason` string the Stop hook emits,
      with tmp paths templated out. Wording is what the model acts on.
- [ ] `tests/golden/stop.log.<skip-reason>.txt` - one per SKIP path. The README
      promises "every decision is logged" and users grep the log, so the log
      lines are a de facto API.
- [ ] The verbose `[DIAGNOSTICS]` header, with counts.

## 3. Untested behaviours

Verified by grepping the justfile for each behaviour's log line, env var, or
code path. Each needs a test against the current implementation first; any bug
found goes to `main` before the port so the goldens encode the intended
behaviour, not the accidental one.

### Stop hook (`session-analysis.mjs`)

- [ ] `stop_reason != end_turn` skips (compaction, `tool_use`, `max_tokens`).
- [ ] Missing or nonexistent `transcript_path` skips.
- [ ] `.claude-watchdog-skip` in the hook cwd skips.
- [ ] Read-only turn skips (`edits == 0 && mutatingBash == 0`), and the
      `READ_ONLY_BASH` regex itself: `sed -n` is read-only, `sed -i` is not,
      leading whitespace is tolerated, `git diff` yes but `git push` no.
- [ ] Zero top-level user messages in the delta skips. Includes the definition
      of "top-level": a text block sharing an entry with a `tool_result` does
      not count.
- [ ] `MultiEdit` and `NotebookEdit` (`notebook_path`) count as edits, and an
      `edited_text_file` attachment adds its filename to the touched list.
- [ ] Touched-file paths are made relative to the hook cwd, and newlines are
      stripped from them.
- [ ] `include_rules`: project files before global, files over 8 KB skipped,
      16 KB total cap, `CLAUDE_WATCHDOG_INCLUDE_RULES=0` sends none, and the
      skip reason is logged.
- [ ] `Previous analysis:` line appears in the prompt when a prior analysis
      file exists for the session, and points at the newest one.
- [ ] `interactive_recommendations` switches the post-analysis instruction
      block and the todo path.
- [ ] Legacy exit-2 mode (`CLAUDE_WATCHDOG_LEGACY_HOOK=true`): instruction on
      stderr, exit 2, nothing on stdout.
- [ ] Log rotation at `CLAUDE_WATCHDOG_LOG_MAX_LINES`, including the
      `LOG ROTATED` line.
- [ ] Two-hour cleanup of `condensed-`, `raw-`, `delta-`, `echo-`, and
      `pending-` files and stale marker directories, and the 20-file analyses
      cap in the Stop hook. Only the cursor TTL is tested today.
- [ ] Marker directory and delta file are removed on every exit path after
      acquisition, including the SKIP paths (cooldown, small delta, read-only,
      no user messages, empty condensed).
- [ ] Directories are created 0700 and files land 0600 (umask), in both storage
      locations.
- [ ] Garbage stdin and the 64 KB stdin cap fail open with exit 0 on the Stop
      hook. The hold hook has this test; the Stop hook does not.
- [ ] `cwd` arriving as the literal string `"null"` falls back to global
      storage.
- [ ] Empty condensed transcript skips.
- [ ] Multi-byte UTF-8 at a truncation boundary is never split. `unhack.md`
      item 4 says this is fixed; nothing non-ASCII is in any test.
- [ ] CRLF line endings in the transcript.
- [ ] Non-numeric numeric config. `CLAUDE_WATCHDOG_MIN_TOOL_USES=abc` parses to
      `NaN`, `count < NaN` is false, and the gate is silently disabled. Same
      for cooldown and max bytes. The port must decide (reject, or fall back to
      the default) and a test must pin the decision.
- [ ] Boolean config parsing: only `1` and `true` are truthy; `TRUE`, `yes`,
      and `on` are falsy. Pin it.
- [ ] `cfg()` precedence: `CLAUDE_WATCHDOG_*` beats `CLAUDE_PLUGIN_OPTION_*`
      beats default. Tested for `MIN_TOOL_USES` only; the port will touch every
      call site.
- [ ] `projectRoot` walk stops at `$HOME` and at the filesystem root.

### Hold hook (`hold-input.mjs`)

- [ ] `CLAUDE_WATCHDOG_HOLD_TTL_SECONDS <= 0` releases immediately.
- [ ] Sentinel line 1 that is not a parseable date falls back to mtime.
- [ ] A failed `nudged` rewrite still blocks this once.

### Persist hook (`persist-analysis.mjs`)

- [ ] 20-file cap prunes oldest by mtime.
- [ ] Filename format `<session_id>-YYYYMMDDTHHMMSSZ.md`.
- [ ] 128 KB stdin cap.

## 4. Fixtures and the undocumented external formats

Two poorly documented, changing formats are load-bearing, which is exactly the
case where integration fixtures earn their keep:

- Transcript JSONL entry types: `user`, `assistant`, `attachment.*`,
  `queue-operation`, `last-prompt`, `mode`, `pr-link`, sidechain entries,
  compaction summaries. There is one fixture.
- Hook event payloads: `stop_hook_active`, `background_tasks`, `session_crons`,
  `last_assistant_message`, `agent_id`, `agent_type`. Every test builds these
  by hand with `jq -n`; none was captured from a real Claude Code run.

- [ ] Add `CLAUDE_WATCHDOG_DUMP_EVENTS=<dir>` to write raw stdin per hook
      invocation. Run a few real sessions, sanitise, and commit
      `tests/fixtures/events/{stop-plain,stop-echo,stop-bg-tasks,subagent-stop,
      prompt-submit}.json`. Tests then load these instead of literals.
- [ ] More transcript fixtures: a subagent/sidechain session, a post-compaction
      session, a session with `thinking` blocks, MCP tool names, and image
      `tool_result` content (non-text blocks currently render as
      `(no content)`), and a >1 MB session for the perf budget.
- [ ] `just fixture-sanitise <path>` so capturing a new fixture is cheap enough
      to actually happen.
- [ ] `design/formats.md` documenting each transcript entry type and each event
      field the hooks consume, with the Claude Code version it appeared in.

## 5. Write the contract

No single document states what the plugin does at wire level. The port needs
one to port against, and every line in it should map to a test. A line with no
test is a gap.

- [ ] `design/contract.md` covering:
  - Inputs: the three events, the fields consumed, the stdin caps.
  - Gate order exactly as the code has it: disabled, session id, `agent_id`,
    `stop_reason`, echo sentinel, background tasks, session cron, skip file,
    storage resolution, marker, transcript, cursor, cooldown, delta size, edits,
    user messages, empty condensed. Order has side effects: the echo sentinel is
    cleared before the skip-file check, and the cooldown is checked after the
    marker is acquired. The README lists the gates in a different order.
  - Every env var and plugin option, precedence, and bool/int parsing rules.
  - File formats: cursor (three lines: uuid, absolute line, transcript path),
    echo sentinel (ISO timestamp), pending sentinel (ISO timestamp plus optional
    `nudged`), marker directory, analysis filename, `condensed-`/`raw-`/`delta-`
    names, and the storage-root resolution rules (`projectRoot`).
  - Outputs: stdout JSON shape, exit codes (always 0 except legacy mode's 2),
    log line prefixes (`SKIP:`, `TRIGGER:`, `CURSOR:`, `ECHO:`, `RULES:`,
    `[hold]`, `[persist]`).
  - Condensed transcript grammar: every label, the per-kind caps (500 default,
    80 browse, 800 Bash and errors, 300 thinking, 500 tool input, 200 system),
    the noise sets, the 20/80 user/other budget split, and the 40/60 head/tail
    split inside the user budget.

## 6. CI

- [x] Add `macos-latest` to the matrix now, before the port. Development
      happens on macOS and CI runs Ubuntu only; `stat`, `mktemp`, and `date`
      differ. The suite must be proven portable before it is asked to prove
      something else.
- [x] `shellcheck` on `tests/*.sh` once extracted, and `just --fmt --check`.
      Both run from `just lint`, so `just check` and CI cover them.
- [ ] One-off coverage run (`NODE_V8_COVERAGE` + `c8`) over the bash suite to
      get the real branch list for section 3. Do not keep it in CI.
- [ ] Parity job during migration: matrix over `impl: [node, <new>]`, both must
      pass the same suite. This is the merge gate for the port.
- [ ] Release pipeline. A compiled target means shipping per-OS/arch binaries or
      building on install. `just release` tags but no workflow consumes tags.
      Needs a cross-compile matrix, artifact upload, and a `hooks.json` command
      that selects the binary per platform. `node-runtime-availability.md`'s
      launcher design becomes "pick the binary for `uname`" and should be
      reworked for the new target. Also confirm the installed plugin keeps the
      exec bit (that doc notes it can be lost) via `just install-dev` on both
      OSes.
- [x] Perf budget tests in `tests/perf.sh`: the hold hook runs on every prompt
      (README claims 30-80 ms), so assert < 100 ms; the Stop hook on a 5 MB
      transcript < 2 s. Measure before and after, since startup time is likely
      a motivation for the port.
      Wired as `just test-perf`, deliberately outside `just test` and CI: the
      100 ms budget is within noise of Node's startup on a shared runner.
      Node baseline on an M-series laptop: hold ~70-95 ms (best of 10),
      Stop on 5.3 MB ~210 ms.

## 7. Documentation drift

- [x] README "How it works" step 4 says exit 2 + stderr. The default has been
      exit 0 + JSON `decision: block` since backlog item 1 landed. Fixed; the
      legacy mode is documented as the `CLAUDE_WATCHDOG_LEGACY_HOOK` opt-in.
- [x] README Requirements say Node >= 18; the CI floor is 20. Picked 20. There
      is no `package.json`, so no `engines` field to reconcile.
- [x] README gate list order differs from the code (section 5). Re-derived from
      `session-analysis.mjs`; the session-id and `agent_id` gates were missing
      entirely.
- [x] README "Session has not already been analyzed (marker ... auto-expires
      after 2 hours)" describes the concurrency lock but reads as once-per-
      session. Reworded: the marker is a per-run lock released on exit, and the
      cooldown is what spaces repeat analyses.
- [x] `design/unhack.md` starts at item 2 (item 1 was removed) and the
      sequencing table still references item 1.
- [x] `design/backlog.md` item 1 is done but still listed HIGH; item 2
      duplicates `unhack.md` item 5.
- [x] `design/condensed-transcript-cutoff.md` says fixes 2 to 5 are outstanding,
      but fix 3 (both user-thread ends, unconditional notice, line-boundary
      cuts) shipped in `condense.mjs`. Fixes 2 (goal anchor for deltas) and 4
      (non-git sessions) remain real gaps and belong in the port's scope
      decision. Fix 5 is covered by `max_transcript_bytes`.
- [x] `skills/analyze-session/SKILL.md` has diverged from the agent prompt
      (300 vs 350 words, mandatory vs conditional sections, no transcript
      legend). Aligned; the missing legend is now stated as deliberate, since
      the skill reads the live conversation rather than a condensed file.
- [x] `plugin.json` description carries no runtime requirement. Names the Node
      20 floor now; revisit when the binary/runtime story is decided.

Found while fixing the above, not previously listed:

- [x] README said the `.claude-watchdog-skip` file is looked for "in any project
      root". The hook checks the session's `cwd`, not the walked project root.
- [x] `CLAUDE_WATCHDOG_LEGACY_HOOK` was undocumented anywhere. Now in the
      advanced-overrides table.

---

## Sequence

1. Section 1 and the macOS CI item. Suite unchanged in meaning, now portable and
   parametrised.
2. Section 2. Goldens generated from the current implementation and committed.
3. Section 3. Gaps filled against the Node implementation; bugs fixed on `main`
   first.
4. Section 4. Real event and transcript fixtures captured.
5. Sections 5 and 7. Contract written, README drift fixed.
6. Start the port, with the parity job green as the merge gate.
