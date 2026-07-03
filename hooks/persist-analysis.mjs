#!/usr/bin/env node
import {
  readFileSync, writeFileSync, appendFileSync, mkdirSync, readdirSync,
  statSync, unlinkSync
} from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const LOG_FILE = process.env.CLAUDE_WATCHDOG_LOG ?? join(homedir(), '.claude/logs/claude-watchdog.log');
const ANALYSES_DIR = process.env.CLAUDE_WATCHDOG_ANALYSES_DIR ?? join(homedir(), '.claude/logs/claude-watchdog-analyses');
const WATCHDOG_TMP = process.env.CLAUDE_WATCHDOG_TMP ?? process.env.CLAUDE_PLUGIN_DATA ?? join(homedir(), '.claude/tmp/claude-watchdog');
const GLOBAL_SESSIONS_DIR = join(WATCHDOG_TMP, 'sessions');

mkdirSync(dirname(LOG_FILE), { recursive: true });
mkdirSync(ANALYSES_DIR, { recursive: true });

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  appendFileSync(LOG_FILE, `[${ts}] [persist] ${msg}\n`);
}

try {
  const input = readFileSync(0).slice(0, 131072).toString('utf8');
  const event = JSON.parse(input);

  const agentType = event.agent_type ?? '';
  const sessionId = event.session_id ?? '';
  const message = event.last_assistant_message ?? '';

  if (agentType !== 'session-analyzer') process.exit(0);

  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
    log('SKIP: invalid session_id');
    process.exit(0);
  }

  // The analyzer finishing releases the input hold, whether or not it produced a
  // persistable message — so this must precede the empty-message early-exit.
  try { unlinkSync(join(GLOBAL_SESSIONS_DIR, `pending-${sessionId}`)); } catch { /* not held or already gone */ }

  if (!message) {
    log(`SKIP: empty last_assistant_message for session=${sessionId}`);
    process.exit(0);
  }

  const ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  const outputFile = join(ANALYSES_DIR, `${sessionId}-${ts}.md`);
  writeFileSync(outputFile, message + '\n');

  const size = Buffer.byteLength(message + '\n', 'utf8');
  log(`WROTE: ${outputFile} (${size} bytes)`);

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
