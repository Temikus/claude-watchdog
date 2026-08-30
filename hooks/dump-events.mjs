#!/usr/bin/env node
// Opt-in raw-stdin capture for hook events.
//
// The Claude Code hook payloads are an undocumented, moving external format and
// every event in the test suite is hand-built. Setting
// CLAUDE_WATCHDOG_DUMP_EVENTS=<dir> makes a real session write the bytes each
// hook actually received, so a fixture can be captured instead of guessed.
// See tests/fixtures/CAPTURE.md.
//
// Strictly opt-in, never fires when the variable is unset, and fails open: a
// capture failure must never change what the hook does.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';

// dumpEvent(hookName, input) - one file per invocation, unique by design:
// timestamp for ordering, pid + random suffix so concurrent hooks cannot collide.
export function dumpEvent(hookName, input) {
  try {
    const dir = process.env.CLAUDE_WATCHDOG_DUMP_EVENTS;
    if (!dir) return null;
    const ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.(\d{3})Z$/, '.$1Z');
    const name = `${hookName}-${ts}-${process.pid}-${randomBytes(3).toString('hex')}.json`;
    mkdirSync(dir, { recursive: true });
    const file = join(dir, name);
    writeFileSync(file, input);
    return file;
  } catch {
    return null; // unwritable dir, full disk, bad name - never break the hook
  }
}
