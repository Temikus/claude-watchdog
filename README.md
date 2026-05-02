# claude-watchdog

> A Claude Code plugin that runs a **critical post-mortem** on every Claude session, automatically.

When Claude finishes a turn, claude-watchdog spawns a `session-analyzer` subagent that cross-checks **what you asked for** against **what actually changed in the repo** (via `git diff`) and delivers a blunt, structured review:

- **Goals** — were they achieved? what was missed?
- **Efficiency** — any wasted detours or repeated failures?
- **Quality** — anything sloppy, hallucinated, or cargo-culted?
- **Compliance** — did Claude dodge pushback or ignore instructions?
- **Recommendations** — 1–3 concrete follow-ups.

The analysis happens **in-session**, using your existing Claude Code credentials — no external API calls, no extra API keys, no telemetry.

## Why

Long coding sessions drift. Claude will sometimes claim a task is done when it isn't, silently drop requirements, or agree too easily. claude-watchdog gives you a second pair of eyes on every session without you having to remember to ask.

## Real examples this plugin caught

> _**the go vet failures I dismissed as "pre-existing" are not pre-existing** —
  openrouter_test.go:263 references FundsRemaining, which was deleted in the same working tree diff. Those are broken tests from the cost_limit migration, not noise._

> _Context7 **docs lookup was never completed**. I said "Let me confirm exact CLI syntax from Jamf docs" but the
  resolve-library-id call only returned Jamf Protect (**wrong product**), and I proceeded without retrying or using WebFetch. This
  violates the global context7.md rule._

> _The claims that reason= is mandatory and that the URL scheme exists **were stated confidently but not doc-verified** — treat them as hypotheses until you test._

> _**Integration test still unexecuted. snapshotReader.test.ts has never actually run** — better-sqlite3 is absent from node_modules._

> _Live/snapshot path inconsistency. health.ts:401 still slices the overview to team.repos.slice(0, 3) on the live (non-snapshot) path. Now that snapshots return all repos, the two paths diverge — **users who bypass  the cache with ?fresh=1 see a smaller dataset than the snapshot they just replaced**. Either align the live path to return all repos, or document why the slice exists (likely: live scoring is expensive; 3 repos keeps the cold-path responsive)._

> _Goals: Neither achieved — **no branch was created, no code changed**._

## Install

In Claude Code:

```
/plugin marketplace add Temikus/claude-plugins
/plugin install claude-watchdog@temikus
```

That adds my personal plugin marketplace (which also hosts any future plugins) and installs `claude-watchdog` from it.

### Verify it's working

Run a short session and end Claude's turn. You should see output like:

```
[bash session-analysis.sh]: Please spawn a session-analyzer agent...
```

…followed by the analysis. If nothing appears, check `~/.claude/logs/claude-watchdog.log` — every hook invocation is logged with the reason it ran or skipped.

## What's inside

| Component | Path | Purpose |
| --- | --- | --- |
| Stop hook | `hooks/session-analysis.sh` | Preprocesses the transcript, triggers the analyzer |
| SubagentStop hook | `hooks/persist-analysis.sh` | Persists the analyzer's output to disk (no UI noise) |
| Subagent | `agents/session-analyzer.md` | Reads the transcript + `git diff`, writes the review |
| Slash command | `skills/analyze-session/SKILL.md` | `/analyze-session` for on-demand analysis mid-conversation |

## Requirements

- **Claude Code** ≥ 1.0 (plugin support)
- **`jq`** on your `PATH` — install with `brew install jq` / `apt install jq`. The hook exits cleanly if `jq` is missing.
- **Bash 3.2+** (macOS default works fine)
- **git** in the working directory you want analyzed (the agent runs `git diff` to compare intent vs. reality — sessions in non-git dirs still get a transcript-only review)

## When does the hook actually fire?

Only when **all** of these are true — otherwise it exits silently and Claude stops normally:

