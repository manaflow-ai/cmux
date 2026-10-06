// The app's one shared store: power assertions from the host (list once,
// then the stream `power.assertion.watch`), the clock that drives countdown
// text, and the running commands the user can bind to. Event driven: no
// polling, and the app never spawns a process; the host holds the IOKit
// assertions.

import { assertionTitle, nextTextChange } from "./format.ts"
import { applyEvent, emptyState, fromList, running, type Assertion, type PowerState } from "./model.ts"
import type { CreateParams } from "./presets.ts"

export const LIST = "power.assertion.list"
export const CREATE = "power.assertion.create"
export const RELEASE = "power.assertion.release"
export const WATCH = "power.assertion.watch"

export type LoadState = "loading" | "ready" | "unavailable" | "denied" | "error"
export type Problem = { code: string; message: string; scope?: string }

const [power, setPower] = signal<PowerState>(emptyState())
const [status, setStatus] = signal<LoadState>("loading")
const [problem, setProblem] = signal<Problem | null>(null)
const [now, setNow] = signal(Date.now())
/** The last refusal of a start or stop, shown under the controls until the next action. */
const [actionError, setActionError] = signal<string | null>(null)

export { actionError, now, power, problem, setActionError, status }

/** Assertions still running now, soonest end first. */
export const active = computed<Assertion[]>(() => running(power(), now()))

const errorOf = (err: unknown): Problem => {
  const e = err as { code?: string; message?: string; details?: { scope?: string } }
  return { code: e?.code ?? "operation.failed", message: e?.message ?? String(err), scope: e?.details?.scope }
}

let inFlight: Promise<void> | null = null
let again = false

/** One list read; a read requested while one runs runs once after it. */
export function load(): Promise<void> {
  if (inFlight) {
    again = true
    return inFlight
  }
  inFlight = readList().finally(() => {
    inFlight = null
    if (again) {
      again = false
      void load()
    }
  })
  return inFlight
}

async function readList(): Promise<void> {
  try {
    const raw = await cmux.call(LIST, {})
    const next = fromList(raw, power())
    // The stream may already be ahead of this answer.
    if (next.revision >= power().revision) setPower(next)
    setProblem(next.available ? null : { code: next.unavailableReason ?? "power.unavailable", message: "" })
    setStatus(next.available ? "ready" : "unavailable")
  } catch (err) {
    const p = errorOf(err)
    setProblem(p)
    setStatus(p.code === "operation.unsupported" ? "unavailable" : p.code === "scope.missing" ? "denied" : "error")
    if (p.code !== "operation.unsupported" && p.code !== "scope.missing") cmux.log("power list failed:", p.code)
  }
  setNow(Date.now())
}

function onWatch(event: unknown) {
  const before = power()
  const after = applyEvent(before, event, assertionTitle)
  if (after === before) return
  setPower(after)
  setNow(Date.now())
  if (status() !== "ready" && after.available) {
    setStatus("ready")
    setProblem(null)
  }
}

// Clock: one one-shot timer at the next moment a displayed countdown changes.
// Each mounted surface keeps it armed through an effect; with nothing mounted
// nothing re-arms it.
let clockTimer: number | null = null
let armQueued = false

function requestClock() {
  if (armQueued) return
  armQueued = true
  Promise.resolve().then(() => {
    armQueued = false
    if (clockTimer !== null) cmux.timer.clear(clockTimer)
    clockTimer = null
    const at = Date.now()
    const ends = power().assertions.flatMap((a) => (a.expiresAt === null ? [] : [a.expiresAt]))
    const next = nextTextChange(ends, at)
    if (next === null) return
    clockTimer = cmux.timer.after(Math.max(0, next - at) + 5, () => {
      clockTimer = null
      setNow(Date.now())
    })
  })
}

/**
 * Called by every render: subscribes the mount to the watch stream, reads
 * once when nothing is loaded, and keeps the clock armed. The subscription
 * and the effect end with the mount.
 */
export function attach(): void {
  setNow(Date.now())
  cmux.events.on(WATCH, onWatch)
  effect(() => {
    now()
    power()
    requestClock()
  })
  if (status() === "loading" && !inFlight) void load()
}

export type StartResult = { started: true; assertion: string; expires_at: string | null } | { started: false; code: string; message: string }

/** Asks the host for the assertions. `gesture` is the token of the user event, when there is one. */
export async function create(params: CreateParams, options: { gesture?: string | null; idempotencyKey?: string } = {}): Promise<StartResult> {
  setActionError(null)
  try {
    const r = (await cmux.call(CREATE, params, { gesture: options.gesture ?? undefined, idempotencyKey: options.idempotencyKey })) as { assertion?: string; expires_at?: string | null }
    if (!power().assertions.some((a) => a.id === r?.assertion)) await load()
    return { started: true, assertion: String(r?.assertion ?? ""), expires_at: r?.expires_at ?? null }
  } catch (err) {
    const p = errorOf(err)
    setActionError(p.message || p.code)
    if (p.code === "operation.unsupported" || p.code === "scope.missing") await load()
    return { started: false, code: p.code, message: p.message }
  }
}

export async function release(id: string, options: { gesture?: string | null } = {}): Promise<{ released: boolean; code?: string }> {
  setActionError(null)
  try {
    await cmux.call(RELEASE, { assertion: id }, { gesture: options.gesture ?? undefined, idempotencyKey: `release:${id}` })
    if (power().assertions.some((a) => a.id === id)) await load()
    return { released: true }
  } catch (err) {
    const p = errorOf(err)
    // Already gone is what the user wanted.
    if (p.code === "power.not_found") {
      await load()
      return { released: true }
    }
    setActionError(p.message || p.code)
    return { released: false, code: p.code }
  }
}

/**
 * Stops every assertion the caller may stop, in one op so one user gesture
 * covers all of them (a gesture token is spent by the first mutation).
 */
export async function releaseAll(options: { gesture?: string | null } = {}): Promise<{ released: string[]; code?: string }> {
  setActionError(null)
  try {
    const r = (await cmux.call(RELEASE, { all: true }, { gesture: options.gesture ?? undefined })) as { released?: string[] }
    await load()
    return { released: Array.isArray(r?.released) ? r.released : [] }
  } catch (err) {
    const p = errorOf(err)
    setActionError(p.message || p.code)
    return { released: [], code: p.code }
  }
}

/** Dismisses the notice about an assertion that ended on its own. */
export const dismissRelease = () => setPower({ ...power(), lastRelease: null })
