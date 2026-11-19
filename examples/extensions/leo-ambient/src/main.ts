// Ambient: what your agents and machines are doing, at a glance. Usage rings per provider (the
// 5-hour window outside, the week inside, like Apple's activity rings), the checks on your open pull
// requests, and how busy each of your machines is. A New Tab page (Settings > Tabs > New Tab App)
// and a widget you place yourself (Edit Widgets > Add Widget); nothing turns it on for you.
//
// Cost: three cmux.watch signals, cached and shared by every mount. chat.list and fleet.hosts are
// pushed by the daemon; github.changes is read only while the checks are on. The extension runs no
// timer of its own: the widget's countdowns read the host's minute tick (ctx.now()).
import {
  BigNumber, bySize, Caption, Capsule, Circle, cmux, computed, ForEach, HStack, newTab, onCleanup, Ring, signal,
  Spacer, Text, VStack, widget, WidgetEmpty, WidgetFrame, WidgetTitle, ZStack, type View, type WidgetContext
} from "cmux-extension-sdk"
import { ci, countdown, dollars, fleet, providers, tokens, type Change, type ChatRow, type CiState, type Host, type Provider, type Window } from "./ambient.ts"

type Show = "usage" | "ci" | "fleet"
const SHOWS: readonly Show[] = ["usage", "ci", "fleet"]
const TITLES: Record<Show, string> = { usage: "Usage", ci: "Checks", fleet: "Machines" }
const SYMBOLS: Record<Show, string> = { usage: "circle.circle", ci: "checkmark.seal", fleet: "server.rack" }

const setting = (name: string) => (cmux.app.settings() as Record<string, unknown>)[name]
const ciOn = computed(() => setting("ci") !== false)
const fleetOn = computed(() => setting("fleet") !== false)

// One watch each, shared by every mount of this extension.
const chats = cmux.watch("chat.list")
const usage = computed(() => providers((chats.value() ?? []) as ChatRow[]))

function changesWatch() {
  const w = cmux.watch("github.changes", () => ({ show: "mine", include: "open", limit: 10 }))
  return computed(() => ci((w.value() ?? []) as Change[]))
}
function hostsWatch() {
  const w = cmux.watch("fleet.hosts")
  return computed(() => fleet((w.value() ?? []) as Host[]))
}

const tone = (w: Window | null) =>
  !w ? cmux.theme.separator : w.usedPercent >= 85 ? cmux.theme.danger : w.usedPercent >= 60 ? cmux.theme.warning : cmux.theme.success
const CI_TONE: Record<CiState, () => string> = {
  failing: () => cmux.theme.danger, pending: () => cmux.theme.warning, passing: () => cmux.theme.success, none: () => cmux.theme.text.secondary
}
const CI_WORD: Record<CiState, string> = { failing: "Failing", pending: "Running", passing: "All green", none: "No checks" }

/** A provider's two rings: the 5-hour window outside, the week inside. */
function rings(p: () => Provider, size: number): View {
  const width = Math.max(4, Math.round(size / 9))
  const inner = size - 2 * width - 4
  return ZStack([
    Ring(() => (p().session?.usedPercent ?? 0) / 100, { tint: () => tone(p().session), width }).frame({ width: size, height: size }),
    Ring(() => (p().weekly?.usedPercent ?? 0) / 100, { tint: () => tone(p().weekly), width }).frame({ width: inner, height: inner })
  ]).frame({ width: size, height: size })
}

const pct = (w: Window | null) => (w ? `${Math.round(w.usedPercent)}%` : "–")

