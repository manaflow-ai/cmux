// Usage meter: every provider your agents spend (Claude, Codex, ...) as live rings, a ticking token
// and dollar counter, a pace badge that pulses near a limit, and reset countdowns. It imports
// nothing but the public SDK.
// - cmux.watch("usage.meter") is pushed by chat.changed: tokens and list-price dollars of the last
//   24 hours and each account's 5-hour and weekly windows, as Claude Code and Codex recorded them.
// - The motion (.animation, .trim, .loop, .glow, Particles) is declared here and run by cmux's
//   renderer; this code never ticks a frame.
// - Settings > Apps > Usage meter: `variant` (rings, bars, neon) and `source` (live or demo).

import {
  Badge, Capsule, Circle, cmux, computed, effect, EmptyState, ForEach, HStack, Icon, pane, Panel, Particles, section, untrack,
  Spacer, Text, VStack, ZStack, type View
} from "cmux-extension-sdk"
import { countdown, demo, dollars, type Meter, nameOf, now, pace, type Provider, rolling, startClock, tokens, toneOf, type Window, windowOf } from "./meter.ts"

type Variant = "rings" | "bars" | "neon"
const setting = (k: string) => String(cmux.app.settings()[k] ?? "")
const variant = computed<Variant>(() => (["rings", "bars", "neon"].includes(setting("variant")) ? setting("variant") : "rings") as Variant)
const isDemo = computed(() => setting("source") === "demo")
const kick = startClock(() => isDemo())

/** The meter: the live signal, or the demo fixture moving with the clock. */
function useMeter() {
  const live = cmux.watch("usage.meter")
  const meter = computed<Meter | null>(() => (isDemo() ? demo(now()) : (live.value() as Meter | undefined) ?? null))
  const problem = computed(() => (isDemo() ? null : live.status() === "error" ? live.error()?.message ?? "Usage is not available" : null))
  // The 24-hour totals as shown: they roll up a third of the way each second toward each reading.
  const shown = { tokens: rolling(() => meter()?.totals.tokens24h ?? null), cost: rolling(() => meter()?.totals.costUsd24h ?? null) }
  effect(() => {
    // Settings arrive after the module loads, so the clock started at load runs at the slow rate:
    // a mount (or a switch to demo) starts the demo's 1 s ticks, a new live reading starts the
    // counters rolling now.
    if (!isDemo()) meter()
    untrack(kick)
  })
  return { meter, problem, shown, providers: () => meter()?.providers ?? [] }
}

const pct = (w: Window | null) => Math.min(1, Math.max(0, (w?.usedPercent ?? 0) / 100))
const glowing = (w: () => Window | null) => () => (variant() === "neon" ? { color: toneOf(w()), radius: 8, opacity: 0.8 } : null)

/** One limit window as a ring that fills clockwise from 12 o'clock and springs to each new value. */
function ring(w: () => Window | null, size: number, width: number): View {
  const frame = { width: size, height: size }
  return ZStack([
    Circle().stroke(cmux.theme.separator).strokeWidth(width).frame(frame),
    Circle().stroke(() => toneOf(w())).strokeWidth(width).frame(frame)
      .trim(() => ({ to: pct(w()) })).glow(glowing(w)).animation("snappy")
  ])
}

/** The 5-hour window outside, the week inside, the session percent in the middle. */
function rings(p: () => Provider, size: number): View {
  const session = () => windowOf(p(), "session")
  const weekly = () => windowOf(p(), "weekly")
  const width = Math.max(3, Math.round(size / 10))
  return ZStack([
    ring(session, size, width),
    ring(weekly, size - 2 * (width + 3), width),
    Text(() => (session() ? `${Math.round(session()!.usedPercent)}` : "–")).font(size > 60 ? "title2" : "caption2").monospaced()
  ])
}

/** One window as a bar whose fill springs to each new value. */
function bar(w: () => Window | null, width: number): View {
  return ZStack([
    Capsule().fill(cmux.theme.separator).frame({ width, height: 6 }),
    HStack({ spacing: 0 }, [
      Capsule().fill(() => toneOf(w())).frame(() => ({ width: Math.max(6, width * pct(w())), height: 6 })).glow(glowing(w)).animation("snappy"),
      Spacer()
    ]).frame({ width })
  ])
}

/** Under, on or over pace for the tighter window; it pulses while that window nears its limit. */
function paceBadge(p: () => Provider): View {
  const tight = () => {
    const s = windowOf(p(), "session")
    const w = windowOf(p(), "weekly")
    return !s || (w && w.usedPercent > s.usedPercent) ? w : s
  }
  const verdict = () => pace(tight(), now())
  return Badge(() => verdict().label, () => verdict().tone).loop(() => (verdict().hot ? { effect: "pulse" } : null))
}

