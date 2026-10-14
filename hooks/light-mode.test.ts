import { describe, expect, test } from 'claude-code/testing'
import type { Engine, On } from 'claude-code'

import { parse } from './light-mode'

const DIR = '/fake/light'
const LOG = '/fake/light.jsonl'
const SID = 'sess-1'
const USAGE = { input_tokens: 9000, output_tokens: 700, cache_read_input_tokens: 100_000, cache_creation_input_tokens: 600 }

const REQUEST = {
  version: 1, sessionId: SID, projectRoot: '/repo', cwd: '/repo', commitRange: 'abc1234',
  touchedFiles: ['src/a.ts'], externalFiles: [], attribution: null, previousAnalysis: null,
  isContinuation: true, analysesDir: '/fake/analyses', createdAt: '2026-10-14T00:00:00Z',
}

const FINDINGS = `verdict: findings
### Goals
The fix landed but its test never ran.

### Quality
The new test was written but not run. The transcript shows no test command after the edit. A broken test would ship.

### Recommendations
- **Run the new test** [process]: run just test before committing.`

const CLEAN = `verdict: clean
### Goals
Done as asked.

### Recommendations
none`

type World = {
  files: Map<string, string>
  forks: string[]
  gitCalls: string[][]
  toasts: string[]
  fills: string[]
  store: Map<string, unknown>
  checked: Promise<void>
}

// Plays every $ call the module makes. A noun call's hook answers `{ value }`;
// an event's hook answers the event's result.
function world(on: On, opts: { reply?: string; env?: Record<string, string>; files?: Record<string, string>; diff?: string } = {}): World {
  const env: Record<string, string> = { CLAUDE_WATCHDOG_LIGHT_DIR: DIR, CLAUDE_WATCHDOG_LIGHT_LOG: LOG, HOME: '/home/u', ...opts.env }
  const files = new Map(Object.entries(opts.files ?? {}))
  const w: Omit<World, 'checked'> = { files, forks: [], gitCalls: [], toasts: [], fills: [], store: new Map() }
  let resolveChecked: () => void = () => {}
  const checked = new Promise<void>(r => { resolveChecked = r })
  on('turn.start', ($, e) => ({ turnId: e.turnId }) as never)
  // The engine's own band, drawn when the module has nothing to show.
  on('ui.render', () => ({ type: 'Box', props: {}, children: [] }) as never)
  on('turn.complete', () => ({ text: '' }))
  on('session.start', () => ({}) as never)
  on('env.get', ($, e) => ({ value: env[e.name] }))
  on('session.id', () => ({ value: SID }))
  on('fs.read', ($, e) => {
    if (e.path.endsWith('/hooks/light-prompt.md')) return { value: 'RULES' }
    const text = files.get(e.path)
    if (text === undefined) throw new Error(`missing ${e.path}`)
    return { value: text }
  })
  on('fs.write', ($, e) => {
    files.set(e.path, e.text)
    if (e.path === LOG && e.text.includes('"kind":"check"')) resolveChecked()
    return { value: undefined }
  })
  on('process.run', ($, e) => {
    w.gitCalls.push([...e.argv])
    const sub = e.argv[1]
    const stdout = sub === 'status' ? ' M src/a.ts\n?? src/new.ts\n'
      : sub === 'diff' && e.argv.includes('--stat') ? ' src/a.ts | 2 +-\n'
      : sub === 'diff' && e.argv.includes('--no-index') ? '+new file\n'
      : (opts.diff ?? '-old\n+new\n')
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('model.fork', ($, e) => {
    w.forks.push(e.prompt)
    return { value: { isAnswered: true, text: opts.reply ?? FINDINGS, usage: USAGE } as never }
  })
  on('store.get', ($, e) => ({ value: w.store.get(e.key) }))
  on('store.set', ($, e) => { w.store.set(e.key, e.value); return { value: undefined } })
  on('ui.toast', ($, e) => { w.toasts.push(e.text); return { value: undefined } })
  on('prompt.fill', ($, e) => { w.fills.push(e.text); return { isFilled: true } })
  return { ...w, checked }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 50; i++) await Promise.resolve()
}

const ON = { options: { light_mode: 'on' } }
const turnEnd = (extra: object = {}) =>
  ({ reason: 'answer', answer: 'done', durationMs: 900, isAborted: false, turnId: 't-1', ...extra }) as never
const withRequest = (extra: object = {}) => ({ [`${DIR}/light-${SID}.json`]: JSON.stringify({ ...REQUEST, ...extra }) })
const band = ($: Engine) => $.ui.mount({
  plugin: 'claude-watchdog', surface: 'terminal', component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: false, maxRows: 12, bodyColumns: 80 } as never,
})

describe('alive marker', () => {
  test('light mode on: each turn start marks the session alive', ON, async ($: Engine, on: On) => {
    const w = world(on)
    await $.turn.start({ text: 'hi', turnId: 't-1' } as never)
    expect(w.files.has(`${DIR}/alive-${SID}`)).toBe(true)
  })

  test('light mode off: no marker, so the Stop hook keeps the analyzer', async ($: Engine, on: On) => {
    const w = world(on)
    await $.turn.start({ text: 'hi', turnId: 't-1' } as never)
    expect(w.files.has(`${DIR}/alive-${SID}`)).toBe(false)
  })

  test('a third-party provider gets no marker (first-party only)', ON, async ($: Engine, on: On) => {
    const w = world(on, { env: { CLAUDE_CODE_USE_BEDROCK: '1' } })
    await $.turn.start({ text: 'hi', turnId: 't-1' } as never)
    expect(w.files.has(`${DIR}/alive-${SID}`)).toBe(false)
  })
})

