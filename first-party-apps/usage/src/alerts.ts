// Threshold warnings, once per window: pure planning; the store sends the
// notifications and persists `Fired` in cmux.storage.
//
// A window warns when its percent crosses a higher threshold than the one it
// already warned for. It re-arms when its reset time passes or when its
// percent falls below the lowest threshold (a reset the service reported
// late, or a budget that was raised). The key is account + window id, not the
// reset time, because some providers move the reported reset by seconds
// between reads.

import { percentOf, type UsageAccount, type UsageWindow } from "./model.ts"

export interface FiredEntry {
  level: number
  resetsAt: number | null
}
export type Fired = Record<string, FiredEntry>

export interface Alert {
  key: string
  level: number
  /** The highest configured threshold (sent as an error-level notification). */
  top: boolean
  percent: number
  account: UsageAccount
  window: UsageWindow
}

export const DEFAULT_THRESHOLDS: readonly number[] = [80, 95]

export const alertKey = (account: UsageAccount, window: UsageWindow) => `${account.id}|${window.id}`

/** Valid thresholds: integers 1 to 100, deduplicated, ascending. */
export function cleanThresholds(raw: unknown): number[] {
  const list = Array.isArray(raw) ? raw : DEFAULT_THRESHOLDS
  const nums = list.map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= 100)
  return [...new Set(nums)].sort((a, b) => a - b)
}

/**
 * Returns the alerts to send now and the next `Fired` state. Stale and failed
 * accounts never warn (an old number is not news) and keep their entries.
 */
export function planAlerts(accounts: readonly UsageAccount[], thresholds: readonly number[], fired: Fired, now: number, staleMs: number): { alerts: Alert[]; fired: Fired } {
  const next: Fired = {}
  const alerts: Alert[] = []
  const lowest = thresholds[0]
  const live = new Set<string>()
  for (const account of accounts) {
    const unusable = account.error !== null || account.stale || (account.fetchedAt !== null && now - account.fetchedAt > staleMs)
    for (const window of account.windows) {
      const key = alertKey(account, window)
      live.add(key)
      const previous = fired[key]
      if (unusable) {
        if (previous) next[key] = previous
        continue
      }
      const percent = percentOf(window)
      const rearm = !previous || (previous.resetsAt !== null && previous.resetsAt <= now) || (percent !== null && lowest !== undefined && percent < lowest)
      const already = rearm ? 0 : previous.level
      const crossed = percent === null ? 0 : Math.max(0, ...thresholds.filter((th) => percent >= th))
      if (crossed > already) {
        alerts.push({ key, level: crossed, top: crossed === thresholds[thresholds.length - 1], percent: percent!, account, window })
        next[key] = { level: crossed, resetsAt: window.resetsAt }
      } else if (already > 0) {
        next[key] = { level: already, resetsAt: window.resetsAt ?? previous!.resetsAt }
      }
    }
  }
  // Entries of accounts that disappeared from this read are kept until their reset passes,
  // so an account that comes back mid-window does not warn twice.
  for (const [key, entry] of Object.entries(fired)) {
    if (!live.has(key) && entry.resetsAt !== null && entry.resetsAt > now) next[key] = entry
  }
  return { alerts, fired: next }
}
