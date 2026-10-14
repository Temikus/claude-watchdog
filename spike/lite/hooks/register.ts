import type { Engine, Register } from 'claude-code'

// Step 1 probe: what does one fork cost right after a main-thread turn?
const PROBE_PROMPT = 'Reply with the single word ok.'

async function logPath($: Engine): Promise<string> {
  const override = await $.env.get('CLAUDE_WATCHDOG_LITE_LOG')
  return override ?? `${await $.env.get('HOME')}/.claude/logs/claude-watchdog-lite.jsonl`
}

// fs has no append. Read-modify-write can drop a line if two writes overlap;
// at one probe per turn that is acceptable for a spike.
async function appendLine($: Engine, line: object): Promise<void> {
  const path = await logPath($)
  const prior = await $.fs.read(path).catch(() => '')
  await $.fs.write(path, `${prior}${JSON.stringify(line)}\n`)
}

async function probe($: Engine, turn: { turnId: string; durationMs: number; usage?: unknown }) {
  const startedAt = Date.now()
  const reply = await $.model.fork({ prompt: PROBE_PROMPT })
  await appendLine($, {
    ts: new Date().toISOString(),
    kind: 'fork-probe',
    sessionId: await $.session.id(),
    turnId: turn.turnId,
    turnMs: turn.durationMs,
    turnUsage: turn.usage ?? null,
    latencyMs: Date.now() - startedAt,
    outcome: reply.isAnswered ? 'answered' : reply.reason,
    usage: 'usage' in reply ? reply.usage : null,
  })
}

export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && !e.isAborted) {
      // Not awaited: the turn's end must not wait on a model call.
      void probe($, e).catch(err => $.ui.log(`watchdog-lite: ${err}`, { to: 'debug' }))
    }
    return result
  })
}
