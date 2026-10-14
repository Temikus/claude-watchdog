// Coexistence probe: proves a command hook still runs beside the module.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const log = process.env.CLAUDE_WATCHDOG_LITE_LOG
  ?? join(homedir(), '.claude', 'logs', 'claude-watchdog-lite.jsonl');

let event = {};
try {
  event = JSON.parse(await new Promise((resolve) => {
    let buf = '';
    process.stdin.on('data', (c) => { buf += c; });
    process.stdin.on('end', () => resolve(buf));
  }));
} catch {}

mkdirSync(dirname(log), { recursive: true });
appendFileSync(log, JSON.stringify({
  ts: new Date().toISOString(),
  kind: 'command-stop',
  sessionId: event.session_id ?? null,
}) + '\n');
