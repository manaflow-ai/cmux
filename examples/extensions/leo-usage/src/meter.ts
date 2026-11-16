// The meter's model: what cmux's usage.meter signal says per provider, the pace of each limit
// window, the demo fixture, and a counter that rolls up to its target once a second.
import { cmux, onCleanup, signal } from "cmux-extension-sdk"

export interface Window { id: string; usedPercent: number; resetsAtMs: number | null }
export interface Provider {
  provider: string
  chats: number
  working: number
  tokens24h: number | null
  costUsd24h: number | null
  calls24h: number | null
  limits: { plan: string | null; windows: Window[] } | null
}
export interface Meter { providers: Provider[]; totals: { tokens24h: number | null; costUsd24h: number | null; working: number } }

export type Pace = { label: string; tone: string; hot: boolean }

const HOUR = 3_600_000
const LENGTH: Record<string, number> = { session: 5 * HOUR, weekly: 168 * HOUR, weekly_opus: 168 * HOUR, weekly_sonnet: 168 * HOUR }
const NAMES: Record<string, string> = { claude: "Claude", codex: "Codex", gemini: "Gemini", opencode: "OpenCode", cursor: "Cursor", amp: "Amp" }

export const nameOf = (provider: string) => NAMES[provider] ?? provider.charAt(0).toUpperCase() + provider.slice(1)
export const windowOf = (p: Provider, id: string) => p.limits?.windows.find((w) => w.id === id) ?? null

/** Used share of the window over elapsed share: above 1 burns faster than the window allows. */
export function pace(w: Window | null, now: number): Pace {
  if (!w) return { label: "no limits", tone: cmux.theme.text.secondary, hot: false }
  if (w.usedPercent >= 85) return { label: w.usedPercent >= 100 ? "at limit" : "near limit", tone: cmux.theme.danger, hot: true }
  const length = LENGTH[w.id]
  if (!length || w.resetsAtMs === null) return { label: `${Math.round(w.usedPercent)}% used`, tone: cmux.theme.text.secondary, hot: false }
  const elapsed = Math.min(1, Math.max(0.02, 1 - (w.resetsAtMs - now) / length))
  const ratio = w.usedPercent / 100 / elapsed
  if (ratio > 1.2) return { label: `over pace ×${ratio.toFixed(1)}`, tone: cmux.theme.warning, hot: ratio > 1.6 }
  if (ratio < 0.8) return { label: "under pace", tone: cmux.theme.success, hot: false }
  return { label: "on pace", tone: cmux.theme.accent, hot: false }
}

export const toneOf = (w: Window | null) =>
  !w ? cmux.theme.separator : w.usedPercent >= 85 ? cmux.theme.danger : w.usedPercent >= 60 ? cmux.theme.warning : cmux.theme.success

export function countdown(at: number | null, now: number): string {
  if (at === null) return "no reset time"
  const min = Math.max(0, Math.round((at - now) / 60_000))
  if (min >= 1440) return `resets in ${Math.floor(min / 1440)}d ${Math.floor((min % 1440) / 60)}h`
  if (min >= 60) return `resets in ${Math.floor(min / 60)}h ${min % 60}m`
  return `resets in ${min}m`
}

export function tokens(n: number | null): string {
  if (n === null) return "–"
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (n >= 1e4) return `${(n / 1e3).toFixed(1)}k`
  return String(Math.round(n))
}
export const dollars = (n: number | null) => (n === null ? "–" : `$${n.toFixed(2)}`)

/** The clock countdowns and paces read. */
export const [now, setNow] = signal(Date.now())

/** Numbers that roll toward their target a third of the way per tick, so a jump reads as a tick-up. */
const counters: Array<{ target: () => number | null; shown: () => number | null; set: (n: number | null) => void }> = []
export function rolling(target: () => number | null): () => number | null {
  const [shown, set] = signal<number | null>(null)
  const c = { target, shown, set }
  counters.push(c)
  onCleanup(() => counters.splice(counters.indexOf(c) >>> 0, 1))
  return shown
}

/** One wake a second while a counter rolls or `fast()` (the demo) says so, else one every 30 s;
 *  the returned `kick` ticks at once (a new reading arrived). */
export function startClock(fast: () => boolean): () => void {
  let timer = 0
  const tick = () => {
    cmux.timer.clear(timer)
    setNow(Date.now())
    let moving = false
    for (const c of counters) {
      const goal = c.target()
      const cur = c.shown()
      if (goal === null || cur === null || Math.abs(goal - cur) < 1) {
        if (cur !== goal) c.set(goal)
        continue
      }
      c.set(cur + (goal - cur) / 3)
      moving = true
    }
    timer = cmux.timer.after(moving || fast() ? 1000 : 30_000, tick)
  }
  tick()
  return tick
}

/** Invented accounts for the gallery and captures: no real labels, ids or emails. */
export function demo(t: number): Meter {
  const s = (t / 1000) % 600
  const wave = (base: number, amp: number, period: number) => base + amp * Math.sin((s / period) * Math.PI * 2)
  const providers: Provider[] = [
    { provider: "claude", chats: 6, working: 3, tokens24h: Math.round(41_200_000 + s * 9_100), costUsd24h: 61.3 + s * 0.013, calls24h: 1_840 + Math.round(s / 2),
      limits: { plan: "max", windows: [{ id: "session", usedPercent: wave(78, 14, 40), resetsAtMs: t + 1.6 * HOUR }, { id: "weekly", usedPercent: 58, resetsAtMs: t + 52 * HOUR }] } },
    { provider: "codex", chats: 3, working: 1, tokens24h: Math.round(18_700_000 + s * 3_300), costUsd24h: 22.8 + s * 0.004, calls24h: 610 + Math.round(s / 5),
      limits: { plan: "pro", windows: [{ id: "session", usedPercent: wave(34, 8, 55), resetsAtMs: t + 3.2 * HOUR }, { id: "weekly", usedPercent: 71, resetsAtMs: t + 20 * HOUR }] } },
    { provider: "gemini", chats: 1, working: 0, tokens24h: null, costUsd24h: null, calls24h: null, limits: null }
  ]
  const sum = (k: "tokens24h" | "costUsd24h") => providers.reduce((a, p) => a + (p[k] ?? 0), 0)
  return { providers, totals: { tokens24h: sum("tokens24h"), costUsd24h: sum("costUsd24h"), working: 4 } }
}
