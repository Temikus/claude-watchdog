# Spike: mod-based light mode

Drafted 2026-10-14 against Claude Code 2.1.296. Status: steps 0-3 done.
Light mode ships as the opt-in `light_mode` option (`hooks/light-mode.tsx`,
README "Light mode"); the `spike/lite/` prototype is removed. Step 4, the
side-by-side run with `light_mode: both`, is next.

The design changed after step 1b (below): the Stop hook hands each review to
the module through `light-<session>.json` in a shared directory, and the
module marks itself alive each turn. See `design/contract.md` sections 6.2,
7.2 and 8.

## Question

Can a function-hooks module ("mod") run the watchdog check as a tool-less fork
of the main conversation and show the result above the prompt? The spike must
show whether that beats the current Stop hook + `session-analyzer` subagent on
cost, quality and friction, or at least matches it.

The spike is throwaway. It ends in a go/no-go note with numbers, not in a
shipped feature.

## Why it might be better

| | Today (Stop hook + subagent) | Light mode (mod + fork) |
| --- | --- | --- |
| Context | Condensed transcript, 50 KB cap, tool results cut at 80-800 chars | The main thread's full request, served from the prompt cache |
| Instruction files | Paths passed, analyzer reads them | Already in the main context |
| Main thread | Blocked at Stop, analysis lands in its context | Never blocked, nothing added to its context |
| When | Post-mortem only | Post-mortem, plus optional heads-ups during a turn |
| Tools | Read, Bash, Grep, Glob (can `git show`) | None (diff must be put in the prompt) |
| Model | Sonnet | The session's model (often Opus), mostly at cache-read price |

The truncation row is a real failure, not a theory. In the 2026-10-14 session
the analyzer reported a claim as unverified because the condensed transcript
had cut the grep output that verified it.

## What is already verified

From `plugin-authoring/types/claude-code.d.ts` in 2.1.296 and a probe plugin:

- `$.model.fork({ prompt })` runs one tool-less completion over the main
  thread's last request, with the prefix served from cache. It returns
  `isAnswered`, `text` and `usage`, or a `reason`: `nothing-to-fork`,
  `api-error`, `empty-reply` or `aborted` (d.ts around lines 2626 and 6349).
- `turn.step` is a streaming event. Its input has `turnId`, `index`, `model`,
  `messageCount`, and `agentId` (absent on the main thread). Its result has
  `toolUses` and `usage` (d.ts around line 13438).
- `classic.Stop` and the other settings-hook events can be hooked from a
  module, with `transcript_path` and `cwd` in `e`.
- `$.process.spawn` / `$.process.run` take `argv` and `cwd`, so the module can
  run `git diff` itself.
- `ui.render` on `AbovePrompt` draws a band; `$.store` persists across
  sessions; `$.state` holds per-session values.
- One `hooks/hooks.json` with both `"modules"` and command `"hooks"` passes
  `claude plugin validate`. Runtime coexistence is not yet tested.
- The built-in you-should-know plugin uses this exact stack: a fork every 6
  main-thread steps, a band, `seen`/`known` lists, and backoff when offers are
  ignored.
- The mod API is "early access and moves between releases"
  (`reference.md`). Plan for churn.

## Unknowns the spike must answer

1. **Coexistence.** Does the command `Stop` hook still fire when the same
   plugin loads a module? On a Claude Code build without mod support, is the
   `"modules"` key ignored, or does it break the whole `hooks.json`?
2. **Cost.** What `cache_read` / `cache_creation` / `output` does a fork
   report on a real session? Compare dollars with the subagent's ~38k Sonnet
   tokens (backlog item 7). A cold cache on a 150k-token Opus transcript is
   the worst case.
3. **Quality without tools.** With the diff in the prompt but no `git show`,
   does the fork find the same true positives? Does it make fewer
   truncation-driven false positives, or more unchecked claims?
4. **Interference.** Does a fork started from `turn.step` slow the main turn?
   How often is it `aborted` by an interrupt?
5. **Compaction.** After auto-compact the fork sees only the summary. How much
   worse is that than the condenser, which reads the raw JSONL?
6. **Gating.** you-should-know is limited to "first-party sessions with
   telemetry on". Does `$.model.fork` work with telemetry off, and on
   Bedrock/Vertex (the d.ts warns the cache only hits when the prompt opens the
   same way)?
7. **Test kit.** Can a `claude plugin test` file answer `model.fork` and
   `process.run` with canned results, so CI does not call a model?

## Prototype design

Build it as a mod under `--plugin-dir` (hot reload), not in `hooks/`.

### Triggers

