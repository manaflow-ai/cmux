// Text for windows, durations and pace, plus the time at which any displayed
// relative text changes next (the app's only timer: one-shot, README gap 2).

import { t } from "./l10n.ts"
import type { UsageAccount, UsageWindow } from "./model.ts"
import type { Pace } from "./pace.ts"

const MINUTE = 60_000
const HOUR = 60 * MINUTE
const DAY = 24 * HOUR

export const percentText = (p: number | null) => (p === null ? "—" : `${Math.round(p)}%`)

/** "<1m", "45m", "2h 10m", "3d 4h". Minutes are floored, so the text changes on minute (or hour) boundaries. */
export function durationText(ms: number): string {
  if (ms < MINUTE) return t("duration.lessThanMinute", "<1m")
  if (ms < HOUR) return t("duration.minutes", "{m}m", { m: Math.floor(ms / MINUTE) })
  if (ms < DAY) return t("duration.hoursMinutes", "{h}h {m}m", { h: Math.floor(ms / HOUR), m: Math.floor((ms % HOUR) / MINUTE) })
  return t("duration.daysHours", "{d}d {h}h", { d: Math.floor(ms / DAY), h: Math.floor((ms % DAY) / HOUR) })
}

/** The granularity `durationText` shows for a remaining or elapsed span. */
const unitFor = (ms: number) => (ms < DAY ? MINUTE : HOUR)

export function windowLabel(w: UsageWindow): string {
  switch (w.kind) {
    case "session":
      return w.windowSeconds && w.windowSeconds % 3600 === 0
        ? t("window.session.hours", "{hours}-hour", { hours: w.windowSeconds / 3600 })
        : t("window.session", "Session")
    case "weekly":
      return w.scope ? t("window.weekly.scoped", "{scope} weekly", { scope: w.scope }) : t("window.weekly", "Weekly")
    case "monthly":
      return t("window.monthly", "Monthly")
    case "daily":
      return t("window.daily", "Daily")
    case "budget":
      return t("window.budget", "Budget")
    case "credits":
      return t("window.credits", "Credits")
    default:
      return w.label ?? w.id
  }
}

export function resetText(w: UsageWindow, now: number): string | null {
  if (w.resetsAt === null) return null
  const left = w.resetsAt - now
  return left <= 0 ? t("reset.now", "resets soon") : t("reset.in", "resets in {duration}", { duration: durationText(left) })
}

/** Spend windows: "$42 / $100". */
export function amountText(w: UsageWindow): string | null {
  if (w.used === null || w.limit === null) return null
  const fmt = (n: number) => (w.unit === "usd" ? `$${n >= 100 ? Math.round(n) : n.toFixed(2)}` : `${Math.round(n)}`)
  return t("spend.ofLimit", "{used} / {limit}", { used: fmt(w.used), limit: fmt(w.limit) })
}

/** Only says something when it matters: a run-out before the reset, or a clear lead or lag. */
export function paceText(p: Pace | null, now: number): string | null {
  if (!p) return null
  if (p.runsOutAt !== null) return t("pace.runsOut", "runs out in {duration}", { duration: durationText(Math.max(0, p.runsOutAt - now)) })
  if (p.stage === "over") return t("pace.over", "{delta}% ahead of pace", { delta: Math.round(p.deltaPercent) })
  return null
}

/** Stale when the owner says so or the reading is older than `staleMs`. */
export const isStale = (a: UsageAccount, now: number, staleMs: number) => a.stale || (a.fetchedAt !== null && now - a.fetchedAt > staleMs)

export function staleText(a: UsageAccount, now: number): string {
  return a.fetchedAt === null ? t("stale", "Stale") : t("stale.ago", "Stale · updated {duration} ago", { duration: durationText(Math.max(0, now - a.fetchedAt)) })
}

/**
 * The earliest time after `now` at which a displayed relative text changes:
 * a countdown (reset, run-out) crossing its next floor boundary, an age
 * ("updated 12m ago") gaining a unit, or a reading turning stale. Null when
 * nothing on screen depends on the clock, so no timer is armed.
 */
export function nextTextChange(now: number, input: { countdownsTo: number[]; agesFrom: number[]; staleAt: number[] }): number | null {
  let next = Infinity
  for (const target of input.countdownsTo) {
    const left = target - now
    if (left <= 0) continue
    const unit = unitFor(left)
    const step = left % unit || unit
    next = Math.min(next, now + step)
  }
  for (const since of input.agesFrom) {
    const age = Math.max(0, now - since)
    const unit = unitFor(age)
    next = Math.min(next, now + (unit - (age % unit)))
  }
  for (const at of input.staleAt) if (at > now) next = Math.min(next, at)
  return Number.isFinite(next) ? next : null
}
