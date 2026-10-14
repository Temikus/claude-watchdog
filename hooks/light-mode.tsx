import type { Engine, Register } from 'claude-code'

// The Stop hook (session-analysis.mjs) keeps every gate. This module only
// marks itself alive, picks up the request the Stop hook leaves, forks the
// conversation for the review and shows it above the prompt. Modules cannot
// hook classic.Stop under managed settings, hence the file handshake.

// A review waiting in the band. Kept in $.store rather than $.state: $.state
// needs a "types" key in plugin.json, which older strict manifests reject.
type LightView = {
  sessionId: string
  goals: string
  titles: string[]
  body: string
  file: string | null
  shownAt: number
}

async function setView($: Engine, value: LightView | null): Promise<void> {
  await $.store.set('view', value)
  $.ui.invalidate('ui.render')
}

// The store is shared by every session, so only this session's review shows.
async function currentView($: Engine): Promise<LightView | null> {
  const v = (await $.store.get('view')) as LightView | null | undefined
  return v && v.sessionId === (await $.session.id()) ? v : null
}

const DIFF_CAP_BYTES = 20 * 1024
const SEEN_CAP = 50
const SESSION_END_WAIT_MS = 30_000

type Request = {
  version: number
  sessionId: string
  projectRoot: string | null
  cwd: string
  commitRange: string | null
  touchedFiles: string[]
  externalFiles: string[]
  attribution: string | null
  previousAnalysis: string | null
  isContinuation: boolean
  analysesDir: string
  createdAt: string
  consumedAt?: string
}

// Must match LIGHT_DIR in session-analysis.mjs.
async function lightDir($: Engine): Promise<string> {
  return (await $.env.get('CLAUDE_WATCHDOG_LIGHT_DIR'))
    ?? `${await $.env.get('HOME')}/.claude/tmp/claude-watchdog/light`
}

async function logFile($: Engine): Promise<string> {
  return (await $.env.get('CLAUDE_WATCHDOG_LIGHT_LOG'))
    ?? `${await $.env.get('HOME')}/.claude/logs/claude-watchdog-light.jsonl`
}

// fs has no append. Read-modify-write can drop a line if two writes overlap;
// at one check per turn that is acceptable.
async function logLine($: Engine, line: object): Promise<void> {
  const path = await logFile($)
  const prior = await $.fs.read(path).catch(() => '')
  await $.fs.write(path, `${prior}${JSON.stringify({ ts: new Date().toISOString(), ...line })}\n`)
}

const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [])

// Light mode is on when the env override or the plugin option says so, and the
// session talks to the first-party API (D3 in design/mod-light-mode-spike.md).
async function mode($: Engine, option: unknown): Promise<'off' | 'on' | 'both' | 'third-party'> {
  const raw = (await $.env.get('CLAUDE_WATCHDOG_LIGHT_MODE')) ?? (typeof option === 'string' ? option : 'off')
  if (raw !== 'on' && raw !== 'both') return 'off'
  const providers = [
    await $.env.get('CLAUDE_CODE_USE_BEDROCK'),
    await $.env.get('CLAUDE_CODE_USE_VERTEX'),
    await $.env.get('CLAUDE_CODE_USE_FOUNDRY'),
  ]
  return providers.some(v => v === '1' || v === 'true') ? 'third-party' : raw
}

async function git($: Engine, cwd: string, args: string[]): Promise<string> {
  const r = await $.process.run(['git', ...args], { cwd, timeoutMs: 15000 }).catch(() => null)
  // `git diff --no-index` exits 1 when the files differ, which is the point.
  return r && (r.exitCode === 0 || r.exitCode === 1) ? r.stdout : ''
}

