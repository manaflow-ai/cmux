/// <reference path="../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Shared inbox state: source data, the triage ledger, filters and selection.
// One VM serves every mounted surface (section, status item, pane) and every
// command, so this state is module-level. Reads that subscribe to events are
// created per mount in `attach()` (the runtime ties them to the mount and
// drops them when it unmounts).

import { fetchGithub, type GithubResult } from "./github.ts"
import { t } from "./l10n.ts"
import { emptyLedger, markDone, markSeen, nextWake, parseLedger, prune, snooze, unsnooze, wake, type Ledger } from "./ledger.ts"
import { buildItems, countItems, DEFAULT_FILTERS, filterItems, groupItems, locateTerminals, type Filters, type Location, type ViewItem } from "./model.ts"
import { asVariant, settings, type Variant } from "./settings.ts"

export const clientId = () => `app:${cmux.app.id || "cmux/inbox"}`

/** A readable reason for a failed call. */
export function describe(e: unknown): string {
  const code = e && typeof e === "object" && "code" in e ? String((e as { code: unknown }).code) : ""
  if (code === "scope.missing") return t("reason.scope", "permission not granted")
  if (code === "operation.unsupported") return t("reason.unsupported", "not supported by this version of cmux")
  return e instanceof Error ? e.message : String(e)
}

// Source data (written by every mount's reads, and by commands when nothing is mounted).
const [notifications, setNotifications] = signal<Cmux.NotificationSnapshot[] | null>(null)
const [agents, setAgents] = signal<Cmux.AgentSnapshot[] | null>(null)
const [terminals, setTerminals] = signal<Cmux.TerminalSnapshot[]>([])
const [locations, setLocations] = signal<Map<string, Location>>(new Map())
export const [sourceErrors, setSourceErrors] = signal<{ notification: string | null; agent: string | null }>({ notification: null, agent: null })
type GithubState = GithubResult & { at: number; loading: boolean }
const [github, setGithubSignal] = signal<GithubState>({ status: "idle", items: [], errors: [], at: 0, loading: false })
let githubValue = github()
const setGithub = (next: GithubState) => setGithubSignal((githubValue = next))
export { github }

// Triage state.
const [ledger, setLedgerSignal] = signal<Ledger>(emptyLedger())
let ledgerValue = ledger()
export const [filters, setFiltersSignal] = signal<Filters>(DEFAULT_FILTERS)
const [groupOverride, setGroupOverride] = signal<"source" | "workspace" | null>(null)
export const [selected, setSelected] = signal<string | null>(null)
export const [now, setNow] = signal(Date.now())
export const [notice, setNotice] = signal<string | null>(null)
export const [replyBlocked, setReplyBlocked] = signal(false)
const [variantOverride, setVariantOverride] = signal<{ variant: Variant; base: Variant } | null>(null)

export const items = computed<ViewItem[]>(() => {
  const s = settings()
  const terminalMap = new Map(terminals().map((x) => [x.id, x]))
  return buildItems(
    { agents: agents() ?? [], notifications: notifications() ?? [], terminals: terminalMap, github: github().items, locations: locations() },
    ledger(),
    { clientId: clientId(), includeIdle: s.includeIdleAgents, includeDone: s.includeDoneAgents, maxAgeDays: s.maxAgeDays, now: now() },
    t("agent.fallback", "Agent")
  )
})
export const visible = computed(() => filterItems(items(), filters()))
export const counts = computed(() => countItems(items()))
export const groupBy = computed(() => groupOverride() ?? settings().groupBy)
export const groups = computed(() => groupItems(visible(), groupBy(), t("group.other", "Other")))
export const current = computed(() => visible().find((i) => i.id === selected()) ?? visible()[0] ?? null)
export const loaded = computed(() => notifications() !== null || agents() !== null || sourceErrors().notification !== null || sourceErrors().agent !== null)
export const variant = computed<Variant>(() => {
  const base = settings().variant
  const o = variantOverride()
  return o && o.base === base ? o.variant : base
})

// Storage: one load per VM; every write goes through the loaded value.

let loading: Promise<void> | null = null
const persist = (key: string, value: unknown) => cmux.storage.set(key, value).catch((e: unknown) => cmux.log(`storage ${key}: ${describe(e)}`))

