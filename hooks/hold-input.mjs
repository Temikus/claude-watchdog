#!/usr/bin/env node
// UserPromptSubmit hook: while a session analysis is in flight (pending-<sid>
// sentinel written by session-analysis.mjs), block newly submitted prompts so
// they don't interleave with the pending analysis. The blocked prompt is erased
// by Claude Code but recoverable via up-arrow history. Escape hatches, since no
// hook fires on Ctrl-C/Esc cancellation: a TTL, and resubmit-to-override (the
// first block marks the sentinel "nudged"; the next prompt releases the hold).
// Runs on every prompt submission, so: opt-out exits before reading stdin, the
// prompt text is never read or logged, and every path fails open (exit 0).
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, unlinkSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[watchdogVar] ?? process.env[pluginVar] ?? defaultVal;
}

const LOG_FILE = process.env.CLAUDE_WATCHDOG_LOG ?? join(homedir(), '.claude/logs/claude-watchdog.log');
const WATCHDOG_TMP = process.env.CLAUDE_WATCHDOG_TMP ?? process.env.CLAUDE_PLUGIN_DATA ?? join(homedir(), '.claude/tmp/claude-watchdog');
const GLOBAL_SESSIONS_DIR = join(WATCHDOG_TMP, 'sessions');
const HOLD_INPUT = cfg('CLAUDE_WATCHDOG_HOLD_INPUT', 'CLAUDE_PLUGIN_OPTION_HOLD_INPUT_DURING_ANALYSIS', '0');
const HOLD_TTL_SECONDS = parseInt(process.env.CLAUDE_WATCHDOG_HOLD_TTL_SECONDS ?? '240', 10);

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  appendFileSync(LOG_FILE, `[${ts}] [hold] ${msg}\n`);
}

try {
  if (HOLD_INPUT !== '1' && HOLD_INPUT !== 'true') process.exit(0);

  mkdirSync(dirname(LOG_FILE), { recursive: true });

  const input = readFileSync(0).slice(0, 65536).toString('utf8');
  const event = JSON.parse(input);

  const sessionId = event.session_id ?? '';
  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) process.exit(0);

  const PENDING_FILE = join(GLOBAL_SESSIONS_DIR, `pending-${sessionId}`);
  if (!existsSync(PENDING_FILE)) process.exit(0);

  const lines = readFileSync(PENDING_FILE, 'utf8').split('\n');
  // TTL is anchored to the trigger timestamp on line 1, not mtime — the "nudged"
  // rewrite below would otherwise silently extend an mtime-based TTL.
  let startedMs = Date.parse(lines[0]);
  if (Number.isNaN(startedMs)) startedMs = statSync(PENDING_FILE).mtimeMs;
  const ageSec = (Date.now() - startedMs) / 1000;

  if (HOLD_TTL_SECONDS <= 0 || ageSec > HOLD_TTL_SECONDS) {
    try { unlinkSync(PENDING_FILE); } catch { /* already gone */ }
    log(`RELEASE: hold expired for session=${sessionId} (${Math.floor(ageSec)}s > ${HOLD_TTL_SECONDS}s)`);
    process.exit(0);
  }

  if (lines[1] === 'nudged') {
    try { unlinkSync(PENDING_FILE); } catch { /* already gone */ }
    log(`RELEASE: user override for session=${sessionId}`);
    process.exit(0);
  }

  try { writeFileSync(PENDING_FILE, `${lines[0]}\nnudged\n`); } catch { /* still block this once; TTL remains the backstop */ }
  const remaining = Math.max(0, Math.ceil(HOLD_TTL_SECONDS - ageSec));
  const reason = `claude-watchdog: a session analysis is still in flight, so your prompt was held to keep it from interleaving with the analysis (press up-arrow to restore it). Resubmit to override and continue anyway, or wait for the analysis — the hold auto-expires in ~${remaining}s.`;
  log(`HOLD: blocked prompt for session=${sessionId} (age=${Math.floor(ageSec)}s)`);
  process.stdout.write(JSON.stringify({ decision: 'block', reason }));
  process.exit(0);
} catch (err) {
  try { log(`ERROR: unexpected failure: ${err.message}`); } catch { /* logging itself failed */ }
  process.exit(0);
}
