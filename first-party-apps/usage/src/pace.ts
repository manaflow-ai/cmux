// Pace: is a window being used faster than its time passes? Pure.
//
// Linear model: at a steady rate the window would be `elapsed / length` used.
// The projected run-out time extrapolates the average rate since the window
// started. Early in a window that average is noise, so no run-out is predicted
// until a minimum share of the window has passed.

import { percentOf, type UsageWindow } from "./model.ts"

export interface Pace {
  /** Percent a steady user would have used by now. */
  expectedPercent: number
  /** used minus expected, in percentage points. */
  deltaPercent: number
  /** When the limit is reached at the current average rate, if before the reset. */
  runsOutAt: number | null
  /** The current average rate lasts until the reset. */
  lastsToReset: boolean
  stage: "under" | "onTrack" | "over"
}

/** Share of a window that must have passed before a run-out is predicted. */
export const MIN_ELAPSED_SHARE = 0.05
/** Points of difference that still count as on track. */
export const ON_TRACK_POINTS = 5

export function paceOf(window: UsageWindow, now: number): Pace | null {
  const used = percentOf(window)
  if (used === null || window.windowSeconds === null || window.resetsAt === null) return null
  const length = window.windowSeconds * 1000
  const left = window.resetsAt - now
  if (length <= 0 || left <= 0 || left > length) return null
  const elapsed = length - left
  const expected = (elapsed / length) * 100
  const delta = used - expected
  const stage = Math.abs(delta) <= ON_TRACK_POINTS ? "onTrack" : delta > 0 ? "over" : "under"
  let runsOutAt: number | null = null
  let lastsToReset = true
  if (used >= 100) {
    runsOutAt = now
    lastsToReset = false
  } else if (used > 0 && elapsed >= length * MIN_ELAPSED_SHARE) {
    const msToLimit = ((100 - used) / used) * elapsed
    if (msToLimit < left) {
      runsOutAt = now + msToLimit
      lastsToReset = false
    }
  }
  return { expectedPercent: expected, deltaPercent: delta, runsOutAt, lastsToReset, stage }
}