export function ensureLoaded(): Promise<void> {
  loading ??= Promise.all([
    cmux.storage.get("ledger").catch(() => null),
    cmux.storage.get<{ filters?: Partial<Filters>; groupBy?: string }>("view").catch(() => null),
    cmux.storage.get<{ variant?: string; base?: string }>("variantOverride").catch(() => null)
  ]).then(([rawLedger, view, override]) => {
    setLedgerValue(wake(parseLedger(rawLedger), Date.now()).ledger)
    if (view?.filters) setFiltersSignal({ ...DEFAULT_FILTERS, ...view.filters, showSnoozed: false })
    if (view?.groupBy === "source" || view?.groupBy === "workspace") setGroupOverride(view.groupBy)
    if (override?.variant) setVariantOverride({ variant: asVariant(override.variant), base: asVariant(override.base) })
    armWake()
  })
  return loading
}

function setLedgerValue(next: Ledger) {
  ledgerValue = next
  setLedgerSignal(next)
}

export async function updateLedger(change: (l: Ledger) => Ledger): Promise<void> {
  await ensureLoaded()
  const live = new Set(items().map((i) => i.id))
  setLedgerValue(prune(change(ledgerValue), live, Date.now()))
  await persist("ledger", ledgerValue)
}

export function setFilters(change: Partial<Filters>): void {
  const next = { ...filters(), ...change }
  setFiltersSignal(next)
  void persist("view", { filters: { ...next, showSnoozed: false }, groupBy: groupBy() })
}

export function setGrouping(by: "source" | "workspace"): void {
  setGroupOverride(by)
  void persist("view", { filters: { ...filters(), showSnoozed: false }, groupBy: by })
}

// Snooze wake-up: one one-shot timer for the earliest wake, never a poll.

const MAX_DELAY = 2 ** 31 - 1
let wakeTimer: number | null = null

function armWake(): void {
  if (wakeTimer !== null) cmux.timer.clear(wakeTimer)
  wakeTimer = null
  const next = nextWake(ledgerValue, Date.now())
  if (next === null) return
  wakeTimer = cmux.timer.after(Math.min(MAX_DELAY, Math.max(0, next - Date.now())), () => {
    wakeTimer = null
    const result = wake(ledgerValue, Date.now())
    if (result.woke.length) {
      setLedgerValue(result.ledger)
      void persist("ledger", ledgerValue)
    }
    setNow(Date.now())
    armWake()
  })
}

// Per-mount reads.

/** Subscribes the calling mount to notifications, agents and terminals. Call from a render function. */
export function attach(): void {
  void ensureLoaded()
  const n = cmux.live<Cmux.NotificationSnapshot[]>("notification.list", { limit: 256 })
  const a = cmux.live<Cmux.AgentSnapshot[]>("agent.list", {})
  const term = cmux.live<Cmux.TerminalSnapshot[]>("terminal.list", {}, { events: ["terminal.changed", "workspace.changed"] })
  effect(() => {
    const v = n()
    if (v) setNotifications(v)
    setNow(Date.now())
  })
  effect(() => {
    const v = a()
    if (v) setAgents(v)
    setNow(Date.now())
  })
  effect(() => setTerminals(term() ?? []))
  effect(() => {
    const notification = n.error() ? describe(n.error()) : null
    const agent = a.error() ? describe(a.error()) : null
    setSourceErrors({ notification, agent })
  })
}

/**
 * Workspace names for grouping (four reads). Call from a view subtree that
 * exists only while grouping by workspace, so the reads stop with it.
 */
export function attachLayout(): void {
  const ws = cmux.live<Cmux.WorkspaceSnapshot[]>("workspace.list", {})
  const screens = cmux.live<Cmux.ScreenSnapshot[]>("screen.list", {}, { events: ["screen.changed", "workspace.changed"] })
  const panes = cmux.live<Cmux.PaneSnapshot[]>("pane.list", {}, { events: ["pane.changed", "workspace.changed"] })
  const tabs = cmux.live<Cmux.TabSnapshot[]>("tab.list", {}, { events: ["tab.changed", "workspace.changed"] })
  effect(() => setLocations(locateTerminals({ workspaces: ws() ?? [], screens: screens() ?? [], panes: panes() ?? [], tabs: tabs() ?? [], terminals: terminals() })))
}