describe('turn.complete picks up the request', () => {
  test('findings: consumes the request, forks once, persists, shows the band', ON, async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest() })
    await $.turn.complete(turnEnd())
    await w.checked
    await settle()

    expect(JSON.parse(w.files.get(`${DIR}/light-${SID}.json`)!).consumedAt).toEqual(expect.any(String))
    expect(w.forks).toHaveLength(1)
    const prompt = w.forks[0]
    expect(prompt.startsWith('RULES')).toBe(true)
    expect(prompt).toContain('git diff abc1234 -- <touched files>')
    expect(prompt).toContain('+new')
    expect(w.gitCalls).toContainEqual(['git', 'diff', 'abc1234', '--', 'src/a.ts'])
    // src/new.ts is untracked but not touched this slice, so it is left out.
    expect(w.gitCalls.some(c => c.includes('--no-index'))).toBe(false)

    const saved = [...w.files.keys()].find(k => k.startsWith('/fake/analyses/sess-1-'))
    expect(saved).toMatch(/\/sess-1-\d{8}T\d{6}Z\.md$/)
    expect(w.files.get(saved!)!.startsWith('### Goals')).toBe(true)
    expect(w.store.get('seen')).toEqual(['Run the new test'])

    const ui = await band($)
    expect((await ui.find({ key: 'send' }))).toBeDefined()
    expect(JSON.stringify(await ui.drawn())).toContain('Run the new test')
  })

  test('clean: a toast and no band', ON, async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest(), reply: CLEAN })
    await $.turn.complete(turnEnd())
    await w.checked
    await settle()
    expect(w.toasts).toEqual(['✓ Watchdog: nothing to report'])
    const ui = await band($)
    expect(await ui.find({ key: 'send' })).toBeUndefined()
  })

  test('the seen and not-useful titles reach the prompt', ON, async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest() })
    w.store.set('seen', ['Old finding'])
    w.store.set('known', ['Ignored finding'])
    await $.turn.complete(turnEnd())
    await w.checked
    expect(w.forks[0]).toContain('## Already reported\n- Old finding')
    expect(w.forks[0]).toContain('## The user marked these not useful\n- Ignored finding')
  })

  test('an untracked touched file is shown whole', ON, async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest({ touchedFiles: ['src/a.ts', 'src/new.ts'] }) })
    await $.turn.complete(turnEnd())
    await w.checked
    expect(w.gitCalls).toContainEqual(['git', 'diff', '--no-index', '--', '/dev/null', 'src/new.ts'])
    expect(w.forks[0]).toContain('+new file')
  })

  test('a diff over 20 KB is cut', ON, async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest(), diff: 'x'.repeat(30_000) })
    await $.turn.complete(turnEnd())
    await w.checked
    expect(w.forks[0]).toContain('[diff cut at 20480 bytes')
    expect(w.forks[0].length).toBeLessThan(25_000)
  })

  for (const [name, files, extra] of [
    ['a consumed request', withRequest({ consumedAt: '2026-10-14T00:00:01Z' }), {}],
    ['no request', {}, {}],
    ['a subagent turn', withRequest(), { agentId: 'agent-1' }],
  ] as const) {
    test(`${name}: no fork`, ON, async ($: Engine, on: On) => {
      const w = world(on, { files })
      await $.turn.complete(turnEnd(extra))
      await settle()
      expect(w.forks).toHaveLength(0)
    })
  }

  test('light mode off: a request is left alone', async ($: Engine, on: On) => {
    const w = world(on, { files: withRequest() })
    await $.turn.complete(turnEnd())
    await settle()
    expect(w.forks).toHaveLength(0)
  })
})

describe('band buttons', () => {
  async function shown($: Engine, on: On) {
    const w = world(on, { files: withRequest() })
    await $.turn.complete(turnEnd())
    await w.checked
    await settle()
    return { w, ui: await band($) }
  }

  test('Send to Claude fills the prompt with the review', ON, async ($: Engine, on: On) => {
    const { w, ui } = await shown($, on)
    await ui.press({ key: 'send' })
    expect(w.fills).toHaveLength(1)
    expect(w.fills[0]).toContain('**Run the new test** [process]')
    expect(await ui.find({ key: 'send' })).toBeUndefined()
    expect(w.files.get(LOG)).toContain('"answer":"sent"')
  })

  test('Dismiss clears the band and remembers nothing', ON, async ($: Engine, on: On) => {
    const { w, ui } = await shown($, on)
    await ui.press({ key: 'dismiss' })
    expect(await ui.find({ key: 'send' })).toBeUndefined()
    expect(w.store.get('known')).toBeUndefined()
  })

  test('Not useful remembers the titles', ON, async ($: Engine, on: On) => {
    const { w, ui } = await shown($, on)
    await ui.press({ key: 'not-useful' })
    expect(w.store.get('known')).toEqual(['Run the new test'])
  })
})

describe('band scope', () => {
  test("another session's review is not shown here", ON, async ($: Engine, on: On) => {
    const w = world(on)
    w.store.set('view', { sessionId: 'other', goals: 'g', titles: ['T'], body: 'b', file: null, shownAt: 0 })
    const ui = await band($)
    expect(await ui.find({ key: 'send' })).toBeUndefined()
  })
})

describe('parse', () => {
  test('reads the verdict, goals and titles', () => {
    expect(parse(FINDINGS)).toMatchObject({ isClean: false, goals: 'The fix landed but its test never ran.', titles: ['Run the new test'] })
    expect(parse(CLEAN).isClean).toBe(true)
  })

  test('without a verdict line, sections decide', () => {
    expect(parse(FINDINGS.split('\n').slice(1).join('\n')).isClean).toBe(false)
    expect(parse(CLEAN.split('\n').slice(1).join('\n')).isClean).toBe(true)
  })
})
