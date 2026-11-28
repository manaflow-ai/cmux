// Building blocks shared by the variants: tones, the meter, per-account text,
// the dropdown menu items, the notice line and the empty/problem states.

import { accountPaceText, pctText, providerInitial, providerTitle, ratioText, staleText, stateText, summaryText, verdictText, windowText } from "../format.ts"
import { t } from "../l10n.ts"
import type { Account, AccountState, Provider } from "../model.ts"
import { sessionPace, weeklyPace, type ProviderPace } from "../pace.ts"
import { now, paceOf, paces, problem, providers, readingAt, stale, state, usage } from "../store.ts"

export interface Actions {
  refresh: () => unknown
  show: () => unknown
}

type Verdict = ProviderPace["verdict"]

/** Tone of a provider's pace; a provider without weekly limits has none. */
export const paceTone = (p: ProviderPace | null): string => (p && p.metered ? verdictTone(p.verdict) : "tertiary")

/** Over pace warns; under pace is wasted headroom (accent); on pace is calm. */
export const verdictTone = (v: Verdict | null): string => {
  switch (v) {
    case "over":
      return "warning"
    case "none":
      return "danger"
    case "under":
      return "accent"
    case "onPace":
      return "success"
    default:
      return "tertiary"
  }
}

export const stateTone = (s: AccountState): string => {
  switch (s) {
    case "active":
      return "success"
    case "rec":
      return "accent"
    case "temp":
      return "warning"
    case "error":
      return "danger"
    case "cooked":
    case "unknown":
      return "tertiary"
    default:
      return "secondary"
  }
}

export const STATE_SYMBOL: Record<AccountState, string> = {
  active: "bolt.fill",
  rec: "arrow.right.circle",
  ready: "circle",
  protected: "lock",
  temp: "hourglass",
  cooked: "flame",
  error: "exclamationmark.triangle",
  unknown: "questionmark.circle"
}

/** The worst verdict across metered providers, for a glyph tint. */
export function worstVerdict(): Verdict | null {
  const order: Verdict[] = ["none", "over", "under", "onPace", "pending"]
  const list = paces().filter((p) => p.metered)
  for (const v of order) if (list.some((p) => p.verdict === v)) return v
  return null
}

/** Metered providers in display order: they are the ones with a pace. */
export const meteredPaces = () => paces().filter((p) => p.metered)

/** "C ×0.92": a provider's initial and burn ratio, or its usable count while the pace waits for a second reading. */
export function paceToken(p: ProviderPace): string {
  const tail = p.ratio !== null ? ratioText(p.ratio) : p.verdict === "none" ? "0" : `${p.usable}/${p.total}`
  return `${providerInitial(p.provider)} ${tail}`
}

/** "Claude · on pace ×0.95 · 19 of 22 usable" for help text and menus. */
export const providerLine = (p: ProviderPace) => `${providerTitle(p.provider)} · ${summaryText(p)}`

export function statusHelp(): string {
  const list = meteredPaces()
  return list.length ? list.map(providerLine).join("\n") : t("menu.noData", "No usage data")
}

/** "5h 78% · 2h 10m · wk 67% · 2d 4h · pace ×0.48". */
export function accountDetail(a: Account, at: number, readAt: number): string {
  const parts: string[] = []
  const session = windowText(a.session, at)
  const weekly = windowText(a.weekly, at)
  if (session) parts.push(t("window.session", "5h {text}", { text: session }))
  if (weekly) parts.push(t("window.weekly", "wk {text}", { text: weekly }))
  const pace = accountPaceText(weeklyPace(a, readAt))
  if (pace) parts.push(pace)
  if (a.extraUsd !== null) parts.push(t("extra", "+${usd} extra", { usd: a.extraUsd < 100 ? a.extraUsd.toFixed(2) : String(Math.round(a.extraUsd)) }))
  if (!session && !weekly && a.plan) parts.push(a.plan)
  return parts.join(" · ")
}

/** Weekly left, the account's headline number ("—" for keyed providers). */
export const accountBadge = (a: Account) => (a.weekly ? pctText(a.weekly.leftPct) : stateText(a.state))

/** Tint of an account's numbers: its state, else its own weekly pace. */
export function accountTone(a: Account, readAt: number): string {
  if (a.state === "error" || a.state === "cooked" || a.state === "temp") return stateTone(a.state)
  const p = weeklyPace(a, readAt)
  return p?.verdict === "over" ? "warning" : "primary"
}

export const sessionShare = (a: Account) => (a.session ? a.session.leftPct / 100 : null)
export const weeklyShare = (a: Account) => (a.weekly ? a.weekly.leftPct / 100 : null)
export { sessionPace }

