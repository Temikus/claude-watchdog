# Design note: session-analyzer receives cut-off transcripts

**Status:** Fixes #1 and #3 implemented; #5 addressed. **#2 (goal anchor for deltas) and #4 (non-git sessions) are the remaining gaps** and belong in any port's scope decision.
**Date:** 2026-07-07
**Scope:** `hooks/session-analysis.mjs`, `hooks/cursor-slice.mjs`, `hooks/persist-analysis.mjs`, `agents/session-analyzer.md`
**Relationship to other work:** Orthogonal to the trigger-timing hardening (PR #8 `stop_hook_active`, the `background_tasks` gap). Those govern *when* the Stop hook fires; this note is about *what content* the analyzer receives once it does.

- #1 done: final assistant message appended, deduped when the transcript flush beat the hook.
- #3 done: `hooks/condense.mjs` keeps both ends of the user thread (`clampUserLines`, 40/60 head/tail split with an elision marker), emits the `[TRUNCATED]` notice unconditionally rather than verbose-only, and accumulates whole lines (`takeLines`) so a cut never lands mid-line or mid-UTF-8-char.
- #5 addressed: the cap is now the `max_transcript_bytes` user config (default 51200, range 4096-512000) and is documented in the README.

---

## Symptom

The `session-analyzer` agent repeatedly misreports that the session "ended mid-task" / "the transcript cuts off before the final output was produced," and guesses at or mislabels the session goal ("this appears to be a separate/unclear task"). This has been happening more frequently on longer, MCP-heavy sessions (Slack, Datadog, etc.).

Across one multi-turn session that produced four complete deliverable drafts (v1–v4), *every* analyzer run claimed the final draft may not have been produced — even though each draft was, in fact, delivered.

## Root cause

Confirmed from the actual condensed file fed to the analyzer for this session. Its `[DIAGNOSTICS]` header read:

```
raw=39282B condensed=39282B ... delta_start=139
```

`raw == condensed`, so **the byte-size truncation (`CONDENSED_MAX_BYTES`, default 51200) never fired.** The size cap is not the cause. Two other mechanisms are:

### 1. Incremental deltas start mid-session with no goal anchor
`delta_start=139` means the condensed file begins at transcript line 139. The cursor/delta mechanism (`hooks/cursor-slice.mjs`) advances each run, so every analysis after the first **excludes the original objective and all earlier work**. The file opens on a bare `SYSTEM[last-prompt]` metadata line with zero framing — hence the analyzer repeatedly guessing at, or misidentifying, the task.

### 2. The final assistant message is absent from the delta
The last `ASSISTANT:` line captured in the delta is the model *announcing* an action (e.g. "Let me search the inverse…"), after which the file ends on tool-results plus the `SYSTEM[last-prompt]` line. The concluding assistant turn — the actual synthesized deliverable — **is not in the file at all.** So "the transcript cuts off before the final output was produced" was *literally true of the input handed to the analyzer*, every time, even though the session did produce that output.

### Why "more and more lately"
Longer, MCP-heavy sessions produce large deltas with lots of trailing tool-result noise. The tail the analyzer sees is increasingly tool-results rather than the concluding assistant turn, making the "cut off before the answer" artifact more likely.

## Recommended fixes (ranked)

### 1. Append the final assistant message, explicitly anchored — *highest value*
`event.last_assistant_message` is already provided by Claude Code and is already consumed in `hooks/persist-analysis.mjs:26` (`event.last_assistant_message ?? ''`), but **not** in `session-analysis.mjs`. After building `condensedContent`, append it under a clear header, e.g.:

```
=== FINAL ASSISTANT MESSAGE (session ended here) ===
```

Feature-detect with `event.last_assistant_message ?? ''`. This single change removes the recurring "cuts off before final output" misdiagnosis.

### 2. Give the delta a goal anchor - **outstanding**
Because analysis is incremental, prepend the session's **first user message** (or persist it alongside the cursor in `cursor-slice.mjs`) so post-first-run deltas still carry the original objective. Fixes the "unclear / separate task" misfires.

### 3. Fix the truncation path for when it *does* fire - **done**, in `hooks/condense.mjs`

The truncation path has since moved out of `session-analysis.mjs` into `condense.mjs`. All three sub-points below shipped there; kept for the record.
- `userBuf.slice(0, USER_BUDGET)` (line 392) keeps the **oldest** user turns and drops the most recent instruction. Invert to `.slice(-USER_BUDGET)`, or keep first + last.
- Emit the `[TRUNCATED]` notice **unconditionally**, not only in verbose mode — otherwise a genuinely truncated file reads to the analyzer as a session that ended early.
- Trim byte-slices to line boundaries. `.slice(0, N)` / `.slice(-N)` cut mid-line and mid-UTF-8-char, producing garbled partial lines that themselves read as "cut off."

### 4. Stop assuming a code session (`agents/session-analyzer.md`) - **outstanding**
The agent hard-codes a `git diff` / `git log` workflow and a rubric that cross-checks findings against the code diff. For non-code sessions (e.g. a drafting task) — or a working dir that isn't a git repo — that workflow yields nothing and the goal-check misfires. Add a branch: if there's no git repo / no diff, evaluate the transcript on its own terms.

### 5. Minor - raise/document the byte cap - **addressed**
`CLAUDE_WATCHDOG_MAX_BYTES` default of 51200 (`session-analysis.mjs:17`) is low for MCP-heavy turns. Worth raising or documenting, though fixes #1 and #2 do the real work.

## Suggested sequencing
Fixes #1, #3, and #5 have landed. What remains is **#2** (goal anchor, the immediate recurring pain) and **#4** (non-git sessions).

## Verification notes
File paths and symbols referenced above were confirmed present on `main` at time of writing:
- `session-analysis.mjs:17` — `CONDENSED_MAX_BYTES` default `51200`
- `session-analysis.mjs:378-392` - truncation path; `USER_BUDGET` (385), `userBuf.slice(0, USER_BUDGET)` (392). Since moved to `hooks/condense.mjs` (`takeLines`, `clampUserLines`, `condense`) as part of fix #3.
- `session-analysis.mjs:411` — `[DIAGNOSTICS]` header emission
- `persist-analysis.mjs:26` — existing `event.last_assistant_message ?? ''` usage (precedent for fix #1)
- `hooks/cursor-slice.mjs` — delta/cursor mechanism (fix #2)
- `agents/session-analyzer.md` — hard-coded git rubric (fix #4)
