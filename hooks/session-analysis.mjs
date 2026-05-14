#!/usr/bin/env node
import {
  readFileSync, writeFileSync, appendFileSync, mkdirSync, readdirSync,
  statSync, unlinkSync, rmdirSync, existsSync, chmodSync
} from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { slice, lastUuid } from './cursor-slice.mjs';

function cfg(watchdogVar, pluginVar, defaultVal) {
  return process.env[watchdogVar] ?? process.env[pluginVar] ?? defaultVal;
}

const LOG_FILE = process.env.CLAUDE_WATCHDOG_LOG ?? join(homedir(), '.claude/logs/claude-watchdog.log');
const MAX_LINES = parseInt(process.env.CLAUDE_WATCHDOG_LOG_MAX_LINES ?? '1000', 10);
const MIN_TOOL_USES = parseInt(cfg('CLAUDE_WATCHDOG_MIN_TOOL_USES', 'CLAUDE_PLUGIN_OPTION_MIN_TOOL_USES', '8'), 10);
const CONDENSED_MAX_BYTES = parseInt(cfg('CLAUDE_WATCHDOG_MAX_BYTES', 'CLAUDE_PLUGIN_OPTION_MAX_TRANSCRIPT_BYTES', '51200'), 10);
const WATCHDOG_TMP = process.env.CLAUDE_WATCHDOG_TMP ?? process.env.CLAUDE_PLUGIN_DATA ?? join(homedir(), '.claude/tmp/claude-watchdog');
const GLOBAL_SESSIONS_DIR = join(WATCHDOG_TMP, 'sessions');
const ANALYSES_DIR = process.env.CLAUDE_WATCHDOG_ANALYSES_DIR ?? join(homedir(), '.claude/logs/claude-watchdog-analyses');
const CURSOR_TTL_DAYS = parseInt(process.env.CLAUDE_WATCHDOG_CURSOR_TTL_DAYS ?? '7', 10);
const COOLDOWN_SECONDS = parseInt(cfg('CLAUDE_WATCHDOG_COOLDOWN_SECONDS', 'CLAUDE_PLUGIN_OPTION_COOLDOWN_SECONDS', '600'), 10);
const LOCAL_STORAGE = cfg('CLAUDE_WATCHDOG_LOCAL_SESSION_STORAGE', 'CLAUDE_PLUGIN_OPTION_LOCAL_SESSION_STORAGE', '1');

function log(msg) {
  const ts = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
  appendFileSync(LOG_FILE, `[${ts}] ${msg}\n`);
}

function rotateLog() {
  try {
    const content = readFileSync(LOG_FILE, 'utf8');
    const lines = content.split('\n');
    if (lines.length > MAX_LINES) {
      const kept = lines.slice(-MAX_LINES).join('\n');
      writeFileSync(LOG_FILE, kept.endsWith('\n') ? kept : kept + '\n');
      log(`LOG ROTATED (was ${lines.length} lines)`);
    }
  } catch { /* file may not exist yet */ }
}

function cleanupSessionsDir(dir) {
  try {
    const entries = readdirSync(dir, { withFileTypes: true });
    const now = Date.now();
    const twoHoursMs = 120 * 60 * 1000;
    const cursorTtlMs = CURSOR_TTL_DAYS * 24 * 60 * 60 * 1000;
    for (const entry of entries) {
      const full = join(dir, entry.name);
      try {
        if (entry.isFile()) {
          const age = now - statSync(full).mtimeMs;
          if (/^(condensed|raw|delta)-/.test(entry.name) && age > twoHoursMs) {
            unlinkSync(full);
          } else if (/^cursor-/.test(entry.name) && age > cursorTtlMs) {
            unlinkSync(full);
          }
        } else if (entry.isDirectory()) {
          if (now - statSync(full).mtimeMs > twoHoursMs) {
            try { rmdirSync(full); } catch { /* non-empty or in use */ }
          }
        }
      } catch { /* skip individual failures */ }
    }
  } catch { /* dir may not exist */ }
}