/** Reads once without subscribing (commands run with no mounted surface). */
export async function ensureData(): Promise<void> {
  await ensureLoaded()
  if (notifications() !== null && agents() !== null) return
  const [n, a, term] = await Promise.allSettled([
    cmux.notification.list({ limit: 256 }),
    cmux.agent.list({}),
    cmux.terminal.list({})
  ])
  setNotifications(n.status === "fulfilled" ? n.value : [])
  setAgents(a.status === "fulfilled" ? a.value : [])
  if (term.status === "fulfilled") setTerminals(term.value)
  setSourceErrors({ notification: n.status === "rejected" ? describe(n.reason) : null, agent: a.status === "rejected" ? describe(a.reason) : null })
  setNow(Date.now())
  await refreshGithub(false)
}

// GitHub through the gateway.

let githubInFlight: Promise<void> | null = null

/** The gateway answers with the response's JSON body; a `{status, body}` envelope is unwrapped too. */
function unwrap(value: unknown): unknown {
  const v = value as { status?: unknown; body?: unknown } | null
  if (v && typeof v.status === "number" && typeof v.body === "string") {
    if (v.status >= 400) throw new Error(`GitHub ${v.status}`)
    return JSON.parse(v.body)
  }
  return value
}

export const githubRequest = (path: string) => cmux.integrations.github.request({ method: "GET", path }).then(unwrap)

/** Refreshes GitHub items unless a recent or refused load makes it pointless; `force` always loads. */
export function refreshGithub(force: boolean): Promise<void> {
  const s = settings().github
  if (!s.enabled) {
    setGithub({ status: "idle", items: [], errors: [], at: Date.now(), loading: false })
    return Promise.resolve()
  }
  const g = githubValue
  const refused = g.status === "notGranted" || g.status === "unavailable"
  if (!force && (refused || Date.now() - g.at < (s.refreshMinutes * 60_000) / 2)) return Promise.resolve()
  if (githubInFlight) return githubInFlight
  setGithub({ ...g, loading: true })
  githubInFlight = fetchGithub(githubRequest, s, Date.now())
    .then(async (r) => {
      setGithub({ ...r, at: Date.now(), loading: false })
      setNow(Date.now())
      if ((r.status === "ok" || r.status === "partial") && !ledgerValue.githubSeeded) {
        await updateLedger((l) => ({ ...markSeen(l, r.items), githubSeeded: true }))
      }
    })
    .finally(() => {
      githubInFlight = null
    })
  return githubInFlight
}

/**
 * Refreshes GitHub on an interval while this mount exists. GitHub has no push
 * channel to apps yet (proposed `integration.changed`), so this is the one
 * repeating timer; the runtime clears it when the mount goes away, and it
 * stops itself when GitHub is not granted or not available.
 */
export function scheduleGithub(): void {
  void refreshGithub(false)
  const id = cmux.timer.every(settings().github.refreshMinutes * 60_000, () => {
    const status = githubValue.status
    if (status === "notGranted" || status === "unavailable" || !settings().github.enabled) cmux.timer.clear(id)
    else void refreshGithub(false)
  })
}

// Variant switching (dogfood only).

export async function cycleVariant(): Promise<Variant> {
  const order: Variant[] = ["grouped", "focus", "card"]
  const next = order[(order.indexOf(variant()) + 1) % order.length]!
  const base = settings().variant
  setVariantOverride({ variant: next, base })
  try {
    // Proposed op: the config layer owns settings; apps cannot write them yet.
    await cmux.call("app.settings.set", { key: "variant", value: next })
  } catch {
    await persist("variantOverride", { variant: next, base })
  }
  return next
}

export function noticeFor(message: string): void {
  setNotice(message)
  cmux.timer.after(6000, () => setNotice(null))
}

export const ledgerSnapshot = () => ledgerValue
export const clearSnooze = (ids: string[]) => updateLedger((l) => unsnooze(l, ids)).then(armWake)
export const snoozeIds = (ids: string[], until: number) => updateLedger((l) => snooze(l, ids, until)).then(armWake)
export const doneIds = (list: ViewItem[]) => updateLedger((l) => markDone(l, list)).then(armWake)
export const terminalTab = (terminal: string) => terminals().find((x) => x.id === terminal)?.tab_id ?? null
