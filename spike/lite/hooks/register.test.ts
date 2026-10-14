import { describe, expect, test } from 'claude-code/testing'
import type { Engine, On } from 'claude-code'

const LOG = '/tmp/watchdog-lite-test.jsonl'
const USAGE = {
  input_tokens: 12,
  output_tokens: 2,
  cache_read_input_tokens: 40_000,
  cache_creation_input_tokens: 300,
}

type Fake = { forks: string[]; written: Promise<string> }

// Answers every $ call the module makes, so no model or disk is touched.
// A noun call's hook answers `{ value }`; an event's answers its result.
function fake(on: On, fork: () => unknown = () => ({ isAnswered: true, text: 'ok', usage: USAGE })): Fake {
  const forks: string[] = []
  let resolveWrite: (text: string) => void = () => {}
  const written = new Promise<string>(r => { resolveWrite = r })
  on('turn.complete', () => ({ text: '' }))
  on('env.get', ($, e) => ({ value: e.name === 'CLAUDE_WATCHDOG_LITE_LOG' ? LOG : undefined }))
  on('fs.read', () => { throw new Error('missing') })
  on('fs.write', ($, e) => { resolveWrite(e.text); return { value: undefined } })
  on('session.id', () => ({ value: 'sess-1' }))
  on('model.fork', ($, e) => { forks.push(e.prompt); return { value: fork() as never } })
  return { forks, written }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await Promise.resolve()
}

function turn(extra: object = {}) {
  return { reason: 'answer', answer: 'done', durationMs: 900, isAborted: false, turnId: 't-1', ...extra } as never
}

describe('turn.complete fork probe', () => {
  test('a main-thread turn forks once and logs the fork usage', async ($: Engine, on: On) => {
    const f = fake(on)
    await $.turn.complete(turn())
    const line = JSON.parse((await f.written).trim())
    expect(f.forks).toHaveLength(1)
    expect(line).toMatchObject({
      kind: 'fork-probe', sessionId: 'sess-1', turnId: 't-1', outcome: 'answered', usage: USAGE,
    })
  })

  test('a fork with nothing to fork logs the reason', async ($: Engine, on: On) => {
    const f = fake(on, () => ({ isAnswered: false, reason: 'nothing-to-fork' }))
    await $.turn.complete(turn())
    expect(JSON.parse((await f.written).trim())).toMatchObject({ outcome: 'nothing-to-fork', usage: null })
  })

  test('a subagent turn does not fork', async ($: Engine, on: On) => {
    const f = fake(on)
    await $.turn.complete(turn({ agentId: 'agent-1' }))
    await settle()
    expect(f.forks).toHaveLength(0)
  })

  test('an interrupted turn does not fork', async ($: Engine, on: On) => {
    const f = fake(on)
    await $.turn.complete(turn({ reason: 'aborted', isAborted: true }))
    await settle()
    expect(f.forks).toHaveLength(0)
  })
})
