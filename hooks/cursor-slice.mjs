#!/usr/bin/env node
// Cursor helper for claude-watchdog. Two subcommands:
//   slice <transcript_path> <cursor_uuid> <cursor_line_hint>
//     -> prints DELTA_START=<n> (1-based line number to start reading from)
//   last-uuid <delta_file>
//     -> prints UUID=<uuid> and REL_LINE=<n> for the last uuid-bearing line

import { readFileSync } from 'node:fs';

function readLines(path) {
  return readFileSync(path, 'utf8').split('\n');
}

function uuidOf(line) {
  if (!line || line[0] !== '{') return null;
  try {
    const obj = JSON.parse(line);
    return typeof obj.uuid === 'string' ? obj.uuid : null;
  } catch {
    return null;
  }
}

function slice(transcriptPath, cursorUuid, hintStr) {
  const lines = readLines(transcriptPath);
  const hint = parseInt(hintStr, 10);

  if (Number.isFinite(hint) && hint > 0 && hint <= lines.length) {
    if (uuidOf(lines[hint - 1]) === cursorUuid) {
      process.stdout.write(`DELTA_START=${hint + 1}\n`);
      return 0;
    }
  }

  for (let i = 0; i < lines.length; i++) {
    if (uuidOf(lines[i]) === cursorUuid) {
      process.stdout.write(`DELTA_START=${i + 2}\n`);
      return 0;
    }
  }

  process.stdout.write(`DELTA_START=1\n`);
  return 0;
}

function lastUuid(deltaPath) {
  const lines = readLines(deltaPath);
  for (let i = lines.length - 1; i >= 0; i--) {
    const u = uuidOf(lines[i]);
    if (u) {
      process.stdout.write(`UUID=${u}\nREL_LINE=${i + 1}\n`);
      return 0;
    }
  }
  return 1;
}

const [, , cmd, ...args] = process.argv;
try {
  if (cmd === 'slice') {
    process.exit(slice(args[0], args[1], args[2] ?? '0'));
  } else if (cmd === 'last-uuid') {
    process.exit(lastUuid(args[0]));
  } else {
    process.stderr.write(`usage: cursor-slice.mjs slice|last-uuid ...\n`);
    process.exit(2);
  }
} catch (e) {
  process.stderr.write(`cursor-slice error: ${e.message}\n`);
  process.exit(1);
}
