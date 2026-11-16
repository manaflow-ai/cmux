// Chief gacha: press Pull, a card shakes, pops open and reveals a Chief with its rarity's glow and a
// burst of sparkles (confetti for epic and legendary). The collection log keeps what you pulled.
// It imports nothing but the public SDK.
// - Every motion is declared here (.loop, .transition, .animation, .glow, Particles) and run by
//   cmux's renderer: this code never ticks a frame.
// - The log persists with cmux.storage. The roll table and odds live in ./chiefs.ts.
// - An agent finishing a turn gives a free pull (scope agent:read; setting `agentPulls`).
// - Settings > Apps > Chief gacha: `variant` (holo, pixel, glass) is the card style.

import {
  agents, Button, cmux, computed, effect, ForEach, HStack, Icon, Image, pane, Panel, Particles, section,
  signal, Spacer, Text, untrack, VStack, ZStack, type View
} from "cmux-extension-sdk"
import { CHIEFS, type Chief, day, image, isBig, RARITY, roll, silhouette } from "./chiefs.ts"

interface Log { pulls: number; sinceBig: number; last: string | null; owned: Record<string, { count: number; first: number }> }
type Face = { key: string; chief: Chief | null; bonus: boolean }
type Variant = "holo" | "pixel" | "glass"

const settings = () => cmux.app.settings()
const variant = computed<Variant>(() => (["holo", "pixel", "glass"].includes(String(settings().variant)) ? settings().variant : "holo") as Variant)
const [log, setLog] = signal<Log>({ pulls: 0, sinceBig: 0, last: null, owned: {} })
const [face, setFace] = signal<Face>({ key: "back-0", chief: null, bonus: false })
const [shaking, setShaking] = signal(false)
const [bigPulls, setBigPulls] = signal(0)
let queued = 0

const ownedCount = () => Object.keys(log().owned).length
const last = () => CHIEFS.find((c) => c.id === log().last) ?? null
const progress = () => `${ownedCount()}/${CHIEFS.length} Chiefs · ${log().pulls} ${log().pulls === 1 ? "pull" : "pulls"}`

let loaded = false
function load() {
  if (loaded) return
  loaded = true
  cmux.storage.get<Log>("log").then((saved) => {
    if (saved && typeof saved.pulls === "number" && untrack(log).pulls === 0) setLog(saved)
  }, () => {})
}

/** Shake the card back, then pop the Chief in. A pull asked for mid-shake waits its turn. */
export function pull(bonus = false) {
  if (untrack(shaking)) return void (queued += 1)
  const chief = roll(untrack(log).sinceBig)
  setFace({ key: `back-${untrack(log).pulls + 1}`, chief: null, bonus })
  setShaking(true)
  cmux.timer.after(900, () => {
    const l = untrack(log)
    const had = l.owned[chief.id]
    const owned = { ...l.owned, [chief.id]: { count: (had?.count ?? 0) + 1, first: had?.first ?? Date.now() } }
    const next = { pulls: l.pulls + 1, sinceBig: isBig(chief.rarity) ? 0 : l.sinceBig + 1, last: chief.id, owned }
    setLog(next)
    cmux.storage.set("log", next).catch(() => {})
    if (isBig(chief.rarity)) setBigPulls((n) => n + 1)
    setFace({ key: `chief-${next.pulls}`, chief, bonus })
    setShaking(false)
    if (queued > 0) {
      queued -= 1
      cmux.timer.after(1600, () => pull(true))
    }
  })
}

// A free pull each time one of your agents finishes a turn (working -> anything else).
let working = new Set<string>()
const agentList = agents()
effect(() => {
  const now = new Set((agentList() ?? []).filter((a) => a.state === "working").map((a) => a.id))
  const finished = [...working].some((id) => !now.has(id))
  working = now
  if (finished && settings().agentPulls !== false) untrack(() => pull(true))
})

// ---- the card --------------------------------------------------------------------------------

const tone = (c: Chief | null) => (c ? RARITY[c.rarity] : null)

/** The card in style `v`: its frame, fill, border, glow and (legendary) shimmer. */
function dress(node: View, v: Variant, c: Chief | null, w: number, h: number): View {
  const color = tone(c)?.color ?? "#8E8E96"
  const big = c ? isBig(c.rarity) : false
  node = node.frame({ width: w, height: h })
  if (v === "pixel") node = node.background("#1C1C22").cornerRadius(3).borderColor(c ? color : cmux.theme.accent).borderWidth(w > 120 ? 5 : 3)
  else if (v === "glass") node = node.background(`${color}2E`).cornerRadius(w / 8).borderColor(`${color}AA`).borderWidth(1)
  else node = node.gradient({ colors: tone(c)?.colors ?? ["#3A3A4A", "#16161E"], angle: 135 }).cornerRadius(w / 10).borderColor("#FFFFFF55").borderWidth(1)
  return node
    .glow(c && (big || v !== "pixel") ? { color, radius: big ? w / 8 : w / 18, opacity: 0.85 } : null)
    .loop(c?.rarity === "legendary" && v !== "pixel" ? { effect: "shimmer" } : null)
}

