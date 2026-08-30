# Golden files

Byte-exact outputs captured from the Node implementation. `tests/golden.sh`
regenerates them and compares against them with `diff -u`; `just test-golden`
runs the comparison and `just golden-regen` rewrites every file.

The rest of the suite asserts with `grep -q` on substrings, which lets a port
change whitespace, ordering, truncation boundaries, or prompt wording and still
pass. These files close that hole: every byte outside a `<PLACEHOLDER>` is
contract.

## Updating them

**An intentional behaviour change updates the goldens in the same PR as the
change.** Run `just golden-regen`, read the diff (it is the review artefact -
it says exactly what a consumer will see change), and commit both together. A
golden diff arriving without a matching code change means something drifted.

## Normalisation

Values that differ per machine or per run are rewritten to placeholders by
`golden_normalise` in `tests/golden.sh`. That function is the *only* place
normalisation happens, and both the generator and the comparator pipe through
it, so an unstable value cannot reach a golden from one side only.

| Placeholder | Replaces |
| --- | --- |
| `<TMP>` | the per-run `mktemp -d` root, in both its symlinked and real form |
| `<SESSION>` | the session id |
| `<TIMESTAMP>` | ISO 8601 instants, with or without milliseconds |
| `<N>` | the elapsed-seconds figure in the cooldown line |
| `<HOST>` | the short hostname |

`HOME` is redirected into the temp root for every Stop-hook case, so the
runner's own `~/.claude/CLAUDE.md` and `~/.claude/rules` cannot leak into
`stop.prompt.txt`.

Determinism is verified by regenerating twice and diffing; byte sizes and
counts in `stop.diagnostics.txt` are deliberately *not* normalised, since they
are exactly what a port has to reproduce.

## The files

### Condensation

| File | What it pins |
| --- | --- |
| `midturn.extract.txt` | `extract` output for `tests/fixtures/midturn-session.jsonl` - the full label grammar and per-tool truncation caps |
| `midturn.condense-8192.txt` | pass-through: 5032 bytes fits in 8192, so no notice and no splits |
| `midturn.condense-4096.txt` | full truncation path, multi-line head and tail |
| `midturn.condense-2048.txt` | same branches at a tighter budget, single-line head |

Budget choice, checked against `hooks/condense.mjs` for this fixture (extract
output 5032 bytes, of which 902 bytes are `USER` lines):

- **8192** cannot truncate - `condense()` returns `rawContent` unchanged when
  `rawSize <= maxBytes`. Section 2 of `design/rewrite-readiness.md` asked for
  4096 and 8192 as the two truncation goldens; 8192 does not reach that path on
  this fixture, so it is kept as the pass-through case and **2048** is the
  second truncation golden.
- **4096**: `userPart` budget is `floor(4096/5) = 819 < 902`, so
  `clampUserLines` elides. `room = 819 - 37 - 1 = 781`, head budget
  `floor(781*0.4) = 312` (3 `USER` lines), tail takes the remainder (6 lines).
  `otherPart` takes the last `floor(4096*4/5) = 3276` bytes of non-`USER` lines.
- **2048**: `userPart` 409, `room` 371, head `floor(371*0.4) = 148` - one
  `USER` line - so the 40/60 asymmetry is visible rather than incidental.

Between them the two truncation goldens cover both user-thread ends, the
`--- [earlier user messages elided] ---` marker, the unconditional
`[TRUNCATED]` notice, the 20/80 user/other budget split, and the 40/60
head/tail split.

`tests/golden.sh` also asserts every label in `tests/labels.txt` appears in at
least one `midturn.*` golden - the other half of the check in
`tests/agent-prompt.sh`, which asserts each label is documented in
`agents/session-analyzer.md`.

### Stop hook

| File | What it pins |
| --- | --- |
| `stop.prompt.txt` | the `reason` string emitted on `decision:block` - subagent type, model, the analyzer prompt, the touched-file list, the instruction-file list, and the post-analysis block. This wording is what the model acts on, so it is contract, not cosmetics. |
| `stop.diagnostics.txt` | the verbose `[DIAGNOSTICS]` header with its byte sizes and counts (`CLAUDE_WATCHDOG_VERBOSE=1`) |

### Skip decisions

The README promises every decision is logged and users grep the log, so the
`SKIP:` lines are a de facto API. One golden per path, named
`stop.log.<reason>.txt`:

| File | Gate |
| --- | --- |
| `stop.log.disabled.txt` | `CLAUDE_WATCHDOG_DISABLED` |
| `stop.log.invalid-session-id.txt` | `session_id` fails `^[a-zA-Z0-9_-]+$` |
| `stop.log.subagent.txt` | event carries `agent_id` |
| `stop.log.stop-reason.txt` | `stop_reason != end_turn` |
| `stop.log.echo.txt` | `stop_hook_active` plus our own echo sentinel |
| `stop.log.background-tasks.txt` | non-empty `background_tasks` |
| `stop.log.session-cron.txt` | a `session_crons` entry already runs the analyzer |
| `stop.log.skip-file.txt` | `.claude-watchdog-skip` in the hook cwd |
| `stop.log.concurrent.txt` | marker directory already held |
| `stop.log.no-transcript.txt` | `transcript_path` missing or nonexistent |
| `stop.log.cooldown.txt` | cursor file younger than the cooldown |
| `stop.log.delta-too-small.txt` | tool uses below `MIN_TOOL_USES` |
| `stop.log.read-only.txt` | no edits and no mutating shell in the delta |
| `stop.log.no-user-messages.txt` | no top-level user messages in the delta |

**Not covered:** `SKIP: condensed transcript is empty`. It sits behind the
user-message gate, and every entry that satisfies `isUserMessage()` also
produces a `USER` line in `extractTranscript()`, so the condensed text cannot be
empty by the time that check runs. It is unreachable in the current
implementation. A port that reorders those gates would make it reachable, which
is itself a behaviour change worth catching.