function capAnalyses() {
  try {
    const files = readdirSync(ANALYSES_DIR)
      .filter(f => f.endsWith('.md'))
      .map(f => ({ name: f, mtime: statSync(join(ANALYSES_DIR, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime);
    for (const f of files.slice(20)) {
      try { unlinkSync(join(ANALYSES_DIR, f.name)); } catch { /* ignore */ }
    }
  } catch { /* dir may not exist or be empty */ }
}

function truncateStrings(val, max) {
  if (typeof val === 'string') return val.length > max ? val.slice(0, max) + '...[truncated]' : val;
  if (Array.isArray(val)) return val.map(v => truncateStrings(v, max));
  if (val && typeof val === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(val)) out[k] = truncateStrings(v, max);
    return out;
  }
  return val;
}

function extractTranscript(lines) {
  const output = [];
  for (const line of lines) {
    if (!line || line[0] !== '{') continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }

    if (obj.type === 'user') {
      const content = obj.message?.content;
      if (typeof content === 'string') {
        output.push(`USER: ${content}`);
      } else if (Array.isArray(content)) {
        for (const block of content) {
          if (block.type === 'text') {
            output.push(`USER: ${block.text}`);
          } else if (block.type === 'tool_result') {
            let text;
            if (typeof block.content === 'string') {
              text = block.content.slice(0, 500);
            } else if (Array.isArray(block.content)) {
              text = block.content
                .filter(c => c.type === 'text')
                .map(c => c.text)
                .join('\n')
                .slice(0, 500);
            } else {
              text = '(no content)';
            }
            output.push(`TOOL_RESULT: ${text}${block.is_error === true ? ' [ERROR]' : ''}`);
          }
        }
      }
    } else if (obj.type === 'assistant') {
      const blocks = obj.message?.content;
      if (Array.isArray(blocks)) {
        for (const block of blocks) {
          if (block.type === 'text') {
            output.push(`ASSISTANT: ${block.text}`);
          } else if (block.type === 'thinking') {
            output.push(`THINKING: ${(block.thinking || '').slice(0, 300)}`);
          } else if (block.type === 'tool_use') {
            output.push(`TOOL_USE: ${block.name}(${JSON.stringify(block.input).slice(0, 500)})`);
          }
        }
      }
    } else {
      output.push(`SYSTEM[${obj.type || 'unknown'}]: ${JSON.stringify(obj).slice(0, 200)}`);
    }
  }
  return output.join('\n');
}

function countToolUses(lines) {
  let count = 0;
  for (const line of lines) {
    if (!line || line[0] !== '{') continue;
    try {
      const obj = JSON.parse(line);
      if (obj.type === 'assistant' && Array.isArray(obj.message?.content)) {
        for (const block of obj.message.content) {
          if (block.type === 'tool_use') count++;
        }
      }
    } catch { /* skip malformed lines */ }
  }
  return count;
}

let markerDir = null;
let deltaFile = null;

process.on('exit', () => {
  if (markerDir) try { rmdirSync(markerDir); } catch { /* already removed or in use */ }
  if (deltaFile) try { unlinkSync(deltaFile); } catch { /* already removed */ }
});

try {
  mkdirSync(dirname(LOG_FILE), { recursive: true });
  mkdirSync(WATCHDOG_TMP, { recursive: true });
  chmodSync(WATCHDOG_TMP, 0o700);
  mkdirSync(GLOBAL_SESSIONS_DIR, { recursive: true });
  chmodSync(GLOBAL_SESSIONS_DIR, 0o700);
  mkdirSync(ANALYSES_DIR, { recursive: true });

  cleanupSessionsDir(GLOBAL_SESSIONS_DIR);
  capAnalyses();

  const disabled = cfg('CLAUDE_WATCHDOG_DISABLED', 'CLAUDE_PLUGIN_OPTION_DISABLED', '0');
  if (disabled === '1' || disabled === 'true') {
    log('SKIP: disabled via configuration');
    process.exit(0);
  }

  const input = readFileSync(0).slice(0, 65536).toString('utf8');
  const event = JSON.parse(input);

  const sessionId = event.session_id;
  const transcriptPath = event.transcript_path;
  const hookCwd = event.cwd;
  const stopReason = event.stop_reason ?? 'end_turn';

  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) {
    log('SKIP: invalid session_id format');
    process.exit(0);
  }

  if (event.agent_id) {
    log(`SKIP: running inside subagent/teammate (agent_id=${event.agent_id}, agent_type=${event.agent_type ?? 'unknown'})`);
    process.exit(0);
  }

  let eventSummary;
  try { eventSummary = JSON.stringify(truncateStrings(event, 200)); } catch { eventSummary = input.slice(0, 500); }

  log(`--- session=${sessionId} stop_reason=${stopReason} ---`);
  log(`event: ${eventSummary}`);
  rotateLog();

  if (stopReason !== 'end_turn') {
    log(`SKIP: stop_reason is '${stopReason}', not 'end_turn'`);
    process.exit(0);
  }

  if (hookCwd && existsSync(join(hookCwd, '.claude-watchdog-skip'))) {
    log(`SKIP: disabled via .claude-watchdog-skip in ${hookCwd}`);
    process.exit(0);
  }

  let SESSIONS_DIR = GLOBAL_SESSIONS_DIR;
  if (LOCAL_STORAGE === '1' || LOCAL_STORAGE === 'true') {
    if (hookCwd && hookCwd !== 'null' && existsSync(hookCwd)) {
      const localDir = join(hookCwd, '.claude/tmp/claude-watchdog/sessions');
      try {
        mkdirSync(localDir, { recursive: true });
        chmodSync(localDir, 0o700);
        cleanupSessionsDir(localDir);
        SESSIONS_DIR = localDir;
        log(`LOCAL_STORAGE: using project-local path ${SESSIONS_DIR}`);
      } catch {
        log('LOCAL_STORAGE: cannot create local dir, falling back to global');
      }
    } else {
      log('LOCAL_STORAGE: hook_cwd empty or invalid, falling back to global');
    }
  }

  const MARKER = join(SESSIONS_DIR, sessionId);
  const CURSOR_FILE = join(SESSIONS_DIR, `cursor-${sessionId}.txt`);
  const DELTA_FILE = join(SESSIONS_DIR, `delta-${sessionId}.tmp`);

  try {
    mkdirSync(MARKER);
  } catch (err) {
    if (err.code === 'EEXIST') {
      log(`SKIP: concurrent run already in progress for ${sessionId}`);
      process.exit(0);
    }
    throw err;
  }
  markerDir = MARKER;
  deltaFile = DELTA_FILE;

  if (!transcriptPath || !existsSync(transcriptPath)) {
    log(`SKIP: transcript not found at '${transcriptPath}'`);
    process.exit(0);
  }

  let cursorUuid = '';
  let cursorLinenum = 0;
  let deltaStart = 1;

  if (existsSync(CURSOR_FILE)) {
    const cursorLines = readFileSync(CURSOR_FILE, 'utf8').split('\n');
    const rawUuid = cursorLines[0] || '';
    const rawLinenum = cursorLines[1] || '';
    const cursorTranscript = cursorLines[2] || '';

    if (/^[A-Za-z0-9_-]+$/.test(rawUuid)) {
      cursorUuid = rawUuid;
    } else {
      log('CURSOR: malformed uuid, ignoring cursor');
    }

    if (/^[0-9]+$/.test(rawLinenum)) {
      cursorLinenum = parseInt(rawLinenum, 10);
    }

    if (cursorTranscript && !existsSync(cursorTranscript)) {
      log('CURSOR: stale transcript path, ignoring cursor');
      cursorUuid = '';
      cursorLinenum = 0;
    }
  }

  if (COOLDOWN_SECONDS > 0 && existsSync(CURSOR_FILE)) {
    const age = (Date.now() - statSync(CURSOR_FILE).mtimeMs) / 1000;
    if (age < COOLDOWN_SECONDS) {
      log(`SKIP: cooldown active (${Math.floor(age)}s < ${COOLDOWN_SECONDS}s since last trigger)`);
      process.exit(0);
    }
  }

  if (cursorUuid) {
    const result = slice(transcriptPath, cursorUuid, String(cursorLinenum));
    deltaStart = result.deltaStart;
    log(`CURSOR: uuid=${cursorUuid} hint=${cursorLinenum} -> delta starts at line ${deltaStart}`);
  }

  const allLines = readFileSync(transcriptPath, 'utf8').split('\n');
  const deltaLines = allLines.slice(deltaStart - 1);
  writeFileSync(DELTA_FILE, deltaLines.join('\n'));

  const toolUseCount = countToolUses(deltaLines);
  log(`tool_use count (delta): ${toolUseCount}`);
  if (toolUseCount < MIN_TOOL_USES) {
    log(`SKIP: delta too small (${toolUseCount} < ${MIN_TOOL_USES}), cursor unchanged`);
    process.exit(0);
  }

  process.umask(0o077);

  const RAW_FILE = join(SESSIONS_DIR, `raw-${sessionId}.txt`);
  const CONDENSED_FILE = join(SESSIONS_DIR, `condensed-${sessionId}.txt`);

  const rawContent = extractTranscript(deltaLines);
  const rawSize = Buffer.byteLength(rawContent, 'utf8');
  const verbose = cfg('CLAUDE_WATCHDOG_VERBOSE', 'CLAUDE_PLUGIN_OPTION_VERBOSE', '0');
  const isVerbose = verbose === '1' || verbose === 'true';

  let condensedContent;
  if (rawSize <= CONDENSED_MAX_BYTES) {
    condensedContent = rawContent;
  } else {
    const rawLines = rawContent.split('\n');
    const userLines = rawLines.filter(l => l.startsWith('USER: '));
    const otherLines = rawLines.filter(l => !l.startsWith('USER: '));

    const USER_BUDGET = Math.floor(CONDENSED_MAX_BYTES / 5);
    const OTHER_BUDGET = Math.floor(CONDENSED_MAX_BYTES * 4 / 5);
    const droppedKb = Math.floor((rawSize - CONDENSED_MAX_BYTES) / 1024);

    const userBuf = Buffer.from(userLines.join('\n'), 'utf8');
    const otherBuf = Buffer.from(otherLines.join('\n'), 'utf8');

    const userPart = userBuf.slice(0, USER_BUDGET).toString('utf8');
    const otherPart = otherBuf.slice(-OTHER_BUDGET).toString('utf8');

    const parts = [];
    if (isVerbose) {
      parts.push(`[TRUNCATED] Original transcript was ${rawSize} bytes (~${droppedKb}KB dropped). Early context may be incomplete.`);
      parts.push('');
    }
    parts.push(userPart);
    parts.push('');
    parts.push('--- [above: user messages; below: recent tool calls and responses] ---');
    parts.push('');
    parts.push(otherPart);
    condensedContent = parts.join('\n');
  }

  if (isVerbose) {
    const userMsgCount = condensedContent.split('\n').filter(l => l.startsWith('USER: ')).length;
    const condensedSize = Buffer.byteLength(condensedContent, 'utf8');
    condensedContent = `[DIAGNOSTICS] raw=${rawSize}B condensed=${condensedSize}B tool_uses=${toolUseCount} user_messages=${userMsgCount} delta_start=${deltaStart}\n\n${condensedContent}`;
  }

  if (!condensedContent || condensedContent.trim().length === 0) {
    log('SKIP: condensed transcript is empty');
    process.exit(0);
  }

  writeFileSync(CONDENSED_FILE, condensedContent);
  const condensedSize = Buffer.byteLength(condensedContent, 'utf8');
  log(`condensed file: ${CONDENSED_FILE} (${condensedSize} bytes)`);

  log('TRIGGER: injecting session-analyzer subagent request (exit 2)');

  const safeCwd = (hookCwd || '').replace(/\n/g, '');
  const safeCondensed = CONDENSED_FILE.replace(/\n/g, '');

  process.stderr.write(`Please spawn a session-analyzer agent to critically analyze this session.

Use the Agent tool with:
- subagent_type: "session-analyzer"
- model: "sonnet"
- prompt: "Read and analyze the condensed session transcript at '${safeCondensed}'. The working directory is '${safeCwd}'. Provide your critical analysis."

Present the analysis to the user, then stop.
`);

  const cursorResult = lastUuid(DELTA_FILE);
  if (cursorResult) {
    if (/^[A-Za-z0-9_-]+$/.test(cursorResult.uuid)) {
      const absLine = (deltaStart - 1) + cursorResult.relLine;
      writeFileSync(CURSOR_FILE, `${cursorResult.uuid}\n${absLine}\n${transcriptPath}\n`);
      log(`CURSOR: updated to uuid=${cursorResult.uuid} line=${absLine}`);
    } else {
      log('CURSOR: invalid last-uuid output, cursor unchanged');
    }
  }

  process.exit(2);
} catch (err) {
  try { log(`ERROR: unexpected failure: ${err.message}`); } catch { /* logging itself failed */ }
  process.exit(0);
}