// The fork has no tools, so the diff it judges is collected here: the slice's
// commits plus uncommitted work in one `git diff <base>`, and the full text of
// touched files git does not track yet.
export async function evidence($: Engine, req: Request): Promise<string> {
  const cwd = req.projectRoot
  if (!cwd) return 'No git repository: judge from the conversation alone.'
  const base = req.commitRange ?? 'HEAD'
  const paths = req.touchedFiles.length ? ['--', ...req.touchedFiles] : []
  const status = await git($, cwd, ['status', '--short'])
  const stat = await git($, cwd, ['diff', '--stat', base])
  let hunks = await git($, cwd, ['diff', base, ...paths])
  for (const line of status.split('\n')) {
    const file = line.startsWith('?? ') ? line.slice(3).trim() : ''
    if (file && (req.touchedFiles.length === 0 || req.touchedFiles.includes(file))) {
      hunks += await git($, cwd, ['diff', '--no-index', '--', '/dev/null', file])
    }
  }
  let body = hunks
  if (new TextEncoder().encode(body).length > DIFF_CAP_BYTES) {
    body = `${body.slice(0, DIFF_CAP_BYTES)}\n[diff cut at ${DIFF_CAP_BYTES} bytes; judge the rest from the stat only]\n`
  }
  return [
    `Slice base: ${req.commitRange ? `${req.commitRange} (commits since the previous review, plus uncommitted work)` : 'HEAD (uncommitted work only)'}`,
    `git status --short:\n${status || '(clean)'}`,
    `git diff --stat ${base}:\n${stat || '(no changes)'}`,
    `git diff ${base}${paths.length ? ' -- <touched files>' : ''}:\n${body || '(no changes)'}`,
  ].join('\n\n')
}

export async function buildPrompt($: Engine, req: Request, seen: string[], known: string[]): Promise<string> {
  const rules = await $.fs.read(`${$.plugin.root}/hooks/light-prompt.md`)
  const slice = [
    req.isContinuation
      ? 'This slice covers only the work since the previous watchdog review.'
      : 'This slice is the whole session so far.',
    `Files touched this slice: ${req.touchedFiles.length ? req.touchedFiles.join(', ') : 'none through editor tools; check the diff'}`,
  ]
  if (req.externalFiles.length) slice.push(`Files touched outside the project root (not in the diff): ${req.externalFiles.join(', ')}`)
  if (req.attribution) slice.push(req.attribution)
  const list = (items: string[]) => (items.length ? items.map(t => `- ${t}`).join('\n') : '(none)')
  return [
    String(rules).trim(),
    `## Slice\n${slice.join('\n')}`,
    `## Already reported\n${list(seen)}`,
    `## The user marked these not useful\n${list(known)}`,
    `## Evidence\n${await evidence($, req)}`,
  ].join('\n\n')
}

export type Parsed = { isClean: boolean; body: string; goals: string; titles: string[] }

export function parse(text: string): Parsed {
  const lines = text.trim().split('\n')
  const first = lines[0]?.trim().toLowerCase() ?? ''
  const hasVerdict = first.startsWith('verdict:')
  const body = (hasVerdict ? lines.slice(1) : lines).join('\n').trim()
  const titles = [...body.matchAll(/^\s*(?:[-*]\s*)?\*\*(.+?)\*\*\s*\[(?:code|instruction|process)\]/gim)].map(m => m[1].trim())
  const goals = /###\s*Goals\s*\n([\s\S]*?)(?=\n###|$)/.exec(body)?.[1].trim() ?? ''
  const hasSections = /^###\s*(Efficiency|Quality|Compliance)\b/m.test(body)
  const isClean = hasVerdict
    ? first.replace(/^verdict:\s*/, '').startsWith('clean')
    : !hasSections && titles.length === 0
  return { isClean, body, goals, titles }
}

async function readRequest($: Engine, path: string): Promise<Request | null> {
  try {
    const req = JSON.parse(String(await $.fs.read(path))) as Request
    return req.version === 1 ? req : null
  } catch {
    return null
  }
}

