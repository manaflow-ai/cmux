// Pace: does the user burn the weekly headroom at the rate that uses all of
// it exactly by each account's reset? Pure.
//
// Per provider:
// - Accounts in state "error" do not count.
// - Ideal burn (percent per hour) = the sum over accounts of
//   weekly_left_pct / hours to that account's weekly reset.
// - Actual burn = the drop of weekly_left_pct between two readings at least
//   30 minutes apart, per hour. Accounts are matched by id. An account whose
//   weekly reset moved between the readings (its window reset) or that is in
//   only one reading is left out, so a reset does not count as negative burn.
// - Verdict: UNDER when actual / ideal < 0.8 (raise the load), OVER when it is
//   > 1.2 (lower it), else ON PACE.
// - Usable accounts: state not cooked or temp (and not error).
//
// Per account: the share of the window used against the share of the window
// that has passed (same bands), so each row says whether that account alone
// runs ahead of its own reset.

import { isUsable, type Account, type Provider, type Snapshot } from "./model.ts"

export const HOUR = 3_600_000
/** Minimum distance between the two readings of the actual burn. */
export const MIN_BASELINE_MS = 30 * 60_000
export const UNDER_BELOW = 0.8
export const OVER_ABOVE = 1.2
export const SESSION_MS = 5 * HOUR
export const WEEK_MS = 7 * 24 * HOUR
/** Share of a window that must have passed before an account pace is shown. */
export const MIN_ELAPSED_SHARE = 0.05
/** A weekly reset that moved by more than this between two readings means the window reset. */
const RESET_MOVED_MS = HOUR

export type Verdict = "under" | "onPace" | "over"

export const verdictOf = (ratio: number): Verdict => (ratio < UNDER_BELOW ? "under" : ratio > OVER_ABOVE ? "over" : "onPace")

export interface ProviderPace {
  provider: string
  /** All accounts, errors included. */
  total: number
  /** Accounts that count (state not error). */
  counted: number
  /** Accounts not cooked, temp or error. */
  usable: number
  /** Some counted account has a weekly window (keyed providers have none). */
  metered: boolean
  /** Sum of weekly_left_pct over counted accounts. */
  leftSumPct: number
  /** Percent per hour that uses every counted account's headroom exactly by its reset. */
  idealPerHour: number
  /** Percent per hour since the baseline; null until a baseline exists. */
  actualPerHour: number | null
  /** actual / ideal; null without a baseline or without headroom. */
  ratio: number | null
  /** "pending": no reading 30 minutes older yet. "none": no headroom left to pace. */
  verdict: Verdict | "pending" | "none"
  /** Epoch ms of the baseline reading. */
  baselineAt: number | null
}

const counted = (accounts: readonly Account[]) => accounts.filter((a) => a.state !== "error")

export function idealPerHour(accounts: readonly Account[], now: number): number {
  let ideal = 0
  for (const a of counted(accounts)) {
    const r = a.weekly?.resetAt ?? null
    if (a.weekly && r !== null && r > now) ideal += a.weekly.leftPct / ((r - now) / HOUR)
  }
  return ideal
}

/** The newest snapshot taken at least `MIN_BASELINE_MS` before `now`. */
export function pickBaseline(history: readonly Snapshot[], now: number): Snapshot | null {
  let best: Snapshot | null = null
  for (const s of history) if (now - s.at >= MIN_BASELINE_MS && (!best || s.at > best.at)) best = s
  return best
}

/** Percent per hour burned by `provider`'s accounts between `baseline` and `current`. */
export function actualPerHour(provider: string, baseline: Snapshot, current: Snapshot): number | null {
  const hours = (current.at - baseline.at) / HOUR
  if (hours <= 0) return null
  let drop = 0
  let matched = 0
  for (const [key, now] of current.accounts) {
    if (now.provider !== provider || now.state === "error" || now.weeklyLeftPct === null) continue
    const before = baseline.accounts.get(key)
    if (!before || before.weeklyLeftPct === null) continue
    const moved = before.weeklyResetAt !== null && now.weeklyResetAt !== null && Math.abs(now.weeklyResetAt - before.weeklyResetAt) > RESET_MOVED_MS
    const passed = before.weeklyResetAt !== null && before.weeklyResetAt <= current.at
    if (moved || passed) continue
    drop += before.weeklyLeftPct - now.weeklyLeftPct
    matched++
  }
  return matched === 0 ? null : drop / hours
}

export function providerPace(provider: Provider, current: Snapshot, baseline: Snapshot | null): ProviderPace {
  const accounts = counted(provider.accounts)
  const ideal = idealPerHour(provider.accounts, current.at)
  const actual = baseline ? actualPerHour(provider.id, baseline, current) : null
  const ratio = actual !== null && ideal > 0 ? actual / ideal : null
  return {
    provider: provider.id,
    total: provider.accounts.length,
    counted: accounts.length,
    usable: accounts.filter((a) => isUsable(a.state)).length,
    metered: accounts.some((a) => a.weekly !== null),
    leftSumPct: accounts.reduce((sum, a) => sum + (a.weekly?.leftPct ?? 0), 0),
    idealPerHour: ideal,
    actualPerHour: actual,
    ratio,
    verdict: ideal <= 0 ? "none" : ratio === null ? "pending" : verdictOf(ratio),
    baselineAt: actual === null ? null : (baseline?.at ?? null)
  }
}

export interface AccountPace {
  /** used share / elapsed share of the window. */
  ratio: number
  verdict: Verdict
  /** Percent a steady user would still have left now. */
  expectedLeftPct: number
}

/** Pace of one window of one account; null early in the window or without a reset. */
export function windowPace(w: { leftPct: number; resetAt: number | null } | null, lengthMs: number, now: number): AccountPace | null {
  if (!w || w.resetAt === null) return null
  const left = w.resetAt - now
  if (left <= 0 || left > lengthMs) return null
  const elapsedShare = 1 - left / lengthMs
  if (elapsedShare < MIN_ELAPSED_SHARE) return null
  const ratio = (100 - w.leftPct) / 100 / elapsedShare
  return { ratio, verdict: verdictOf(ratio), expectedLeftPct: (left / lengthMs) * 100 }
}

export const weeklyPace = (a: Account, now: number) => windowPace(a.weekly, WEEK_MS, now)
export const sessionPace = (a: Account, now: number) => windowPace(a.session, SESSION_MS, now)