- **A. Post-mortem (main experiment).** Hook `turn.complete` on the main
  thread (no `agentId`). Apply the same gates as `session-analysis.mjs`
  (`design/contract.md`): disabled, skip file, cooldown, minimum tool calls,
  at least one mutating call, no background tasks. Count tool calls from
  `turn.step` results' `toolUses` in the module, not by parsing the
  transcript. The cache is warm here, since the last step has just run.
- **B. Mid-turn heads-up (second experiment).** Every 8th main-thread step,
  only when the window since the last check holds a mutating call. Drop the
  answer if `turnId` changed before it came back.

Never `await` the fork inside the `turn.step` generator: it would spend the
hook's budget. Start it, keep one in-flight check per session, and
`yield* next(e)`.

### Prompt

- Port the rules from `agents/session-analyzer.md`: signal threshold,
  three-sentence findings, `### Goals` first, `none` as the expected outcome.
- Remove the tool workflow. Replace it with the module's own evidence block:
  `git diff --stat`, then hunks for files touched this slice, capped at 20 KB.
- Add "skip these" lists: the last 20 recommendation titles (`seen`) and the
  ones the user marked not useful (`known`).
- Add the rule: drop a finding the user already raised or acknowledged in the
  conversation.
- Require a parseable first line: `verdict: clean` or `verdict: findings`.

### Display

- Clean: a toast, `✓ Watchdog: nothing to report`, or nothing (try both).
- Findings: an `AbovePrompt` band with the Goals line and up to 3 titles.
  Keys: `1` sends the findings to Claude (`$.prompt.fill`, the user presses
  Enter), `2` marks them not useful (adds to `known`), `0` dismisses.
- Persist the full text to `CLAUDE_WATCHDOG_ANALYSES_DIR`, as
  `persist-analysis.mjs` does today.

### Measurement

For every check, log one JSON line: trigger, step index, latency, `usage`
fields, outcome (`clean`, `findings`, `none-parsed`, `aborted`,
`nothing-to-fork`, `api-error`), and the user's key press.

## Steps

Time box: 2 days. Stop early if step 0 or step 1 fails a hard limit.

0. **Probe (2 h).** Load the scratch plugin with both hook kinds and confirm
   the command `Stop` hook still runs (unknown 1). Install it on the oldest
   Claude Code we support and see what happens. Write one kit test that
   answers `model.fork` (unknown 7).
1. **Cost probe (2 h).** A `turn.complete` hook that forks a fixed one-line
   prompt and logs `usage`. Run 3 real sessions of different lengths
   (unknowns 2 and 6).
2. **Evidence and prompt (3 h).** `git diff` through `$.process.run`, the
   ported prompt, the `verdict:` parser, `seen`/`known`.
3. **Band (3 h).** `AbovePrompt` band, the three keys, persistence.
4. **Side-by-side run (1 day, in parallel with normal work).** Keep the
   current watchdog on and add the mod. Collect about 10 sessions where both
   ran. Grade each finding by hand: true positive, false positive, missed
   (unknowns 3 and 5).
5. **Mid-turn trial (2 h).** Turn on trigger B for a few sessions and log
   abort rate and any slowdown (unknown 4).
6. **Write-up.** Replace this file's Status with the go/no-go and the numbers.

## Go / no-go

Go only if all hold:

- Median cost per check is at or below the subagent's, in dollars.
- True positives at least match the subagent. False positives are fewer.
- Median latency is under 30 s, with no visible slowdown of the main turn.
- Coexistence works, or a separate plugin is acceptable (decision D1).

## Risks

- **API churn.** Pin a minimum Claude Code version and feature-detect.
  Keep the command-hook path as the fallback.
- **Cold-cache cost.** A fork after the cache entry has lapsed pays a full
  cache write on the main model. Trigger A runs right after a step, so the
  cache should be warm; measure it rather than assume.
- **No tools, no check-it-or-drop-it.** The fork cannot run `git show` to
  confirm a finding. The prompt must forbid findings without evidence in the
  conversation or the diff block.
- **"Fix recommendations" no longer runs on its own.** Key `1` makes it an
  explicit opt-in. It is a behaviour change for users who turned that on.
- **CI.** The kit needs the `claude` binary in CI. The bash suite stays for
  the command hooks.

## Decisions needed before step 2

- **D1.** Ship light mode as a mode of `claude-watchdog`, or as a separate
  `claude-watchdog-lite` plugin in the same marketplace? Separate is safer
  if unknown 1 shows older builds reject `"modules"`.
- **D2.** Trigger A only, or A and B?
- **D3.** Support only first-party API sessions, or also Bedrock/Vertex?

