# Capturing fixtures

The hook event payloads and the transcript JSONL are undocumented external
formats that move between Claude Code releases. Everything under
`tests/fixtures/events/` is currently **reconstructed** from `hooks/hooks.json`,
the hook source, and the `jq -n` literals the suite used before. Reconstruction
is a guess. This file is how you replace a guess with a capture.

## 1. Capture raw hook events

`CLAUDE_WATCHDOG_DUMP_EVENTS=<dir>` makes each hook write the exact bytes it
read on stdin to `<dir>/<hook>-<timestamp>-<pid>-<rand>.json`. It is strictly
opt-in, does not change hook behaviour, and fails open if the directory cannot
be written.

Set it for a real Claude Code session. Either export it before launching:

```bash
mkdir -p ~/watchdog-capture
CLAUDE_WATCHDOG_DUMP_EVENTS=~/watchdog-capture claude
```

or put it in the plugin config so it survives restarts (settings JSON):

```json
{ "env": { "CLAUDE_WATCHDOG_DUMP_EVENTS": "/Users/you/watchdog-capture" } }
```

Then drive the situations you want on record:

| Fixture | How to provoke it |
| --- | --- |
| `stop-plain` | Any ordinary turn that ends. |
| `stop-echo` | Let the watchdog analyse a turn, then stop again immediately - the second Stop carries `stop_hook_active: true` and the analyzer's own message in `last_assistant_message`. |
| `stop-bg-tasks` | Start a background Bash task or a subagent, then stop while it is still running. Needs Claude Code >= 2.1.145 for `background_tasks`. |
| `subagent-stop` | Any turn that runs a `Task`. |
| `prompt-submit` | Submit any prompt with `CLAUDE_WATCHDOG_HOLD_INPUT=1` (the hold hook exits before reading stdin when the feature is off, so nothing is dumped otherwise). |

Unset the variable when you are done. It writes one file per hook invocation and
never rotates.

## 2. Sanitise

Never commit a raw capture. It contains your home directory, username,
hostname, session UUIDs, and whatever was on screen.

```bash
just fixture-sanitise ~/watchdog-capture/stop-20260830T101112.123Z-4242-a1b2c3.json
```

The script rewrites the file in place and strips: API keys and tokens
(Anthropic, OpenAI-style, GitHub, Slack, AWS, Google, JWTs, `Authorization:`
headers, PEM blocks), email addresses, UUIDs (pseudonymised consistently within
one file, so a `session_id` still matches the one inside `transcript_path`), the
repo root, `$HOME`, other users' home directories, temp directories, your
username, and your hostname. Repo paths outside this repo collapse to
`/repo/<basename>`. Output is validated as JSON (or JSONL, per line) and the
original is restored if the result would not parse.

It is idempotent, so running it twice is safe. **Read the diff before
committing** - it is a regex pass, not a proof.

## 3. Commit

Event fixtures carry a `_fixture` provenance block. `event_fixture` in
`tests/lib.sh` strips every `_`-prefixed key before the payload reaches a hook,
so the block never affects behaviour.

```json
{
  "_fixture": {
    "status": "captured",
    "source": "Claude Code 2.1.x, macOS, ordinary end_turn",
    "note": "Captured via CLAUDE_WATCHDOG_DUMP_EVENTS and sanitised with just fixture-sanitise.",
    "claude_code_version": "2.1.x"
  },
  ...
}
```

Flip `status` from `reconstructed` to `captured` and fill in the real version.
`tests/fixtures.sh` asserts the block exists and is one of those two values.

Transcript fixtures (`tests/fixtures/*.jsonl`) are captured the same way, except
the source is the transcript file itself - `transcript_path` in any Stop event
points at it. Trim it to the interesting entries, then sanitise.

## Known lossiness worth remembering

A `tool_result` whose `content` is an array of non-text blocks (an image from
`Read`, for instance) condenses to an **empty** body: `TOOL_RESULT[Read]: ` with
nothing after it. `(no content)` appears only when `content` is neither a string
nor an array (e.g. `null`). Both are pinned in `tests/fixtures.sh`. Either way
the analyzer cannot tell an image came back at all.