const spend = (p: Provider) => `${tokens(p.tokens24h)} tok · ${dollars(p.costUsd24h)}${p.working ? ` · ${p.working} working` : ""}`

function sectionRow(p: () => Provider): View {
  if (variant() === "bars") {
    return VStack({ spacing: 3 }, [
      HStack([Text(() => nameOf(p().provider)).font("headline"), Spacer(), paceBadge(p)]),
      HStack([Text("5h").font("caption2").color(cmux.theme.text.tertiary), bar(() => windowOf(p(), "session"), 120), Spacer()]),
      HStack([Text("wk").font("caption2").color(cmux.theme.text.tertiary), bar(() => windowOf(p(), "weekly"), 120), Spacer()]),
      Text(() => spend(p())).font("caption").color(cmux.theme.text.secondary)
    ])
  }
  return HStack({ spacing: 8 }, [
    rings(p, 30),
    VStack({ spacing: 1 }, [
      Text(() => nameOf(p().provider)).font("headline"),
      Text(() => spend(p())).font("caption").color(cmux.theme.text.secondary).lineLimit(1)
    ]),
    Spacer(),
    paceBadge(p)
  ])
}

/** The 24-hour total tokens and dollars. */
function counter(shown: { tokens: () => number | null; cost: () => number | null }, big: boolean): View {
  return HStack({ spacing: 6 }, [
    Text(() => tokens(shown.tokens())).font(big ? "largeTitle" : "title3").monospaced().weight("semibold").fixedSize("horizontal"),
    Text(() => `tokens · ${dollars(shown.cost())} today`).font(big ? "title3" : "caption").color(cmux.theme.text.secondary).lineLimit(1),
    Spacer()
  ])
}

function frameFor(body: View[], working: () => boolean): View {
  if (variant() !== "neon") return VStack({ spacing: 8 }, body)
  return ZStack([
    Particles({ preset: "embers", rate: () => (working() ? 1 : 0.2) }).opacity(0.5),
    VStack({ spacing: 8 }, body).padding(10)
  ]).gradient({ colors: ["#14102AE6", "#2A1240E6"], angle: 135 }).cornerRadius(12)
}

// A function child is rebuilt when what it reads changes: here, the `variant` setting.
export const renderSection = section(() => {
  const { meter, problem, shown, providers } = useMeter()
  return Panel({ style: "glass" }, [
    () => frameFor([
      counter(shown, false),
      ForEach({ items: providers, key: (p) => p.provider }, (p) => sectionRow(p).transition("pop")),
      Text(() => problem() ?? (providers().length ? "" : "No chats with usage yet. Set source to demo to preview."))
        .font("caption").color(cmux.theme.text.secondary)
    ], () => (meter()?.totals.working ?? 0) > 0)
  ])
})

function card(p: () => Provider): View {
  const detail = (id: string, label: string) => () => {
    const w = windowOf(p(), id)
    return w ? `${label} ${Math.round(w.usedPercent)}% · ${countdown(w.resetsAtMs, now())}` : `${label} not reported`
  }
  const big = variant() === "bars"
    ? VStack({ spacing: 6 }, [bar(() => windowOf(p(), "session"), 220), bar(() => windowOf(p(), "weekly"), 220)])
    : rings(p, 96)
  return HStack({ spacing: 16 }, [
    big,
    VStack({ spacing: 4 }, [
      HStack([Icon("gauge.with.needle").color(cmux.theme.accent), Text(() => nameOf(p().provider)).font("title3"), Spacer(), paceBadge(p)]),
      Text(detail("session", "5-hour")).font("callout").monospaced(),
      Text(detail("weekly", "Week")).font("callout").monospaced(),
      Text(() => `${spend(p())} · ${p().calls24h ?? "–"} calls`).font("caption").color(cmux.theme.text.secondary)
    ])
  ]).padding(12).transition("pop")
}

export const renderPane = pane(() => {
  const { meter, problem, shown, providers } = useMeter()
  return VStack({ spacing: 12 }, [
    () => frameFor([
      counter(shown, true),
      ForEach({ items: providers, key: (p) => p.provider }, (p) => card(p)),
      () => (problem() || providers().length
        ? Text(() => problem() ?? "").color(cmux.theme.warning)
        : EmptyState({ title: "No usage yet", message: "Start a Claude or Codex chat, or set source to demo.", symbol: "gauge.with.needle" }))
    ], () => (meter()?.totals.working ?? 0) > 0),
    Spacer()
  ]).padding(16)
})
