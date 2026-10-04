#!/usr/bin/env node
import {
  readFileSync, writeFileSync, appendFileSync, mkdirSync, readdirSync,
  statSync, unlinkSync, chmodSync, renameSync
} from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { dumpEvent } from './dump-events.mjs';

const LOG_FILE = process.env.CLAUDE_WATCHDOG_LOG ?? join(homedir(), '.claude/logs/claude-watchdog.log');
const ANALYSES_DIR = process.env.CLAUDE_WATCHDOG_ANALYSES_DIR ?? join(homedir(), '.claude/logs/claude-watchdog-analyses');
const WATCHDOG_TMP = process.env.CLAUDE_WATCHDOG_TMP ?? process.env.CLAUDE_PLUGIN_DATA ?? join(homedir(), '.claude/tmp/claude-watchdog');
const GLOBAL_SESSIONS_DIR = join(WATCHDOG_TMP, 'sessions');

// The persisted analysis is the most sensitive artefact the plugin writes - it
// quotes the session back. Owner-only regardless of the caller's umask.
process.umask(0o077);

mkdirSync(dirname(LOG_FILE), { recursive: true });
mkdirSync(ANALYSES_DIR, { recursive: true });
try { chmodSync(ANALYSES_DIR, 0o700); } catch { /* pre-existing dir we do not own */ }

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  appendFileSync(LOG_FILE, `[${ts}] [persist] ${msg}\n`);
}

// Claude Code delivers a subagent's report through a SubagentHandback tool call.
// When that call is the agent's last turn, last_assistant_message is empty, so
// the report is read from the agent transcript. `draft` is the last
// '### Goals' text turn before it, which an earlier stop may already have saved.
function readHandback(path) {
  let message = '';
  let draft = '';
  if (!path) return { message, draft };
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    let content;
    try { content = JSON.parse(line).message?.content; } catch { continue; }
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (c.type === 'text' && c.text?.startsWith('### Goals')) draft = c.text;
      if (c.type === 'tool_use' && c.name === 'SubagentHandback' && typeof c.input?.message === 'string') {
        message = c.input.message;
      }
    }
  }
  return { message, draft };
}

try {
  const input = readFileSync(0).slice(0, 131072).toString('utf8');
  dumpEvent('subagent-stop', input);
  const event = JSON.parse(input);

  const agentType = event.agent_type ?? '';
  const sessionId = event.session_id ?? '';
  let message = event.last_assistant_message ?? '';

  // Plugin-scoped dispatches report agent_type as "<plugin>:session-analyzer".
  if (!/(^|:)session-analyzer$/.test(agentType)) {
    log(`SKIP: agent_type '${agentType}' does not match session-analyzer`);
    process.exit(0);
  }

  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
    log('SKIP: invalid session_id');
    process.exit(0);
  }

  // The analyzer finishing releases the input hold, whether or not it produced a
  // persistable message — so this must precede the empty-message early-exit.
  try { unlinkSync(join(GLOBAL_SESSIONS_DIR, `pending-${sessionId}`)); } catch { /* not held or already gone */ }

  let draft = '';
  if (!message) {
    try {
      ({ message, draft } = readHandback(event.agent_transcript_path));
    } catch (err) {
      log(`SKIP: unreadable agent transcript for session=${sessionId}: ${err.message}`);
    }
  }

  if (!message) {
    log(`SKIP: empty last_assistant_message for session=${sessionId}`);
    process.exit(0);
  }

  // The analyzer can stop twice: once with the report, once with a short ack after
  // handing it back. Both carry agent_type, so the ack used to be persisted as
  // its own file and, being newer, became what the next slice read back.
  if (!message.startsWith('### Goals')) {
    log(`SKIP: message is not an analysis (no '### Goals' header) for session=${sessionId}`);
    process.exit(0);
  }

  // A text turn saved by an earlier stop is replaced in place, so the caller's
  // version wins without leaving a second file for the same run. A file that
  // already holds the handback is reused, so a repeated stop adds nothing.
  const sessionFiles = readdirSync(ANALYSES_DIR)
    .filter(f => f.startsWith(`${sessionId}-`) && /^\d{8}T\d{6}Z\.md$/.test(f.slice(sessionId.length + 1)))
    .map(f => join(ANALYSES_DIR, f));
  const holds = text => f => { try { return readFileSync(f, 'utf8') === text + '\n'; } catch { return false; } };
  const draftFile = draft && sessionFiles.find(holds(draft));
  const existingFile = draftFile || sessionFiles.find(holds(message));
  const ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  const outputFile = existingFile || join(ANALYSES_DIR, `${sessionId}-${ts}.md`);
  // Rename is atomic, so an interrupted write never truncates a saved draft.
  const tmp = `${outputFile}.${process.pid}.tmp`;
  try {
    writeFileSync(tmp, message + '\n');
    renameSync(tmp, outputFile);
  } finally {
    try { unlinkSync(tmp); } catch { /* renamed */ }
  }

  const size = Buffer.byteLength(message + '\n', 'utf8');
  log(`${existingFile ? 'REPLACED' : 'WROTE'}: ${outputFile} (${size} bytes)`);
  console.log(`Analysis saved to: ${outputFile}`);

  const files = readdirSync(ANALYSES_DIR)
    .filter(f => f.endsWith('.md'))
    .map(f => ({ name: f, mtime: statSync(join(ANALYSES_DIR, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  for (const f of files.slice(20)) {
    try { unlinkSync(join(ANALYSES_DIR, f.name)); } catch { /* ignore */ }
  }
} catch (err) {
  try { log(`ERROR: unexpected failure: ${err.message}`); } catch { /* logging itself failed */ }
  process.exit(0);
}
