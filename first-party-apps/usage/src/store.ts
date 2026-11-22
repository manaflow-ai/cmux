// The app's one shared store: the usage server's reading, the baseline
// reading for the pace, the clock that drives countdown text, and the
// out-of-accounts warning. Event driven: reads happen on mount (when nothing
// is loaded yet), on `account.watch`, and on user commands. The usage server
// decides when to run the router; the app never polls and never spawns.

import { planAlerts, type Fired } from "./alerts.ts"
import { isStale, nextTextChange } from "./format.ts"
import { normalizeHistory, normalizeUsage, snapshotOf, type Snapshot, type Usage } from "./model.ts"
import { notifyAlerts } from "./notify.ts"
import { MIN_BASELINE_MS, pickBaseline, providerPace, type ProviderPace } from "./pace.ts"

export type LoadState = "loading" | "ready" | "unavailable" | "denied" | "error"
export type Demand = "glance" | "detail"

export const ACCOUNT_LIST = "account.list"
export const ACCOUNT_USAGE = "account.usage"
export const ACCOUNT_REFRESH = "account.refresh"

const [usage, setUsage] = signal<Usage | null>(null)
const [baseline, setBaseline] = signal<Snapshot | null>(null)
const [state, setState] = signal<LoadState>("loading")
const [problem, setProblem] = signal<{ code: string; message: string; scope?: string } | null>(null)
const [now, setNow] = signal(Date.now())

export { baseline, now, problem, state, usage }

export const settings = () => cmux.app.settings()
export const staleMs = () => Math.max(1, Number(settings().staleMinutes ?? 30)) * 60_000

export const providers = () => usage()?.providers ?? []
/** The time the numbers describe: the server's reading time, else now. */
export const readingAt = () => usage()?.fetchedAt ?? now()
export const stale = () => {
  const u = usage()
  return u ? isStale(u, now(), staleMs()) : false
}

/** Pace per provider, computed at the reading time (it does not change with the clock). */
export const paces = computed<ProviderPace[]>(() => {
  const u = usage()
  if (!u) return []
  const current = snapshotOf(u, u.fetchedAt ?? now())
  const base = baseline()
  return u.providers.map((p) => providerPace(p, current, base))
})
export const paceOf = (provider: string) => paces().find((p) => p.provider === provider) ?? null

let inFlight: Promise<void> | null = null
let again = false

/** One read; a read requested while one runs runs once after it. */
export function load(): Promise<void> {
  if (inFlight) {
    again = true
    return inFlight
  }
  inFlight = readAll().finally(() => {
    inFlight = null
    if (again) {
      again = false
      void load()
    }
  })
  return inFlight
}

async function readAll(): Promise<void> {
  let next: Usage
  try {
    next = normalizeUsage(await cmux.call(ACCOUNT_LIST, {}))
  } catch (err) {
    const e = err as { code?: string; message?: string; details?: { scope?: string } }
    const code = e?.code ?? "operation.failed"
    setProblem({ code, message: e?.message ?? String(err), scope: e?.details?.scope })
    // A failed read keeps the last reading on screen; its age marks it stale.
    setState(code === "operation.unsupported" ? "unavailable" : code === "scope.missing" ? "denied" : usage() ? "ready" : "error")
    if (code !== "operation.unsupported" && code !== "scope.missing") cmux.log("usage read failed:", code)
    setNow(Date.now())
    return
  }
  // The baseline: the newest reading at least 30 minutes older than this one.
  const at = next.fetchedAt ?? Date.now()
  const history = await cmux.call(ACCOUNT_USAGE, { before_ms: String(at - MIN_BASELINE_MS), limit: 1 }).catch(() => null)
  setNow(Date.now())
  setBaseline(history === null ? null : pickBaseline(normalizeHistory(history), at))
  setUsage(next)
  setProblem(next.error)
  setState("ready")
  queueAlerts()
}

// Clock: one one-shot timer at the next moment a displayed countdown or age
// changes (README gap 2: a native relative-date text node would remove it).
// Each mounted surface keeps it armed through an effect; with no surface
// mounted nothing re-arms it, so at most one timer fires after the last unmount.
let clockTimer: number | null = null
let armQueued = false

function clockTargets(at: number) {
  const countdownsTo: number[] = []
  const agesFrom: number[] = []
  const staleAt: number[] = []
  const u = usage()
  if (u?.fetchedAt != null) {
    if (isStale(u, at, staleMs())) agesFrom.push(u.fetchedAt)
    else staleAt.push(u.fetchedAt + staleMs())
  }
  for (const p of u?.providers ?? []) {
    for (const a of p.accounts) {
      if (a.session?.resetAt != null) countdownsTo.push(a.session.resetAt)
      if (a.weekly?.resetAt != null) countdownsTo.push(a.weekly.resetAt)
    }
  }
  return { countdownsTo, agesFrom, staleAt }
}

/** Arms the clock from a microtask, outside any mount's owner, so no mount owns the timer. */
function requestClock() {
  if (armQueued) return
  armQueued = true
  Promise.resolve().then(() => {
    armQueued = false
    if (clockTimer !== null) cmux.timer.clear(clockTimer)
    clockTimer = null
    const at = Date.now()
    const next = nextTextChange(at, clockTargets(at))
    if (next === null) return
    clockTimer = cmux.timer.after(next - at + 5, () => {
      clockTimer = null
      setNow(Date.now())
    })
  })
}

/**
 * Called by every render: subscribes this mount to `account.watch` (the
 * filter tells the server how much detail is on screen, README "Refresh
 * policy"), reads once if nothing is loaded, and keeps the clock armed. The
 * subscription and the effect belong to the mount and end with it.
 */
export function attach(demand: Demand): void {
  setNow(Date.now())
  cmux.events.on("account.watch", () => void load(), { demand })
  effect(() => {
    now()
    usage()
    staleMs()
    requestClock()
  })
  if (state() === "loading" && !inFlight) void load()
}

/** User-initiated refresh: asks the server to run the router now (it rate-limits), then reads. */
export async function refreshNow(): Promise<{ requested: boolean }> {
  let requested = true
  try {
    await cmux.call(ACCOUNT_REFRESH, {})
  } catch {
    requested = false
  }
  await load()
  return { requested }
}

// Warning: a provider whose accounts are all used up, once until one is usable again.
const ALERTS_KEY = "alerts.v2"
let alertChain: Promise<void> = Promise.resolve()
let fired: Fired | null = null

function queueAlerts() {
  // An old reading is not news.
  if (settings().notifications === false || stale()) return
  const snapshot = providers()
  alertChain = alertChain
    .then(async () => {
      fired ??= ((await cmux.storage.get<Fired>(ALERTS_KEY).catch(() => null)) ?? {}) as Fired
      const plan = planAlerts(snapshot, fired)
      fired = plan.fired
      // Without storage the in-memory state still deduplicates for this VM's lifetime.
      await cmux.storage.set(ALERTS_KEY, plan.fired).catch((e) => cmux.log("usage alerts not persisted:", String(e)))
      await notifyAlerts(plan.alerts)
    })
    .catch((e) => cmux.log("usage alerts failed:", String(e)))
}

/** For tests: wait until queued warnings are sent. */
export const alertsSettled = () => alertChain
