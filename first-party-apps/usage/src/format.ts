// Text for durations, windows, states and pace, plus the time at which any
// displayed relative text changes next (the app's only timer: one-shot,
// README gap 2).

import { t } from "./l10n.ts"
import type { AccountState, Usage, Window } from "./model.ts"
import type { AccountPace, ProviderPace, Verdict } from "./pace.ts"

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

export const pctText = (p: number | null | undefined) => (p === null || p === undefined ? "—" : `${Math.round(p)}%`)

/** "<1m", "45m", "2h 10m", "3d 4h". Floored, so the text changes on minute (or hour) boundaries. */
export function durationText(ms: number): string {
  if (ms < MINUTE) return t("duration.lessThanMinute", "<1m")
  if (ms < HOUR) return t("duration.minutes", "{m}m", { m: Math.floor(ms / MINUTE) })
  if (ms < DAY) return t("duration.hoursMinutes", "{h}h {m}m", { h: Math.floor(ms / HOUR), m: Math.floor((ms % HOUR) / MINUTE) })
  return t("duration.daysHours", "{d}d {h}h", { d: Math.floor(ms / DAY), h: Math.floor((ms % DAY) / HOUR) })
}

/** The granularity `durationText` shows for a span. */
const unitFor = (ms: number) => (ms < DAY ? MINUTE : HOUR)

const TITLES: Record<string, string> = { claude: "Claude", codex: "Codex" }
/** "Claude", "Codex", else the router's id with a capital first letter. */
export const providerTitle = (id: string) => TITLES[id] ?? id.charAt(0).toUpperCase() + id.slice(1)
const SHORT: Record<string, string> = { claude: "Cl", codex: "Cx" }
/** Two letters for the menu bar ("Cl", "Cx", "Ki"). */
export const providerInitial = (id: string) => SHORT[id] ?? providerTitle(id).slice(0, 2)

export function stateText(s: AccountState): string {
  switch (s) {
    case "active":
      return t("state.active", "in use")
    case "rec":
      return t("state.rec", "next")
    case "ready":
      return t("state.ready", "ready")
    case "protected":
      return t("state.protected", "held")
    case "temp":
      return t("state.temp", "cooling")
    case "cooked":
      return t("state.cooked", "used up")
    case "error":
      return t("state.error", "error")
    default:
      return t("state.unknown", "unknown")
  }
}

/** "78% · 2h 10m": left and time to reset. */
export function windowText(w: Window | null, now: number): string | null {
  if (!w) return null
  const reset = w.resetAt === null ? null : durationText(Math.max(0, w.resetAt - now))
  return reset ? t("window.leftReset", "{left} · {reset}", { left: pctText(w.leftPct), reset }) : pctText(w.leftPct)
}

export const ratioText = (r: number) => `×${r < 10 ? r.toFixed(2) : Math.round(r)}`

export function verdictText(v: ProviderPace["verdict"] | Verdict, metered = true): string {
  switch (v) {
    case "under":
      return t("verdict.under", "under pace")
    case "over":
      return t("verdict.over", "over pace")
    case "onPace":
      return t("verdict.onPace", "on pace")
    case "none":
      return metered ? t("verdict.none", "no headroom") : t("verdict.unmetered", "no weekly limit")
    default:
      return t("verdict.pending", "pace in 30m")
  }
}

/** What to do about it, for the summary line. */
export function adviceText(v: ProviderPace["verdict"]): string | null {
  if (v === "under") return t("advice.under", "raise load")
  if (v === "over") return t("advice.over", "lower load")
  return null
}

const rate = (n: number) => (n < 10 ? n.toFixed(1) : String(Math.round(n)))

/** "on pace ×0.95 · 41%/h of 43%/h · 19 of 22 usable · 1,240% left". */
export function summaryText(p: ProviderPace, withVerdict = true): string {
  if (!p.metered) return t("summary.usable", "{usable} of {total} usable", { usable: p.usable, total: p.total })
  const head = [withVerdict ? verdictText(p.verdict) : null, p.ratio !== null ? ratioText(p.ratio) : null].filter((x): x is string => x !== null).join(" ")
  const parts = head ? [head] : []
  const advice = adviceText(p.verdict)
  if (advice) parts.push(advice)
  if (p.actualPerHour !== null) parts.push(t("summary.burn", "{actual}%/h of {ideal}%/h", { actual: rate(Math.max(0, p.actualPerHour)), ideal: rate(p.idealPerHour) }))
  else if (p.idealPerHour > 0) parts.push(t("summary.ideal", "ideal {ideal}%/h", { ideal: rate(p.idealPerHour) }))
  parts.push(t("summary.usable", "{usable} of {total} usable", { usable: p.usable, total: p.total }))
  return parts.join(" · ")
}


export const accountPaceText = (p: AccountPace | null) => (p ? t("pace.account", "pace {ratio}", { ratio: ratioText(p.ratio) }) : null)

/** Stale when the server says so or the reading is older than `staleMs`. */
export const isStale = (u: Usage, now: number, staleMs: number) => u.stale || (u.fetchedAt !== null && now - u.fetchedAt > staleMs)

export function staleText(u: Usage, now: number): string {
  return u.fetchedAt === null ? t("stale", "Stale") : t("stale.ago", "Stale · updated {duration} ago", { duration: durationText(Math.max(0, now - u.fetchedAt)) })
}

/**
 * The earliest time after `now` at which a displayed relative text changes:
 * a countdown crossing its next floor boundary, an age gaining a unit, or a
 * reading turning stale. Null when nothing on screen depends on the clock.
 */
export function nextTextChange(now: number, input: { countdownsTo: number[]; agesFrom: number[]; staleAt: number[] }): number | null {
  let next = Infinity
  for (const target of input.countdownsTo) {
    const left = target - now
    if (left <= 0) continue
    const unit = unitFor(left)
    next = Math.min(next, now + (left % unit || unit))
  }
  for (const since of input.agesFrom) {
    const age = Math.max(0, now - since)
    const unit = unitFor(age)
    next = Math.min(next, now + (unit - (age % unit)))
  }
  for (const at of input.staleAt) if (at > now) next = Math.min(next, at)
  return Number.isFinite(next) ? next : null
}
