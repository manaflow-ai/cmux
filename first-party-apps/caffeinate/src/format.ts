// Text for time left and assertion titles, and the moment the next displayed
// countdown changes (the app's only timer is one-shot at that moment).

import { kindsText } from "./kinds.ts"
import { t } from "./l10n.ts"
import type { Assertion, ReleaseCause } from "./model.ts"

const SECOND = 1000
const MINUTE = 60 * SECOND
const HOUR = 60 * MINUTE

/**
 * "45s", "42m", "1h 5m", "2h". Rounded up, so "For 1 hour" starts at "1h" and
 * the text reaches "0s" only when the time is up. Seconds only in the last minute.
 */
export function timeLeftText(ms: number): string {
  if (ms <= 0) return t("time.seconds", "{s}s", { s: 0 })
  if (ms <= MINUTE) return t("time.seconds", "{s}s", { s: Math.ceil(ms / SECOND) })
  const minutes = Math.ceil(ms / MINUTE)
  if (minutes < 60) return t("time.minutes", "{m}m", { m: minutes })
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return m === 0 ? t("time.hours", "{h}h", { h }) : t("time.hoursMinutes", "{h}h {m}m", { h, m })
}

/** The first moment after `now` at which `timeLeftText(end - now)` changes, or null when it never does. */
export function nextChangeFor(end: number, now: number): number | null {
  const ms = end - now
  if (ms <= 0) return null
  if (ms <= MINUTE) {
    const s = Math.ceil(ms / SECOND)
    return end - (s - 1) * SECOND
  }
  const minutes = Math.ceil(ms / MINUTE)
  return end - (minutes - 1) * MINUTE
}

/** The soonest text change over every end time, or null. */
export function nextTextChange(ends: readonly number[], now: number): number | null {
  let best: number | null = null
  for (const end of ends) {
    const at = nextChangeFor(end, now)
    if (at !== null && (best === null || at < best)) best = at
  }
  return best
}

/** "15 minutes", "1 hour", "1 hour 30 minutes": a chosen duration. */
export function durationWords(totalMinutes: number): string {
  const h = Math.floor(totalMinutes / 60)
  const m = totalMinutes % 60
  if (h === 0) return m === 1 ? t("words.minute", "1 minute") : t("words.minutes", "{m} minutes", { m })
  const hours = h === 1 ? t("words.hour", "1 hour") : t("words.hours", "{h} hours", { h })
  if (m === 0) return hours
  return t("words.hoursMinutes", "{hours} {minutes}", { hours, minutes: m === 1 ? t("words.minute", "1 minute") : t("words.minutes", "{m} minutes", { m }) })
}

/** "For 1 hour", "Until stopped", "While cargo · api runs", "While process 4242 runs". */
export function assertionTitle(a: Assertion): string {
  if (a.until) {
    const what = a.untilLabel ?? (a.until.pid ? t("until.pid", "process {pid}", { pid: a.until.pid }) : a.until.task ? t("until.task", "the task") : t("until.terminal", "the command"))
    return t("title.while", "While {what} runs", { what })
  }
  if (a.expiresAt !== null) {
    const minutes = Math.max(1, Math.round((a.expiresAt - a.createdAt) / MINUTE))
    return t("title.for", "For {duration}", { duration: durationWords(minutes) })
  }
  return t("title.untilStopped", "Until stopped")
}

/** "Display, Mac · 42m left", plus kinds paused on battery and who started it. */
export function assertionDetail(a: Assertion, now: number, withTime = true): string {
  const parts = [kindsText(a.kinds)]
  if (withTime && a.expiresAt !== null) parts.push(t("time.left", "{time} left", { time: timeLeftText(a.expiresAt - now) }))
  if (a.inactive.length) parts.push(t("detail.inactive", "{kinds} paused on battery", { kinds: kindsText(a.inactive) }))
  if (a.owner.app && a.owner.app !== "cmux/caffeinate") parts.push(t("detail.byApp", "by {app}", { app: a.owner.app }))
  else if (a.owner.origin === "agent") parts.push(t("detail.byAgent", "by an agent"))
  return parts.join(" · ")
}

export function releaseText(cause: ReleaseCause, title: string): string {
  switch (cause) {
    case "timeout":
      return t("release.timeout", "Time is up: {title}", { title })
    case "until":
      return t("release.until", "Finished: {title}", { title })
    case "owner_disabled":
    case "owner_uninstalled":
      return t("release.owner", "Stopped because its app was turned off: {title}", { title })
    case "host_restart":
      return t("release.restart", "Stopped when cmux restarted: {title}", { title })
    default:
      return t("release.other", "Stopped: {title}", { title })
  }
}
