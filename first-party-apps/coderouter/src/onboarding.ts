// First-run setup as a pure reducer. Progress is kept in cmux.storage (key
// `onboarding`), so setup resumes where the user left it, on any surface.
// A step is complete when the user finished it here or when the data already
// shows it (an account is connected, a key exists, the last test passed).

export const STEPS = ["detect", "connect", "share", "use", "test"] as const
export type Step = (typeof STEPS)[number]
export type StepState = "done" | "skipped" | "current" | "todo" | "notNeeded"

export interface Progress {
  version: 1
  current: Step
  done: Step[]
  skipped: Step[]
  /** The user closed setup ("Skip setup"). Start Onboarding reopens it. */
  dismissed: boolean
  finished: boolean
  updated_at_ms: number
}

/** What the data says right now. */
export interface Facts {
  signedIn: boolean
  scopeKind: "personal" | "team" | null
  connected: number
  privateConnected: number
  agentsRouted: boolean
  keys: number
  lastTestOk: boolean
}

export type OnboardingEvent =
  | { type: "next" }
  | { type: "back" }
  | { type: "skip" }
  | { type: "goto"; step: Step }
  | { type: "complete"; step: Step }
  | { type: "dismiss" }
  | { type: "restart" }

export const initialProgress = (now = 0): Progress => ({ version: 1, current: "detect", done: [], skipped: [], dismissed: false, finished: false, updated_at_ms: now })

/** Accepts what storage returned; anything unknown starts fresh. */
export function parseProgress(raw: unknown): Progress {
  if (!raw || typeof raw !== "object") return initialProgress()
  const p = raw as Partial<Progress>
  if (p.version !== 1) return initialProgress()
  const steps = (v: unknown) => (Array.isArray(v) ? v.filter((s): s is Step => (STEPS as readonly string[]).includes(s as string)) : [])
  return {
    version: 1,
    current: (STEPS as readonly string[]).includes(p.current as string) ? (p.current as Step) : "detect",
    done: steps(p.done),
    skipped: steps(p.skipped),
    dismissed: p.dismissed === true,
    finished: p.finished === true,
    updated_at_ms: typeof p.updated_at_ms === "number" ? p.updated_at_ms : 0
  }
}

/** Sharing only exists in a team scope: a personal scope's private accounts already serve your own machines. */
export const notNeeded = (step: Step, f: Facts) => step === "share" && f.scopeKind === "personal"

/** Completion the data proves, independent of clicks. */
export function provenByData(step: Step, f: Facts): boolean {
  switch (step) {
    case "detect":
      return false
    case "connect":
      return f.connected > 0
    case "share":
      return f.connected > 0 && f.privateConnected === 0
    case "use":
      return f.agentsRouted || f.keys > 0
    case "test":
      return f.lastTestOk
  }
}

export function stepState(step: Step, p: Progress, f: Facts): StepState {
  if (notNeeded(step, f)) return "notNeeded"
  if (p.done.includes(step) || provenByData(step, f)) return "done"
  if (p.skipped.includes(step)) return "skipped"
  return step === p.current ? "current" : "todo"
}

const settled = (s: StepState) => s === "done" || s === "skipped" || s === "notNeeded"

/** The first step still open after `from`, or null when every step is settled. */
export function nextOpen(p: Progress, f: Facts, from: Step | null = null): Step | null {
  const start = from ? STEPS.indexOf(from) + 1 : 0
  for (let i = start; i < STEPS.length; i++) if (!settled(stepState(STEPS[i]!, p, f))) return STEPS[i]!
  return null
}

export function remaining(p: Progress, f: Facts): number {
  return STEPS.filter((s) => !settled(stepState(s, p, f))).length
}

/** Fraction of steps settled, for a progress bar. */
export function fraction(p: Progress, f: Facts): number {
  const applicable = STEPS.filter((s) => !notNeeded(s, f))
  return applicable.filter((s) => settled(stepState(s, p, f))).length / applicable.length
}

/** Setup shows while signed in, not dismissed and not finished. */
export const shouldShow = (p: Progress, f: Facts) => f.signedIn && !p.dismissed && !p.finished

const add = (list: Step[], s: Step) => (list.includes(s) ? list : [...list, s])
const without = (list: Step[], s: Step) => list.filter((x) => x !== s)

/** Moves to the next open step after `from`; finishes when none is left. */
function advance(p: Progress, f: Facts, from: Step): Progress {
  const next = nextOpen(p, f, from) ?? nextOpen(p, f)
  return next ? { ...p, current: next } : { ...p, finished: true }
}

export function reduce(p: Progress, e: OnboardingEvent, f: Facts, now: number): Progress {
  const stamp = (q: Progress): Progress => ({ ...q, updated_at_ms: now })
  switch (e.type) {
    case "next":
      return stamp(advance({ ...p, done: add(p.done, p.current), skipped: without(p.skipped, p.current) }, f, p.current))
    case "complete": {
      const q = { ...p, done: add(p.done, e.step), skipped: without(p.skipped, e.step) }
      return stamp(e.step === p.current ? advance(q, f, e.step) : q)
    }
    case "skip":
      return stamp(advance(p.done.includes(p.current) ? p : { ...p, skipped: add(p.skipped, p.current) }, f, p.current))
    case "back": {
      let i = STEPS.indexOf(p.current) - 1
      while (i > 0 && notNeeded(STEPS[i]!, f)) i--
      return stamp({ ...p, current: STEPS[Math.max(0, i)]! })
    }
    case "goto":
      return stamp({ ...p, current: e.step, finished: false, dismissed: false })
    case "dismiss":
      return stamp({ ...p, dismissed: true })
    case "restart":
      return stamp({ ...p, dismissed: false, finished: false, current: nextOpen({ ...p, skipped: [] }, f) ?? "detect", skipped: [] })
  }
}