async function check($: Engine, sessionId: string): Promise<void> {
  const path = `${await lightDir($)}/light-${sessionId}.json`
  const req = await readRequest($, path)
  if (!req || req.consumedAt) return
  // Marked before the fork, so the Stop hook never falls back for a request
  // this module already holds.
  await $.fs.write(path, `${JSON.stringify({ ...req, consumedAt: new Date().toISOString() })}\n`)

  const seen = strings(await $.store.get('seen'))
  const known = strings(await $.store.get('known'))
  const startedAt = Date.now()
  const reply = await $.model.fork({ prompt: await buildPrompt($, req, seen, known) })
  const usage = 'usage' in reply ? reply.usage : null
  if (!reply.isAnswered) {
    await logLine($, { kind: 'check', sessionId, outcome: reply.reason, latencyMs: Date.now() - startedAt, usage })
    return
  }

  const parsed = parse(reply.text)
  const ts = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
  const file = `${req.analysesDir}/${sessionId}-${ts}.md`
  const saved = await $.fs.write(file, `${parsed.body}\n`).then(() => file, () => null)
  if (parsed.isClean) {
    $.ui.toast('✓ Watchdog: nothing to report')
  } else {
    await $.store.set('seen', [...seen, ...parsed.titles].slice(-SEEN_CAP))
    await setView($, {
      sessionId, goals: parsed.goals, titles: parsed.titles, body: parsed.body, file: saved, shownAt: Date.now(),
    })
  }
  // Last, so a reader of the log knows the check has fully landed.
  await logLine($, {
    kind: 'check', sessionId, outcome: parsed.isClean ? 'clean' : 'findings',
    latencyMs: Date.now() - startedAt, usage, titles: parsed.titles, file: saved,
  })
}

// The Stop hook hands a review over only while this marker is fresh.
async function markAlive($: Engine, option: unknown): Promise<void> {
  const m = await mode($, option)
  if (m !== 'on' && m !== 'both') return
  await $.fs.write(`${await lightDir($)}/alive-${await $.session.id()}`, `${JSON.stringify({ ts: new Date().toISOString() })}\n`)
}

async function answer($: Engine, current: LightView, kind: 'sent' | 'not_useful' | 'dismissed'): Promise<void> {
  if (kind === 'sent') {
    await $.prompt.fill({ text: `Watchdog review (light mode):\n\n${current.body}\n\nAddress these findings.` })
  } else if (kind === 'not_useful') {
    await $.store.set('known', [...strings(await $.store.get('known')), ...current.titles].slice(-SEEN_CAP))
  }
  await setView($, null)
  await logLine($, { kind: 'answer', sessionId: current.sessionId, answer: kind, msToAnswer: Date.now() - current.shownAt })
}

export const register: Register = (on, options) => {
  const running = new Map<string, Promise<void>>()

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await markAlive($, options.light_mode).catch(() => {})
    return started
  })

  on('turn.start', async ($, e, next) => {
    await markAlive($, options.light_mode).catch(() => {})
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined) return result
    const m = await mode($, options.light_mode)
    if (m !== 'on' && m !== 'both') return result
    const sessionId = await $.session.id()
    if (running.has(sessionId)) return result
    // Not awaited: the turn's end must not wait on a model call.
    const job = check($, sessionId)
      .catch(err => logLine($, { kind: 'error', sessionId, error: String(err) }).catch(() => {}))
      .finally(() => running.delete(sessionId))
    running.set(sessionId, job)
    return result
  })

  // A headless run (`claude -p`) ends right after its last turn, which would
  // drop the review mid-fork. Wait for it, within the hook's budget.
  on('session.end', async ($, e, next) => {
    if (running.size > 0) {
      const ms = Math.max(0, Math.min(SESSION_END_WAIT_MS, next.budget.remainingMs - 1000))
      await Promise.race([Promise.allSettled([...running.values()]), $.clock.sleep(ms)])
    }
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current = await currentView($)
    if (e.props.hasSurvey || current === null) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    const titles = current.titles.length ? current.titles : ['See the full review']
    return (
      <Box flexDirection="column">
        <Text bold>Watchdog: {titles.length} {titles.length === 1 ? 'finding' : 'findings'}</Text>
        {current.goals ? <Text dimColor>{current.goals}</Text> : null}
        {titles.map(t => <Text key={t}>- {t}</Text>)}
        <Box>
          <Button key="send" hotkey="1" label="1: Send to Claude" onPress={() => answer($, current, 'sent')} />
          <Text> </Text>
          <Button key="not-useful" hotkey="2" label="2: Not useful" onPress={() => answer($, current, 'not_useful')} />
          <Text> </Text>
          <Button key="dismiss" hotkey="0" label="0: Dismiss" onPress={() => answer($, current, 'dismissed')} />
        </Box>
      </Box>
    )
  })
}
