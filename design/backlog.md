# Claude Watchdog — Improvement Backlog

Generated from UX analysis of real session transcripts cross-referenced with
the latest Claude Code plugin documentation (2026-05-04).
Last pruned: 2026-05-15.

---

## DONE

### 1. Eliminate "Stop hook error" framing on analysis trigger

**Status: done.** The Stop hook now exits `0` and writes
`{"decision": "block", "reason": "..."}` to stdout; the `reason` does reach
Claude as actionable context, so option 2 of the original investigation was the
one that worked. The old exit-2 + stderr path is kept behind
`CLAUDE_WATCHDOG_LEGACY_HOOK=true` for hosts that do not honour the JSON
decision. `unhack.md` numbering starts at 2 for the same reason.

---

## HIGH PRIORITY

### 2. Handle `/clear` boundaries to prevent stale transcript analysis

See `unhack.md` item 5 (`/clear` boundary cursor reset), which carries the
investigation and the timestamp-based cursor naming approach. Tracked there,
not here.

---

## MEDIUM PRIORITY

### 3. Confirm analysis save path to the user

**Problem:** The SubagentStop hook persists analyses silently. Users never see
where the file was saved and have no way to find it after the session ends.

**Fix:** Have `hooks/persist-analysis.sh` output the save path on stdout
(exit 0) so it appears in the transcript, e.g.:

```
Analysis saved to: ~/.claude/logs/claude-watchdog-analyses/<session>-<ts>.md
```

---

### 4. Add urgency ranking to recommendations

**Problem:** The session-analyzer produces consistently useful recommendations,
but all items are formatted identically. "Revert retries after CI stabilizes"
and "A 4700-char prompt was pushed without review" look the same.

**Fix:** Update the agent prompt in `agents/session-analyzer.md` to require
urgency labels on each recommendation:

- `[ACTION REQUIRED]` — needs immediate follow-up
- `[SHOULD]` — do soon, but not blocking
- `[CONSIDER]` — nice-to-have or long-term

---

### 5. Address first-session analysis latency

**Problem:** One observed analysis took 68 seconds (long session with large
transcript). Subsequent analyses were 25-30 seconds. A 68-second delay at
session end is noticeable friction.

**Partial progress:** `max_transcript_bytes` is now enforced via `userConfig`
(default 51200, configurable 4096–512000) with weighted truncation in
`session-analysis.mjs`. This addresses the transcript size cap.

**Remaining:**
- Consider using `"async": true` or `"asyncRewake": true` on the Stop hook so
  session ending feels instant and analysis runs in the background.
- Trade-off: async means the user might not see the analysis before closing the
  terminal.

---

### Input-hold follow-ups (from the 2026-07-03 hold_input_during_analysis work)

- **Foreground nudge:** append "run the analyzer in the foreground — do not
  background it" to the Stop-hook instruction in `session-analysis.mjs`.
  Best-effort (the harness classifier may background anyway) but attacks the
  root cause of the input-clash the hold option mitigates.
- **Shared `common.mjs`:** the WATCHDOG_TMP / `cfg()` / `log()` boilerplate is
  now duplicated across three hook scripts (`session-analysis.mjs`,
  `persist-analysis.mjs`, `hold-input.mjs`). Fold into the unhack.md refactor.
- **`done`-state grace window (v2 race fix):** a prompt landing between
  SubagentStop clearing the `pending-` sentinel and the main agent finishing the
  analysis presentation is not held. If this proves annoying, have
  persist-analysis rewrite the sentinel to a `done` state that `hold-input.mjs`
  honors for ~20s instead of deleting it outright.

---

## LOW PRIORITY

### 6. Move cleanup logic to `SessionEnd` hook

**Problem:** Stale-file cleanup (old session files, cursor pruning, analysis
retention) runs inside the Stop hook script. This work doesn't need to block
Claude and adds latency to the analysis trigger path.

**Fix:** Add a `SessionEnd` hook for cleanup tasks. `SessionEnd` fires after the
session terminates and cannot block — ideal for housekeeping.

---

### 7. Surface analysis token cost

**Problem:** Each analysis consumes ~38-39.5k tokens (~$0.02-0.05 at Sonnet
pricing). Over a workday with multiple sessions this adds up, but users have no
visibility.

**Fix:** Include token count in the analysis footer, or document expected cost
per-analysis in the README.

---

### 8. Explore new plugin features

Features from the latest docs that the plugin doesn't yet leverage:

- **`bin/` directory:** Ship a `claude-watchdog` CLI helper for listing/viewing
  past analyses (e.g. `claude-watchdog list`, `claude-watchdog last`).
- **`output-styles/`:** Define a compact analysis output style.
- **`settings.json` at plugin root:** Set default `subagentStatusLine` config
  for the analyzer agent.
- **Monitors:** Background processes that deliver stdout as notifications. Could
  watch the analyses directory for new files.

---

## INFORMATIONAL

### 9. Post-mortem cannot prevent mistakes in real time

The session-analyzer correctly caught issues like "pushed changes without
showing the user first" — but only after the fact. This is a fundamental
architectural limitation of post-mortem analysis.

**Partial progress:** The README headline uses "critical post-mortem" which
conveys retrospective intent.

**Remaining:** Explicitly document in the README that the watchdog analyzes but
does not guard in real time, and point users toward `PreToolUse` hooks for
pre-action gates.