## Results

### Step 0 - probe (2026-10-14)

- **Coexistence on 2.1.296: works.** In a `claude -p --plugin-dir spike/lite`
  run, the command `Stop` hook and the module's `turn.complete` hook both
  wrote their log lines.
- **Older builds: degrade cleanly.** On 2.1.29, `plugin validate` passes, the
  `"modules"` key is ignored, and the command `Stop` hook still runs. A mode
  inside `claude-watchdog` would not break older installs (D1). Note that
  2.1.29 cannot load the full `claude-watchdog` at all, before or after this
  work: it rejects `userConfig` and `$schema` as unknown manifest keys. For
  the same reason the module avoids `$.state`, which needs a `"types"`
  manifest key.
- **Test kit: works.** `claude plugin test` answers `model.fork`, `fs.*`,
  `env.get` and `session.id` from test hooks. A noun call's hook must answer
  `{ value }`, an event's hook its result. 4 tests in
  `spike/lite/hooks/register.test.ts`.
- **New blocker for any rename or new plugin:** 2.1.296's
  `claude plugin validate` rejects names that start with `claude-` as
  reserved. That includes `claude-watchdog` itself. The installed plugin still
  loads, so this is a validator rule today, not a load failure. The spike
  plugin is named `watchdog-lite` for that reason.

### Step 1 - cost probe (2026-10-14, Haiku main model)

Fork of a fixed one-line prompt, started from `turn.complete`, not awaited:

| Session | Turn cache read / write | Fork cache read / write | Fork latency |
| --- | --- | --- | --- |
| 1 step, no tools | 0 / 40,481 | 17,337 / 23,147 | 1.5 s |
| 4 steps, 3 `Read`s | 49,862 / 89,388 | 101,042 / 326 | 1.8 s |

- After a turn with tool steps, the fork reads almost the whole transcript
  from cache. Sessions that pass the minimum-tool-calls gate look like the
  second row.
- A one-step turn hits only part of the cache. Those turns are under the
  gate anyway.
- `claude -p` exits after the turn, yet the un-awaited fork still finished
  and logged.
Same 4-step session on the other main models:

| Main model | Fork cache read / write | Fork latency | Fork cost (probe) |
| --- | --- | --- | --- |
| Haiku 5.5 | 101,042 / 326 | 1.8 s | ~$0.001 |
| Sonnet 5.5 | 100,172 / 618 | 1.5 s | ~$0.022 |
| Opus 5.5 | 99,813 / 685 | 2.7 s | ~$0.023 |

Prices are from the bundled `claude-api` skill (cached 2026-10-06): cache
reads $0.20/MTok on Opus 5.5 and Sonnet 5.5, 5-minute writes 1.25x input.

- **Estimate for a real check on Opus 5.5 at ~100k tokens:** the probe cost
  plus ~8k fresh tokens of rules and diff (~$0.03) and ~1-3k output tokens,
  thinking included (~$0.02-0.06). Total ~$0.07-0.12. The cache-read part
  grows linearly with the transcript: ~$0.08 at 400k.
- **The current path at the same size:** the subagent's ~38k Sonnet tokens
  (~$0.05-0.10), plus 2-3 extra main-thread requests to read the brief, spawn
  the agent and repeat the analysis. On Opus that is ~$0.02 of cache reads
  each. Total ~$0.10-0.17.
- These are estimates. Step 4 replaces them with measured numbers from the
  real prompt.
- Unknown 6 (telemetry off, Bedrock/Vertex) is not tested. D3 makes
  Bedrock/Vertex out of scope for now.

### Step 1b - can a module see the command Stop hook's output? (2026-10-14)

No, not on this machine. The debug log says
`watchdog-lite: classic.Stop bypassed by cc-plugin-sec-default (tier user)`.
The built-in `cc-plugin-sec-default` is seated outermost "on a machine with
managed settings and for Team and Enterprise organizations". It keeps
`classic.*`, `prompt.section/context/compose`, `tool.*`, `agent.*`,
`settings.read` and `plugin.register` out of reach of user-installed modules.
`turn.*`, `session.*`, `ui.render`, `model.*`, `prompt.submit`, `$.fs`,
`$.process` and `$.store` still reach the module. So a design that rewrites
the Stop hook's output from a module does not work for managed or Enterprise
users.

## Decisions (2026-10-14)

- **D1:** ship inside `claude-watchdog`, as an opt-in config option.
- **D2:** trigger A only (after each turn).
- **D3:** first-party API only for now.

## Out of scope

Removing the condenser, the subagent path, or any current option.