function providerColumn(p: () => Provider, size: number, now: () => number): View {
  return VStack({ spacing: 6, alignment: "center" }, [
    rings(p, size),
    Text(() => p().name).font("headline").lineLimit(1),
    Text(() => `5h ${pct(p().session)} · week ${pct(p().weekly)}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1),
    Text(() => {
      const left = countdown(p().session?.resetsAtMs ?? null, now())
      return `${tokens(p().tokens24h)} tokens · ${dollars(p().costUsd24h)}${left ? ` · resets ${left}` : ""}`
    }).font("caption2").color(cmux.theme.text.tertiary).lineLimit(1)
  ])
}

function ciRow(c: () => Change): View {
  return HStack({ spacing: 8 }, [
    Circle().fill(() => CI_TONE[c().checks.state]()).frame({ width: 8, height: 8 }),
    Text(() => c().title).font("callout").lineLimit(1),
    Spacer(),
    Text(() => `${c().repo.split("/")[1] ?? c().repo} #${c().number}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1)
  ]).onTap(() => void cmux.actions.run("openBrowser", { url: c().url }).catch(() => undefined))
}

function hostRow(h: () => Host, barWidth: number): View {
  const busy = () => (h().reachable ? Math.min(1, Math.max(0, h().busy ?? 0)) : 0)
  const barTone = () => (!h().reachable ? cmux.theme.separator : busy() >= 0.9 ? cmux.theme.danger : busy() >= 0.6 ? cmux.theme.warning : cmux.theme.accent)
  return HStack({ spacing: 8 }, [
    Text(() => h().name).font("callout").lineLimit(1).frame({ width: 110, alignment: "leading" }),
    ZStack({ alignment: "leading" }, [
      Capsule().fill(cmux.theme.separator).frame({ width: barWidth, height: 6 }),
      Capsule().fill(barTone).frame(() => ({ width: Math.max(6, busy() * barWidth), height: 6 })).animation("smooth")
    ]),
    Text(() => (h().reachable ? `${Math.round(busy() * 100)}%` : "offline")).font("caption").monospaced().color(cmux.theme.text.secondary),
    Text(() => (h().liveSessions ? `${h().liveSessions} agents` : "")).font("caption").color(cmux.theme.text.tertiary)
  ])
}

// ── New Tab ────────────────────────────────────────────────────────────────────────────────────

function section(title: string, children: Array<View | (() => unknown) | null>): View {
  return VStack({ spacing: 10, alignment: "leading" }, [Text(title).font("title3").weight("semibold"), ...children]).frame({ maxWidth: 640 })
}

function usageSection(): View {
  // No timer: a countdown is redrawn when its row changes (chat.changed fires on every turn).
  return section("Usage", [
    () => (usage().length === 0 ? Text("No usage yet: start a Claude Code or Codex chat.").color(cmux.theme.text.secondary) : null),
    HStack({ spacing: 36 }, [ForEach({ items: usage, key: (p) => p.id }, (p) => providerColumn(p, 96, Date.now))])
  ])
}

function ciSection(): View {
  const summary = changesWatch()
  return section("Checks", [
    HStack({ spacing: 8 }, [
      Circle().fill(() => CI_TONE[summary().state]()).frame({ width: 10, height: 10 }),
      Text(() => CI_WORD[summary().state]).font("headline"),
      Text(() => `${summary().failing} failing · ${summary().pending} running · ${summary().passing} green`).font("caption").color(cmux.theme.text.secondary)
    ]),
    VStack({ spacing: 6, alignment: "leading" }, [ForEach({ items: () => summary().worst.slice(0, 5), key: (c) => c.id }, ciRow)])
  ])
}

function fleetSection(): View {
  const summary = hostsWatch()
  return section("Machines", [
    Text(() => `${summary().reachable} up · ${summary().sessions} agents running`).font("caption").color(cmux.theme.text.secondary),
    VStack({ spacing: 6, alignment: "leading" }, [ForEach({ items: () => summary().hosts.slice(0, 8), key: (h) => h.name }, (h) => hostRow(h, 220))])
  ])
}

/** Mounts `view` only while `on()` is true, so a section turned off runs no watch. */
const when = (on: () => boolean, key: string, view: () => View) =>
  ForEach({ items: () => (on() ? [key] : []), key: (k) => k }, () => view())

export const renderNewTab = newTab(() =>
  VStack({ spacing: 32, alignment: "center" }, [
    Spacer(),
    usageSection(),
    when(ciOn, "ci", ciSection),
    when(fleetOn, "fleet", fleetSection),
    Spacer()
  ]).padding(32).frame({ maxWidth: "infinity", maxHeight: "infinity" })
)

// ── Widget ─────────────────────────────────────────────────────────────────────────────────────

function usageTile(ctx: WidgetContext): View {
  const first = () => usage()[0]
  if (ctx.size === "small") {
    return VStack({ spacing: 4, alignment: "center" }, [
      () => (first() ? rings(() => first()!, 72) : WidgetEmpty("No usage yet", { symbol: "circle.circle" })),
      Caption(() => (first() ? `${first()!.name} · 5h ${pct(first()!.session)}` : ""))
    ])
  }
  const shown = () => usage().slice(0, ctx.size === "large" ? 4 : 2)
  return HStack({ spacing: 16 }, [
    ForEach({ items: shown, key: (p) => p.id }, (p) => providerColumn(p, ctx.size === "large" ? 84 : 56, ctx.now))
  ])
}

function ciTile(ctx: WidgetContext): View {
  const summary = changesWatch()
  return VStack({ spacing: 4, alignment: "leading" }, [
    BigNumber(() => (summary().state === "failing" ? summary().failing : summary().total)).color(() => CI_TONE[summary().state]()),
    Caption(() => CI_WORD[summary().state]),
    ctx.size === "small" ? null : VStack({ spacing: 4, alignment: "leading" }, [
      ForEach({ items: () => summary().worst.slice(0, ctx.size === "large" ? 6 : 2), key: (c) => c.id }, ciRow)
    ])
  ].filter((v): v is View => v !== null))
}

function fleetTile(ctx: WidgetContext): View {
  const summary = hostsWatch()
  return VStack({ spacing: 4, alignment: "leading" }, [
    BigNumber(() => (summary().busy === null ? "–" : `${Math.round(summary().busy! * 100)}%`)),
    Caption(() => `${summary().reachable} up · ${summary().sessions} agents`),
    ctx.size === "small" ? null : VStack({ spacing: 4, alignment: "leading" }, [
      ForEach({ items: () => summary().hosts.slice(0, ctx.size === "large" ? 6 : 2), key: (h) => h.name }, (h) => hostRow(h, 90))
    ])
  ].filter((v): v is View => v !== null))
}

const TILES: Record<Show, (ctx: WidgetContext) => View> = { usage: usageTile, ci: ciTile, fleet: fleetTile }

export const renderWidget = widget((ctx) => {
  const saved = SHOWS.includes(ctx.settings.show as Show) ? (ctx.settings.show as Show) : "usage"
  const [show, setShow] = signal<Show>(saved)
  const key = `show:${ctx.instance}`
  let live = true
  onCleanup(() => (live = false))
  if (!ctx.preview) void cmux.storage.get<Show>(key).then((s) => live && s && SHOWS.includes(s) && setShow(s))
  const next = () => {
    const s = SHOWS[(SHOWS.indexOf(show()) + 1) % SHOWS.length]!
    setShow(s)
    if (!ctx.preview) void cmux.storage.set(key, s)
  }
  // A switch rebuilds the tile, so only the shown source's watch runs.
  return ForEach({ items: () => [show()], key: (s) => s }, (s) =>
    WidgetFrame([
      WidgetTitle(TITLES[s()], { symbol: SYMBOLS[s()] }).onTap(next).help("Tap to switch: usage, checks, machines"),
      Spacer(),
      bySize(ctx, { small: () => TILES[s()](ctx) })
    ], { place: ctx.place })
  )
})
