#!/usr/bin/env node
// Transcript extraction and byte-budget condensation for the Stop hook. Split out
// of session-analysis.mjs so the fixture tests can exercise it directly
// (`just test-condense`).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const TOOL_RESULT_MAX = 500;
// File-browsing output is bulk the analyzer never needs; shell output and errors
// carry the failure detail it does.
const TOOL_RESULT_MAX_BROWSE = 80;
const TOOL_RESULT_MAX_VERBOSE = 800;
const BROWSE_TOOLS = new Set(['Read', 'Glob', 'Grep', 'LS']);
const TOOL_INPUT_MAX = 500;
const THINKING_MAX = 300;
const SYSTEM_MAX = 200;

// Bookkeeping entries whose payload is either duplicated by a real message entry
// (last-prompt, queue enqueue/dequeue) or is UI-only (titles, PR links, mode
// pings). Dumped as raw JSON they crowded out real content in the byte budget.
// Unknown types are NOT dropped - they still fall through to a SYSTEM[...] line,
// so a future type carrying user text degrades to noisy rather than invisible.
const NOISE_TYPES = new Set(['last-prompt', 'custom-title', 'ai-title', 'pr-link', 'mode']);

// Harness plumbing attachments - no session content worth spending budget on.
const NOISE_ATTACHMENTS = new Set([
  'task_reminder',
  'deferred_tools_delta',
  'agent_listing_delta',
  'mcp_instructions_delta',
  'skill_listing',
]);

// Some builds hand a mid-turn message to the model wrapped in framing text rather
// than as a queued_command attachment. Strip the framing so the message reads as
// the user's own words, and treat its presence as a mid-turn signal.
const MIDTURN_FRAMING = /^\s*\[?\s*The user sent (?:a |an |another )?new message while you were working:?\s*\]?\s*/i;

