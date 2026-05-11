#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

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

export function slice(transcriptPath, cursorUuid, hintStr) {
  const lines = readLines(transcriptPath);
  const hint = parseInt(hintStr, 10);

  if (Number.isFinite(hint) && hint > 0 && hint <= lines.length) {
    if (uuidOf(lines[hint - 1]) === cursorUuid) {
      return { deltaStart: hint + 1 };
    }
  }

  for (let i = 0; i < lines.length; i++) {
    if (uuidOf(lines[i]) === cursorUuid) {
      return { deltaStart: i + 2 };
    }
  }

  return { deltaStart: 1 };
}

export function lastUuid(deltaPath) {
  const lines = readLines(deltaPath);
  for (let i = lines.length - 1; i >= 0; i--) {
    const u = uuidOf(lines[i]);
    if (u) {
      return { uuid: u, relLine: i + 1 };
    }
  }
  return null;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [, , cmd, ...args] = process.argv;
  try {
    if (cmd === 'slice') {
      const { deltaStart } = slice(args[0], args[1], args[2] ?? '0');
      process.stdout.write(`DELTA_START=${deltaStart}\n`);
      process.exit(0);
    } else if (cmd === 'last-uuid') {
      const result = lastUuid(args[0]);
      if (result) {
        process.stdout.write(`UUID=${result.uuid}\nREL_LINE=${result.relLine}\n`);
        process.exit(0);
      } else {
        process.exit(1);
      }
    } else {
      process.stderr.write(`usage: cursor-slice.mjs slice|last-uuid ...\n`);
      process.exit(2);
    }
  } catch (e) {
    process.stderr.write(`cursor-slice error: ${e.message}\n`);
    process.exit(1);
  }
}