// Collapsed provider groups in the pane (view state shared by every mount of the app).
const [collapsed, setCollapsed] = signal<Record<string, boolean>>({})
export const isCollapsed = (id: string) => collapsed()[id] === true
export const toggleCollapsed = (id: string) => setCollapsed((c) => ({ ...c, [id]: !c[id] }))

/** Headroom share of a provider: weekly left over its counted accounts' full weeks. */
export const headroomShare = (p: ProviderPace | null) => (p && p.counted > 0 ? Math.min(1, p.leftSumPct / (p.counted * 100)) : 0)

/**
 * A fixed-width bar from rectangles (the renderer has no tinted meter and no
 * container width: README gaps 3 and 4).
 */
export function Meter(value: () => number, width: number, height: number, tone: () => string) {
  const fill = () => ({ width: Math.round(Math.min(1, Math.max(0, value())) * width * 10) / 10, height })
  const rest = () => ({ width: Math.max(0, width - fill().width), height })
  return HStack({ spacing: 0 }, [Rectangle().fill(tone).frame(fill), Rectangle().fill("separator").frame(rest)])
    .frame({ width, height })
    .cornerRadius(height / 2)
}

/** Dropdown entries for the status item: one line per provider, then actions. */
export function menuItems(actions: Actions) {
  const items: ReturnType<typeof Button>[] = []
  const list = paces()
  if (state() !== "ready" || list.length === 0) items.push(Button(problemTitle()).disabled())
  const u = usage()
  if (u && stale()) items.push(Button(staleText(u, now())).disabled())
  for (const p of list) items.push(Button(providerLine(p)).disabled())
  items.push(Divider(), Button(t("menu.refresh", "Refresh Now"), actions.refresh), Button(t("menu.show", "Show Usage"), actions.show))
  return items
}

export function problemTitle(): string {
  switch (state()) {
    case "loading":
      return t("loading", "Loading…")
    case "unavailable":
      return t("unavailable.title", "Usage server not available")
    case "denied":
      return t("scope.title", "No permission to read usage")
    case "error":
      return t("error.title", "Cannot read usage")
    default:
      return providers().length ? "" : t("empty.title", "No accounts found")
  }
}

type ProblemSpec = { loading: true } | { title: string; message: string; symbol: string } | null

/** What to show when there is nothing to list, as a string so the view rebuilds only when it changes. */
const problemSpec = computed(() => {
  const s = state()
  let spec: ProblemSpec = null
  if (s === "loading") spec = { loading: true }
  else if (!(s === "ready" && providers().length > 0)) {
    const p = problem()
    const message =
      s === "unavailable"
        ? t("unavailable.message", "This build has no usage server ({op}) yet.", { op: "account.list" })
        : s === "denied"
          ? t("scope.message", "Allow {scope} in Settings > Apps > Usage.", { scope: p?.scope ?? "account:read" })
          : s === "error"
            ? (p?.message ?? "")
            : t("empty.message", "Add accounts to your router (sr add) and cmux shows their usage here.")
    const symbol = s === "ready" ? "gauge.with.dots.needle.0percent" : s === "denied" ? "lock" : "exclamationmark.triangle"
    spec = { title: problemTitle(), message, symbol }
  }
  return JSON.stringify(spec)
})

/** A dynamic child: the loading row or an EmptyState, or nothing when there are providers to list. */
export function ProblemView() {
  const spec = JSON.parse(problemSpec()) as ProblemSpec
  if (!spec) return null
  if ("loading" in spec) return HStack({ spacing: 6 }, [ProgressView(), Text(t("loading", "Loading…")).secondary()]).padding(8)
  return EmptyState(spec)
}

/** The reading's trouble: the server's last error, else staleness, else "". */
export function noticeText(): string {
  const u = usage()
  if (!u || state() !== "ready") return ""
  const parts: string[] = []
  if (u.error) parts.push(u.error.message || u.error.code)
  for (const s of u.sources) if (s.error) parts.push(`${s.id}: ${s.error.message || s.error.code}`)
  if (stale()) parts.push(staleText(u, now()))
  return parts.join(" · ")
}

/** A notice line that exists only while there is a notice; it rebuilds when the notice appears or goes. */
export function NoticeLine(font: string) {
  const has = computed(() => noticeText() !== "")
  return () =>
    has()
      ? HStack({ spacing: 4 }, [
          Icon("exclamationmark.triangle").size(10).color("warning"),
          Text(noticeText).font(font).color("warning").lineLimit(2)
        ]).padding({ top: 4, leading: 12, bottom: 4, trailing: 12 })
      : null
}

/** Providers with a stable signal per item for ForEach templates. */
export const providerList = () => providers()
export const paceFor = (p: Provider) => paceOf(p.id)
export const verdictLabel = (p: ProviderPace | null) => (p ? verdictText(p.verdict, p.metered) : "")
export { readingAt }
