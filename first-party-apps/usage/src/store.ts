// The app's one shared store: usage from the host-side usage service, the
// clock that drives relative text, and threshold warnings. Event driven:
// reads happen on mount (when nothing is loaded yet), on `usage.changed`,
// and on user commands. The service decides when to fetch from providers.

import { cleanThresholds, planAlerts, type Fired } from "./alerts.ts"
import { isStale, nextTextChange } from "./format.ts"
import { t } from "./l10n.ts"
import { normalizePools, normalizeUsage, type UsageAccount } from "./model.ts"
import { notifyAlerts } from "./notify.ts"
import { paceOf } from "./pace.ts"

export type LoadState = "loading" | "ready" | "unavailable" | "denied" | "error"
export type Demand = "glance" | "detail"

export const USAGE_GET = "usage.get"
export const POOLS_GET = "coderouter.usage.get"

const [accounts, setAccounts] = signal<UsageAccount[]>([])
const [pools, setPools] = signal<UsageAccount[]>([])
const [state, setState] = signal<LoadState>("loading")
const [problem, setProblem] = signal<{ code: string; message: string; scope?: string } | null>(null)
const [now, setNow] = signal(Date.now())

export { now, problem, state }

/** Plans and API accounts from `usage.get`, then CodeRouter pool accounts (plain reads, never a lagging computed). */
export const allAccounts = () => [...accounts(), ...pools()]

export const settings = () => cmux.app.settings()
export const thresholds = () => cleanThresholds(settings().warnAt)
export const staleMs = () => Math.max(1, Number(settings().staleMinutes ?? 30)) * 60_000

let inFlight: Promise<void> | null = null
let again = false

/** One read of both sources; a read requested while one runs runs once after it. */
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
  const [usage, pool] = await Promise.allSettled([cmux.call(USAGE_GET, {}), cmux.call(POOLS_GET, {})])
  setNow(Date.now())
  // Pools are optional (scope `coderouter:read`, cloud op): any failure only hides them.
  setPools(pool.status === "fulfilled" ? normalizePools(pool.value, t("pool", "pool")) : [])
  if (usage.status === "fulfilled") {
    setAccounts(normalizeUsage(usage.value))
    setProblem(null)
    setState("ready")
    queueAlerts()
  } else {
    const e = usage.reason as { code?: string; message?: string; details?: { scope?: string } }
    const code = e?.code ?? "operation.failed"
    setProblem({ code, message: e?.message ?? String(usage.reason), scope: e?.details?.scope })
    // A failed read keeps the last accounts on screen; their age marks them stale.
    setState(code === "operation.unsupported" ? "unavailable" : code === "scope.missing" ? "denied" : accounts().length ? "ready" : "error")
    if (code !== "operation.unsupported" && code !== "scope.missing") cmux.log("usage read failed:", code)
  }
}

// Clock: one one-shot timer at the next moment a displayed relative text
// changes (README gap 2: a native relative-date text node would remove it).
// Each mounted surface keeps it armed through an effect that re-runs when the
// time or the data changes; with no surface mounted nothing re-arms it, so at
// most one timer fires after the last unmount.
let clockTimer: number | null = null
let armQueued = false

function clockTargets(at: number) {
  const countdownsTo: number[] = []
  const agesFrom: number[] = []
  const staleAt: number[] = []
  for (const a of allAccounts()) {
    if (a.fetchedAt !== null) {
      if (isStale(a, at, staleMs())) agesFrom.push(a.fetchedAt)
      else staleAt.push(a.fetchedAt + staleMs())
    }
    for (const w of a.windows) {
      if (w.resetsAt !== null) countdownsTo.push(w.resetsAt)
      const pace = paceOf(w, at)
      if (pace?.runsOutAt) countdownsTo.push(pace.runsOutAt)
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
 * Called by every render: subscribes this mount to `usage.changed` (the
 * filter tells the service how much detail is on screen, README "Refresh
 * policy"), reads once if nothing is loaded, and keeps the clock armed. The
 * subscriptions and the effect belong to the mount and end with it.
 */
export function attach(demand: Demand): void {
  setNow(Date.now())
  cmux.events.on("usage.changed", () => void load(), { demand })
  cmux.events.on("coderouter.usage.changed", () => void load(), { demand })
  effect(() => {
    now()
    allAccounts()
    staleMs()
    requestClock()
  })
  if (state() === "loading" && !inFlight) void load()
}

/** User-initiated refresh: asks the service (it rate-limits per account), then reads. */
export async function refreshNow(params: { provider?: string; account?: string } = {}): Promise<{ requested: boolean }> {
  let requested = true
  try {
    await cmux.call("usage.refresh", params)
  } catch {
    requested = false
  }
  await load()
  return { requested }
}

// Warnings: evaluated after each read, serialized, deduplicated through cmux.storage.
const ALERTS_KEY = "alerts.v1"
let alertChain: Promise<void> = Promise.resolve()
let fired: Fired | null = null

function queueAlerts() {
  if (settings().notifications === false) return
  const snapshot = allAccounts()
  alertChain = alertChain
    .then(async () => {
      fired ??= ((await cmux.storage.get<Fired>(ALERTS_KEY).catch(() => null)) ?? {}) as Fired
      const plan = planAlerts(snapshot, thresholds(), fired, Date.now(), staleMs())
      fired = plan.fired
      // Without storage the in-memory state still deduplicates for this VM's lifetime.
      await cmux.storage.set(ALERTS_KEY, plan.fired).catch((e) => cmux.log("usage alerts not persisted:", String(e)))
      await notifyAlerts(plan.alerts, Date.now())
    })
    .catch((e) => cmux.log("usage alerts failed:", String(e)))
}

/** For tests: wait until queued warnings are sent. */
export const alertsSettled = () => alertChain
