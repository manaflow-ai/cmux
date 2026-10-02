// Building blocks shared by the variants: tones, the meter, per-window text,
// the dropdown menu items and the empty/problem states.

import { amountText, isStale, paceText, percentText, resetText, staleText, windowLabel } from "../format.ts"
import { t } from "../l10n.ts"
import { percentOf, severityOf, tightest, type Severity, type UsageAccount, type UsageWindow } from "../model.ts"
import { paceOf } from "../pace.ts"
import { allAccounts, now, problem, staleMs, state, thresholds } from "../store.ts"

type Read<T> = () => T

/** Fill color for bars and glyphs. */
export const toneOf = (s: Severity) => (s === "danger" ? "danger" : s === "warning" ? "warning" : "secondary")
/** Text color: calm numbers read as primary text. */
export const textTone = (s: Severity) => (s === "normal" ? "primary" : toneOf(s))

/** Color follows the warning thresholds only; pace is said in words ("runs out in 40m") so early-window noise does not paint everything yellow. */
export const severity = (w: UsageWindow, _at: number) => severityOf(percentOf(w), thresholds())

export const accountStale = (a: UsageAccount) => isStale(a, now(), staleMs())

/** "Claude Code · Personal · Max 20x" (absent parts dropped). */
export const accountTitle = (a: UsageAccount) => [a.providerTitle, a.label, a.plan].filter(Boolean).join(" · ")

/** The account's trouble line: its error, else its staleness, else "". */
export const accountNote = (a: UsageAccount) => (a.error ? a.error.message : accountStale(a) ? staleText(a, now()) : "")

/**
 * A line under an account header that exists only while there is a note. The
 * dynamic child depends on a boolean, so it rebuilds when the note appears or
 * goes, not on every read or clock tick; the text itself is a live prop.
 */
export function NoteLine(a: () => UsageAccount, font: string) {
  const has = computed(() => accountNote(a()) !== "")
  return () =>
    has()
      ? Text(() => accountNote(a()))
          .font(font)
          .color(() => (a().error ? "warning" : "tertiary"))
          .lineLimit(2)
      : null
}

/** "resets in 2h 10m · runs out in 40m" or "$42 / $100". */
export function windowDetail(w: UsageWindow, at: number): string {
  const parts = [amountText(w), resetText(w, at), paceText(paceOf(w, at), at)].filter((p): p is string => !!p)
  return parts.join(" · ")
}

/** The window the status item shows: the most used one. */
export const top = () => tightest(allAccounts())

/**
 * A fixed-width bar: used share filled, the rest as track, and a 1 pt tick
 * where a steady pace would be. Built from rectangles because the renderer
 * has no meter node and no container width (README gaps 3 and 4).
 */
export function Meter(window: Read<UsageWindow | null>, width: number, height: number, withPace: boolean) {
  const used = () => {
    const w = window()
    const p = w ? percentOf(w) : null
    return p === null ? 0 : Math.min(100, p) / 100
  }
  const tick = () => {
    const w = window()
    if (!withPace || !w) return null
    const p = paceOf(w, now())
    return p ? Math.min(1, Math.max(0, p.expectedPercent / 100)) : null
  }
  const tone = () => {
    const w = window()
    return w ? toneOf(severity(w, now())) : "tertiary"
  }
  // Left to right: fill up to min(used, pace), track up to the pace, the pace tick,
  // fill beyond the pace, track. Without a pace only the first and last are non-zero.
  const seg = (fn: () => number) => () => ({ width: Math.max(0, Math.round(fn() * 10) / 10), height })
  const usable = width - 1
  const u = () => used() * usable
  const k = () => (tick() === null ? null : tick()! * usable)
  const fillBefore = () => (k() === null ? u() : Math.min(u(), k()!))
  const trackBefore = () => (k() === null ? 0 : Math.max(0, k()! - u()))
  const fillAfter = () => (k() === null ? 0 : Math.max(0, u() - k()!))
  const tickW = () => (k() === null ? 0 : 1)
  const rest = () => width - fillBefore() - trackBefore() - tickW() - fillAfter()
  return HStack({ spacing: 0 }, [
    Rectangle().fill(tone).frame(seg(fillBefore)),
    Rectangle().fill("separator").frame(seg(trackBefore)),
    Rectangle().fill("primary").frame(seg(tickW)),
    Rectangle().fill(tone).frame(seg(fillAfter)),
    Rectangle().fill("separator").frame(seg(rest))
  ])
    .frame({ width, height })
    .cornerRadius(height / 2)
}

/** Dropdown entries for the status item: every account and window, then actions. */
export function menuItems(actions: { refresh: () => unknown; show: () => unknown }) {
  const at = now()
  const items: ReturnType<typeof Button>[] = []
  const accounts = allAccounts()
  if (state() !== "ready" || accounts.length === 0) items.push(Button(problemTitle()).disabled())
  for (const a of accounts) {
    if (items.length) items.push(Divider())
    items.push(Button(accountStale(a) ? `${accountTitle(a)} · ${staleText(a, at)}` : accountTitle(a)).disabled())
    if (a.error) items.push(Button(a.error.message).disabled())
    for (const w of a.windows) {
      const detail = windowDetail(w, at)
      items.push(Button(`${windowLabel(w)}  ${percentText(percentOf(w))}${detail ? `  ${detail}` : ""}`).disabled())
    }
  }
  items.push(Divider(), Button(t("menu.refresh", "Refresh Now"), actions.refresh), Button(t("menu.show", "Show Usage"), actions.show))
  return items
}

export function problemTitle(): string {
  switch (state()) {
    case "loading":
      return t("loading", "Loading…")
    case "unavailable":
      return t("unavailable.title", "Usage service not available")
    case "denied":
      return t("scope.title", "No permission to read usage")
    case "error":
      return t("error.title", "Cannot read usage")
    default:
      return allAccounts().length ? "" : t("empty.title", "No plans found")
  }
}

type ProblemSpec = { loading: true } | { title: string; message: string; symbol: string } | null

/** What to show when there is nothing to list, as a string so the view rebuilds only when it changes. */
const problemSpec = computed(() => {
  const s = state()
  let spec: ProblemSpec = null
  if (s === "loading") spec = { loading: true }
  else if (!(s === "ready" && allAccounts().length > 0)) {
    const p = problem()
    const message =
      s === "unavailable"
        ? t("unavailable.message", "This build has no usage service ({op}) yet.", { op: "usage.get" })
        : s === "denied"
          ? t("scope.message", "Allow {scope} in Settings > Apps > Usage.", { scope: p?.scope ?? "usage:read" })
          : s === "error"
            ? (p?.message ?? "")
            : t("empty.message", "Sign in to Claude Code or Codex in a terminal and cmux shows their usage here.")
    const symbol = s === "ready" ? "gauge.with.dots.needle.0percent" : s === "denied" ? "lock" : "exclamationmark.triangle"
    spec = { title: problemTitle(), message, symbol }
  }
  return JSON.stringify(spec)
})

/** A dynamic child: the loading row or an EmptyState, or nothing when there are accounts to list. */
export function ProblemView() {
  const spec = JSON.parse(problemSpec()) as ProblemSpec
  if (!spec) return null
  if ("loading" in spec) return HStack({ spacing: 6 }, [ProgressView(), Text(t("loading", "Loading…")).secondary()]).padding(8)
  return EmptyState(spec)
}

export const percentLabel = (w: UsageWindow) => percentText(percentOf(w))