// Protected in the truncation path: every USER line, including the parenthesised
// variants (mid-turn, edited file).
export const USER_LINE = /^USER(?: \([^)]*\))?: /;
export const MIDTURN_LINE = /^USER \(mid-turn/;

const MIDTURN_LABEL = 'USER (mid-turn)';
const ELISION = '--- [earlier user messages elided] ---';

function parseLines(lines) {
  const out = [];
  for (const line of lines) {
    if (!line || line[0] !== '{') continue;
    try { out.push(JSON.parse(line)); } catch { /* skip malformed lines */ }
  }
  return out;
}

function queuedPrompt(att) {
  const raw = typeof att?.prompt === 'string' ? att.prompt
    : typeof att?.content === 'string' ? att.content
      : '';
  return raw.trim();
}

// A queued prompt can be injected by something other than the person at the
// keyboard (a cron, a hook). Keep it visible but don't let it pass as a human ask.
function midTurnLabel(origin) {
  return origin && origin !== 'human' ? `USER (mid-turn, origin=${origin})` : MIDTURN_LABEL;
}

function toolResultMax(name, isError) {
  if (isError || name === 'Bash') return TOOL_RESULT_MAX_VERBOSE;
  if (BROWSE_TOOLS.has(name)) return TOOL_RESULT_MAX_BROWSE;
  return TOOL_RESULT_MAX;
}

function toolResultText(block, name) {
  const max = toolResultMax(name, block.is_error === true);
  if (typeof block.content === 'string') return block.content.slice(0, max);
  if (Array.isArray(block.content)) {
    return block.content
      .filter(c => c.type === 'text')
      .map(c => c.text)
      .join('\n')
      .slice(0, max);
  }
  return '(no content)';
}

export function extractTranscript(lines) {
  const entries = parseLines(lines);
  const output = [];

  // Mid-turn input reaches the transcript as an attachment (attachment.type
  // 'queued_command', text in attachment.prompt). A `queue-operation` with
  // operation 'remove' carries the same text a line earlier - the same event seen
  // from the queue's side. Collect the attachment prompts first so the
  // queue-operation path below is only a fallback for builds that don't log the
  // attachment, rather than a source of duplicates.
  const attachmentPrompts = new Set();
  const toolNames = new Map(); // tool_use.id -> name, for per-tool result caps
  for (const obj of entries) {
    if (obj.type === 'assistant' && Array.isArray(obj.message?.content)) {
      for (const b of obj.message.content) {
        if (b.type === 'tool_use' && b.id) toolNames.set(b.id, b.name);
      }
    }
    if (obj.type === 'attachment' && obj.attachment?.type === 'queued_command') {
      const prompt = queuedPrompt(obj.attachment);
      if (prompt) attachmentPrompts.add(prompt);
    }
  }

  for (const obj of entries) {
    if (obj.type === 'user') {
      const content = obj.message?.content;
      if (typeof content === 'string') {
        const framed = MIDTURN_FRAMING.test(content);
        output.push(`${framed ? MIDTURN_LABEL : 'USER'}: ${content.replace(MIDTURN_FRAMING, '')}`);
      } else if (Array.isArray(content)) {
        // Text sharing an entry with tool_result blocks was typed while the turn
        // was still running - it is not the prompt that started the turn.
        const midTurn = content.some(b => b.type === 'tool_result');
        for (const block of content) {
          if (block.type === 'text') {
            const text = block.text || '';
            const label = (midTurn || MIDTURN_FRAMING.test(text)) ? MIDTURN_LABEL : 'USER';
            output.push(`${label}: ${text.replace(MIDTURN_FRAMING, '')}`);
          } else if (block.type === 'tool_result') {
            const name = toolNames.get(block.tool_use_id);
            // [ERROR] goes in the label, not after a body that can run 800 chars:
            // the reader must see the failure before the content it did not produce.
            const label = `${name ? `TOOL_RESULT[${name}]` : 'TOOL_RESULT'}${block.is_error === true ? '[ERROR]' : ''}`;
            output.push(`${label}: ${toolResultText(block, name)}`);
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
            output.push(`THINKING: ${(block.thinking || '').slice(0, THINKING_MAX)}`);
          } else if (block.type === 'tool_use') {
            output.push(`TOOL_USE: ${block.name}(${JSON.stringify(block.input).slice(0, TOOL_INPUT_MAX)})`);
          }
        }
      }
    } else if (obj.type === 'attachment') {
      const att = obj.attachment || {};
      if (att.type === 'queued_command') {
        const prompt = queuedPrompt(att);
        if (prompt) output.push(`${midTurnLabel(att.origin?.kind)}: ${prompt}`);
      } else if (att.type === 'edited_text_file') {
        // The user edited a file by hand mid-session. The snippet is large and
        // the diff shows the content anyway; the filename is the signal.
        output.push(`USER (edited file): ${att.filename || '(unknown)'}`);
      } else if (att.type === 'hook_blocking_error') {
        const err = att.blockingError?.blockingError ?? att.blockingError ?? '';
        output.push(`SYSTEM[hook-blocked ${att.hookName || att.hookEvent || 'hook'}]: ${String(err).slice(0, SYSTEM_MAX)}`);
      } else if (att.type === 'plan_mode' || att.type === 'plan_mode_exit') {
        output.push(`SYSTEM[${att.type}]`);
      } else if (!NOISE_ATTACHMENTS.has(att.type)) {
        output.push(`SYSTEM[attachment:${att.type || 'unknown'}]: ${JSON.stringify(att).slice(0, SYSTEM_MAX)}`);
      }
    } else if (obj.type === 'queue-operation') {
      // 'remove' means the queued prompt was pulled out and injected into the
      // running turn; 'dequeue' means it became the next turn's own user message
      // (already captured as a user entry above). Fall back to this record only
      // when the authoritative queued_command attachment is absent from the slice.
      const content = (obj.content || '').trim();
      if (obj.operation === 'remove' && content && !attachmentPrompts.has(content)) {
        output.push(`${MIDTURN_LABEL}: ${content}`);
      }
    } else if (!NOISE_TYPES.has(obj.type)) {
      output.push(`SYSTEM[${obj.type || 'unknown'}]: ${JSON.stringify(obj).slice(0, SYSTEM_MAX)}`);
    }
  }

  return output.join('\n');
}

// Accumulate whole lines from one end until the byte budget is spent. Line-wise
// rather than Buffer.slice so a cut can't land mid-line or split a UTF-8 char.
function takeLines(lines, budget, from) {
  const seq = from === 'tail' ? [...lines].reverse() : lines;
  const picked = [];
  let used = 0;
  for (const line of seq) {
    const cost = Buffer.byteLength(line, 'utf8') + 1;
    if (used + cost > budget) break;
    picked.push(line);
    used += cost;
  }
  return { lines: from === 'tail' ? picked.reverse() : picked, used };
}

// Keep both ends of the user thread. The head carries the session goal, the tail
// carries the most recent asks - which is where mid-turn corrections land. Taking
// only the head (the previous behaviour) silently dropped late user input on long
// sessions.
function clampUserLines(userLines, budget) {
  const size = Buffer.byteLength(userLines.join('\n'), 'utf8');
  if (size <= budget) return userLines;

  const room = Math.max(0, budget - Buffer.byteLength(ELISION, 'utf8') - 1);
  const head = takeLines(userLines, Math.floor(room * 0.4), 'head');
  const tail = takeLines(userLines.slice(head.lines.length), room - head.used, 'tail');
  return [...head.lines, ELISION, ...tail.lines];
}

export function condense(rawContent, maxBytes) {
  const rawSize = Buffer.byteLength(rawContent, 'utf8');
  if (rawSize <= maxBytes) return { content: rawContent, rawSize, truncated: false, droppedKb: 0 };

  const rawLines = rawContent.split('\n');
  const userLines = rawLines.filter(l => USER_LINE.test(l));
  const otherLines = rawLines.filter(l => !USER_LINE.test(l));

  const userPart = clampUserLines(userLines, Math.floor(maxBytes / 5)).join('\n');
  const otherPart = takeLines(otherLines, Math.floor(maxBytes * 4 / 5), 'tail').lines.join('\n');

  const droppedKb = Math.floor((rawSize - maxBytes) / 1024);

  // The notice is unconditional, not verbose-only: without it a truncated file
  // reads to the analyzer as a session that ended early, and it cannot tell that a
  // missing instruction was elided rather than never given.
  const content = [
    `[TRUNCATED] Original transcript was ${rawSize} bytes (~${droppedKb}KB dropped). Early context may be incomplete.`,
    '',
    userPart,
    '',
    '--- [above: user messages in order, mid-turn ones labelled; below: recent tool calls and responses] ---',
    '',
    otherPart,
  ].join('\n');

  return { content, rawSize, truncated: true, droppedKb };
}

export function counts(content) {
  const lines = content.split('\n');
  return {
    user: lines.filter(l => USER_LINE.test(l)).length,
    midTurn: lines.filter(l => MIDTURN_LINE.test(l)).length,
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [, , cmd, ...args] = process.argv;
  try {
    if (cmd === 'extract') {
      process.stdout.write(extractTranscript(readFileSync(args[0], 'utf8').split('\n')) + '\n');
      process.exit(0);
    } else if (cmd === 'condense') {
      const raw = extractTranscript(readFileSync(args[0], 'utf8').split('\n'));
      process.stdout.write(condense(raw, parseInt(args[1] ?? '51200', 10)).content + '\n');
      process.exit(0);
    } else {
      process.stderr.write('usage: condense.mjs extract <transcript.jsonl> | condense <transcript.jsonl> [maxBytes]\n');
      process.exit(2);
    }
  } catch (e) {
    process.stderr.write(`condense error: ${e.message}\n`);
    process.exit(1);
  }
}
