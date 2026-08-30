# The condense debug CLI

Note for the contract station (design/contract.md, section 5 of
design/rewrite-readiness.md). Written while extracting the suite into `tests/`.

`hooks/condense.mjs` has a small command-line entry point that the tests drive
directly. Section 1 of the rewrite-readiness doc asked for a decision on it:
drop it as an internal API, or promote it to a documented interface. **Decision:
keep it, as a supported interface**, because it is the only way a human can see
what the analyzer was actually shown when an analysis comes back wrong.

## Interface

    <binary> condense <transcript.jsonl> [maxBytes]
    <binary> extract  <transcript.jsonl>

- `condense` writes the budgeted condensed transcript to stdout, followed by a
  newline. `maxBytes` defaults to `51200`.
- `extract` writes the unbudgeted extraction to stdout, followed by a newline.
  This is the input `condense` applies its byte budget to.
- Exit 0 on success, 2 on an unknown subcommand (usage on stderr), 1 on any
  other error (`condense error: <message>` on stderr).

The tests reach it through `$HOOK_CONDENSE` (see `tests/lib.sh`), which defaults
to `node hooks/condense.mjs`. A port satisfies the suite by providing the two
subcommands above under whatever binary `HOOK_CONDENSE` names.

## What the contract needs to say

Copy the interface above into `design/contract.md`, and pin there:

1. Whether `extract` is part of the supported surface or only `condense`. The
   suite currently depends on both - `tests/condense.sh` uses `extract` to
   assert the pre-budget grammar and to prove the flood fixture busts the
   budget.
2. The trailing newline on both subcommands (goldens in section 2 will encode
   it either way, so state it deliberately).
3. The `51200` default, which is the same number as the `CLAUDE_WATCHDOG_MAX_BYTES`
   default - say whether the CLI is meant to track that config or stay fixed.