- `CLAUDE_WATCHDOG_DISABLED` is not set to `1`
- No `.claude-watchdog-skip` file exists in the project root
- `stop_reason == "end_turn"` (skips compaction, tool_use pauses, max_tokens cutoffs)
- Session has not already been analyzed (marker in the plugin's data directory, auto-expires after 2 hours)
- Transcript exists and has ≥ `CLAUDE_WATCHDOG_MIN_TOOL_USES` tool calls in the unanalyzed delta (default 8)
- At least `CLAUDE_WATCHDOG_COOLDOWN_SECONDS` have elapsed since the last analysis for this session (default 600)
- Condensed transcript is non-empty after jq filtering
- `jq` is installed

Every decision is logged to `~/.claude/logs/claude-watchdog.log`.

## Configuration

Set these environment variables in your shell profile or `~/.claude/settings.json` `env` block:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_WATCHDOG_DISABLED` | `0` | Set to `1` to disable the hook globally |
| `CLAUDE_WATCHDOG_LOG` | `~/.claude/logs/claude-watchdog.log` | Debug log path |
| `CLAUDE_WATCHDOG_LOG_MAX_LINES` | `1000` | Log rotation threshold (lines) |
| `CLAUDE_WATCHDOG_MIN_TOOL_USES` | `8` | Skip turns whose delta has fewer tool calls than this (prevents review-storms on short back-and-forth edits) |
| `CLAUDE_WATCHDOG_COOLDOWN_SECONDS` | `600` | Minimum seconds between analyses for the same session. Set to `0` to disable |
| `CLAUDE_WATCHDOG_MAX_BYTES` | `51200` | Condensed transcript size cap (weighted: 20% user messages, 80% recent context) |
| `CLAUDE_WATCHDOG_TMP` | `${CLAUDE_PLUGIN_DATA}` when running as an installed plugin, otherwise `~/.claude/tmp/claude-watchdog` | Plugin-owned data root. Per-session files live in a `sessions/` subdirectory underneath |
| `CLAUDE_WATCHDOG_ANALYSES_DIR` | `~/.claude/logs/claude-watchdog-analyses` | Directory for persisted analysis results (capped at 20) |

You can also create a `.claude-watchdog-skip` file in any project root to disable the hook for that project:

```bash
touch .claude-watchdog-skip  # add to .gitignore if needed
```

## On-demand analysis

Don't want to wait for Claude to stop? Run `/analyze-session` any time during a conversation and Claude will analyze the session-so-far using the same criteria.

## How it works

1. Claude Code fires the `Stop` hook when a turn ends.
2. `session-analysis.sh` receives the event JSON (session id, transcript path, cwd, stop reason) on stdin.
3. It filters the JSONL transcript with `jq` down to user text, assistant text, tool calls, and tool results, keeps the last ~50 KB, and writes it to `${CLAUDE_PLUGIN_DATA}/sessions/condensed-<session-id>.txt` (owner-only permissions; falls back to `~/.claude/tmp/claude-watchdog/sessions/` when not running as an installed plugin). Files older than 2 hours are cleaned up automatically.
4. It exits with code `2` and a stderr message instructing Claude to spawn the `session-analyzer` subagent pointed at that file.
5. The subagent reads the condensed transcript, runs `git diff` / `git log` in the working directory, and produces the structured review — all inside your current Claude Code session, using the model you're already authenticated with.
6. When the subagent finishes, Claude Code fires the `SubagentStop` hook. `persist-analysis.sh` reads the subagent's final message from the event payload and writes it to `~/.claude/logs/claude-watchdog-analyses/` — so the subagent itself doesn't have to call `Write`, keeping the UI clean.

No data leaves your machine except through Claude Code's normal model calls.

Analysis results are saved to `~/.claude/logs/claude-watchdog-analyses/` (capped at 20 most recent sessions) so you can review past post-mortems.

## Uninstall

```
/plugin uninstall claude-watchdog
/plugin marketplace remove Temikus/claude-plugins
```

`/plugin uninstall` clears `${CLAUDE_PLUGIN_DATA}` automatically. Optionally delete the log, analyses, and any pre-plugin-era temp files:

```bash
rm -f ~/.claude/logs/claude-watchdog.log
rm -rf ~/.claude/logs/claude-watchdog-analyses
rm -rf ~/.claude/tmp/claude-watchdog  # only exists on pre-0.4 installs or custom CLAUDE_WATCHDOG_TMP
```

## Development

```bash
just lint    # validate JSON manifests and bash syntax
just test    # run smoke tests
just check   # lint + all tests
```

See `justfile` for the full list.

## License

MIT.
