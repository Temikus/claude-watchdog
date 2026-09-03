#!/usr/bin/env node
// PreToolUse hook: refuse a Task/Agent dispatch that omits `model` when the
// agent definition pins one. Exit 2 + stderr is the PreToolUse block protocol;
// any other exit allows the call.
//
// Runs on every Task/Agent dispatch, so: the opt-in check exits before reading
// stdin, and every path other than the deliberate block fails open (exit 0).
import { readFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { dumpEvent } from './dump-events.mjs';

process.umask(0o077);

function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[watchdogVar] ?? process.env[pluginVar] ?? defaultVal;
}

const LOG_FILE = process.env.CLAUDE_WATCHDOG_LOG ?? join(homedir(), '.claude/logs/claude-watchdog.log');
const ENFORCE = cfg('CLAUDE_WATCHDOG_ENFORCE_SUBAGENT_MODEL', 'CLAUDE_PLUGIN_OPTION_ENFORCE_SUBAGENT_MODEL', '0');

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  appendFileSync(LOG_FILE, `[${ts}] [model] ${msg}\n`);
}

// First `model:` in the leading `---` frontmatter block, quotes stripped.
function pinnedModel(text) {
  const lines = text.split('\n').map(l => l.replace(/\r$/, ''));
  if (lines[0] !== '---') return '';
  for (const line of lines.slice(1)) {
    if (line === '---') return '';
    const m = /^model:[ \t]+(\S+)/.exec(line);
    if (m) return m[1].replace(/["']/g, '');
  }
  return '';
}

// Project agents shadow personal ones; a bare `<t>.md` shadows `<t>/<t>.md`.
function readAgentFile(subagentType) {
  const dirs = [
    join(process.env.CLAUDE_PROJECT_DIR ?? '.', '.claude/agents'),
    join(homedir(), '.claude/agents'),
  ];
  for (const dir of dirs) {
    for (const file of [join(dir, `${subagentType}.md`), join(dir, subagentType, `${subagentType}.md`)]) {
      try {
        return readFileSync(file, 'utf8');
      } catch { /* not here, keep looking */ }
    }
  }
  return null;
}

try {
  if (ENFORCE !== '1' && ENFORCE !== 'true') process.exit(0);

  mkdirSync(dirname(LOG_FILE), { recursive: true });

  const input = readFileSync(0).slice(0, 65536).toString('utf8');
  dumpEvent('pre-tool-use', input);
  const event = JSON.parse(input);

  const toolName = event.tool_name ?? '';
  if (toolName !== 'Task' && toolName !== 'Agent') process.exit(0);

  const subagentType = event.tool_input?.subagent_type ?? '';
  const model = event.tool_input?.model ?? '';
  if (!subagentType || model) process.exit(0);

  // subagent_type is unsanitised tool input and is spliced into a path below.
  if (subagentType.includes('/') || subagentType.startsWith('.')) process.exit(0);

  const agentText = readAgentFile(subagentType);
  if (agentText === null) process.exit(0);

  const pinned = pinnedModel(agentText);
  if (!pinned || pinned.toLowerCase() === 'inherit') process.exit(0);

  log(`BLOCK: '${subagentType}' pinned to ${pinned}, dispatch had no explicit model`);
  process.stderr.write(`BLOCKED: '${subagentType}' is pinned (model: ${pinned}) but this dispatch has no explicit 'model'. Re-dispatch with model: "${pinned}". A deliberate different model also passes, but it must be explicit.\n`);
  process.exit(2);
} catch (err) {
  try { log(`ERROR: unexpected failure: ${err.message}`); } catch { /* logging itself failed */ }
  process.exit(0);
}