function cardBack(v: Variant, w: number, h: number): View {
  const ink = v === "pixel" ? cmux.theme.accent : "#FFFFFFCC"
  return dress(VStack({ spacing: 6 }, [
    Icon("sparkles").font(Math.round(w / 4)).color(ink),
    w > 120 ? Text("PULL ME").font("headline").bold().monospaced().color(ink) : null
  ]), v, null, w, h)
    .loop(() => (shaking() ? { effect: "wiggle", period: 0.25, amount: 1.6 } : { effect: "float" }))
    .transition("scale")
}

function cardFront(v: Variant, c: Chief, bonus: boolean, w: number, h: number): View {
  const t = RARITY[c.rarity]
  const ink = v === "holo" ? "#FFFFFF" : t.color
  const big = w > 120
  return dress(VStack({ spacing: 4 }, [
    big ? Text(t.stars).font("title3").color(ink) : null,
    Image(image(c)).frame({ width: w * 0.78, height: w * 0.78 }),
    big ? Text(c.name).font("title3").bold().monospaced().color(v === "holo" ? "#FFFFFF" : cmux.theme.text.primary) : null,
    big ? Text(bonus ? `${t.label} · agent bonus` : t.label).font("caption").color(ink) : null
  ]), v, c, w, h)
    .transition("pop")
    .animation("bouncy")
}

/** The stage: sparkles (and confetti for epic and up) behind the card; a new key pops the next card in. */
function stage(v: Variant, w: number, h: number): View {
  return ZStack([
    Particles({ preset: "sparkles", colors: () => tone(face().chief)?.colors ?? null, burst: () => log().pulls }),
    Particles({ preset: "confetti", colors: () => tone(face().chief)?.colors ?? null, burst: bigPulls }),
    ForEach({ items: () => [face()], key: (f) => f.key }, (f) => {
      const { chief, bonus } = f()
      return chief ? cardFront(v, chief, bonus, w, h) : cardBack(v, w, h)
    })
  ])
}

// ---- the collection log ----------------------------------------------------------------------

function cell(c: Chief): View {
  const got = () => log().owned[c.id]
  return VStack({ spacing: 2 }, [
    Image(() => (got() ? image(c) : silhouette(c))).frame({ width: 44, height: 44 }).opacity(() => (got() ? 1 : 0.35))
      .glow(() => (got() && isBig(c.rarity) ? { color: RARITY[c.rarity].color, radius: 8, opacity: 0.7 } : null)),
    Text(() => (got() ? c.name : "???")).font("caption2").bold().lineLimit(1),
    Text(() => (got() ? `x${got()!.count} · ${day(got()!.first)}` : RARITY[c.rarity].label)).font("caption2")
      .color(() => (got() ? cmux.theme.text.secondary : RARITY[c.rarity].color)).lineLimit(1)
  ]).frame({ width: 84 }).help(() => (got() ? `${c.name}, ${RARITY[c.rarity].label}: pulled ${got()!.count}x, first on ${day(got()!.first)}` : `Not pulled yet (${RARITY[c.rarity].label})`))
}

function collection(): View {
  const rows: Chief[][] = []
  for (let i = 0; i < CHIEFS.length; i += 6) rows.push(CHIEFS.slice(i, i + 6))
  return Panel({ title: "Collection", spacing: 10 }, [
    Text(progress).font("caption").color(cmux.theme.text.secondary),
    ...rows.map((r) => HStack({ spacing: 6 }, [...r.map(cell), Spacer()]))
  ])
}

// ---- places ----------------------------------------------------------------------------------

export const renderPane = pane(() => {
  load()
  return VStack({ spacing: 14 }, [
    HStack({ spacing: 8 }, [Icon("sparkles").color(cmux.theme.accent), Text("Chief gacha").font("title2").bold(), Spacer(), Text(progress).font("caption").color(cmux.theme.text.secondary)]),
    () => stage(variant(), 180, 250).frame({ maxWidth: "infinity", height: 300 }),
    HStack([Spacer(), Button(() => (shaking() ? "Pulling…" : "Pull"), () => pull()).disabled(shaking), Spacer()]),
    collection()
  ]).padding(16)
})

export const renderSection = section(() => {
  load()
  return Panel({ style: "glass" }, [
    HStack({ spacing: 10 }, [
      () => stage(variant(), 48, 60).frame({ width: 64, height: 72 }),
      VStack({ spacing: 2 }, [
        Text(() => last()?.name ?? "No Chief yet").font("headline"),
        Text(() => (last() ? `${RARITY[last()!.rarity].stars} ${RARITY[last()!.rarity].label}` : "Press Pull")).font("caption").color(() => tone(last())?.color ?? cmux.theme.text.secondary),
        Text(progress).font("caption2").color(cmux.theme.text.secondary)
      ]),
      Spacer(),
      Button("Pull", () => pull()).disabled(shaking)
    ])
  ])
})
