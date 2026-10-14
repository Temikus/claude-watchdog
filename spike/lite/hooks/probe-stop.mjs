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
  stopHookActive: event.stop_hook_active === true,
}) + '\n');

// Step 1 probe: a context entry the module should see, and may strip.
if (event.stop_hook_active !== true) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'Stop', additionalContext: 'PROBE: reply with the word probed.' },
  }));
}
