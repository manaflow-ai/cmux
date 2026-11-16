// Leo clock: a big animated clock as your New Tab page, and a world clock in the sidebar.
// JS ticks once a second (the sandbox floor); all motion between ticks is declared and run by
// cmux's renderer: the second hand sweeps on a 1 s linear animation, digits slide, the colon
// breathes. Pick a face with the `variant` setting (analog, flip, ring); colors live in INK.
import { Circle, cmux, computed, ForEach, HStack, newTab, Row, section, Spacer, Text, untrack, VStack, ZStack, type View } from "cmux-extension-sdk"
import { city, dayFraction, distance, greeting, hhmm, isNight, longDate, secondsSince, ticking, timeText, wall, zonesFrom, type Wall } from "./time.ts"

const INK = {
  face: ["#24305A", "#0B1022"],
  card: ["#2B3150", "#151a2e"],
  hand: "#EEF1FF",
  tick: "#8E97C8",
  accent: "#FF7A59",
}
const D = 300 // the analog face
const R = D / 2
const SWEEP = { duration: 1, curve: "linear" } as const

const settings = () => cmux.app.settings()
const hour12 = () => settings().hour12 === true

// A gap and a bar: hands and ticks are a D-tall column rotated about the face's center.
const gap = (h: number) => VStack([]).frame({ width: 1, height: Math.max(0, h) })
const bar = (width: number, height: number, color: string) => VStack([]).frame({ width, height }).background(color).cornerRadius(width / 2)
const spoke = (inset: number, parts: View[], height: number) =>
  VStack({ alignment: "center", spacing: 0 }, [gap(inset), ...parts, gap(D - inset - height)]).frame({ width: D, height: D })

function analog(now: () => number): View {
  const base = untrack(now) // read once, so the face is not rebuilt on every tick
  const s = () => secondsSince(base, now()) // ever increasing: 354 -> 360 -> 366, never back
  const ticks = Array.from({ length: 60 }, (_, i) => {
    const major = i % 5 === 0
    return spoke(10, [bar(major ? 4 : 1.5, major ? 16 : 7, major ? INK.hand : INK.tick)], major ? 16 : 7).rotation(i * 6)
  })
  const hand = (len: number, width: number, color: string, angle: () => number, tip: View[] = [], tipH = 0) =>
    spoke(R - len - tipH, [...tip, bar(width, len, color)], len + tipH).rotation(angle).animation(SWEEP)
  return ZStack([
    Circle({ size: D }).gradient({ colors: INK.face, angle: 135 }).glow({ color: INK.face[0], radius: 40, opacity: 0.6 }),
    ...ticks,
    hand(R * 0.5, 7, INK.hand, () => s() / 120),
    hand(R * 0.74, 4, INK.hand, () => s() / 10),
    hand(R * 0.8, 2, INK.accent, () => s() * 6, [Circle({ size: 10 }).fill(INK.accent).glow({ color: INK.accent, radius: 10 })], 10),
    spoke(R - 7, [Circle({ size: 14 }).fill(INK.accent)], 14),
  ]).frame({ width: D, height: D })
}

/** One digit position: a ZStack holding one item keyed by the digit, so the old one slides out while the new one slides in. */
const digit = (ch: () => string, font: number, card = false, color: string | null = null) => {
  const face = ZStack([ForEach({ items: () => [ch()], key: (c) => c }, (c) => Text(c).font(font).weight("semibold").monospaced().color(color).transition("slide"))])
  return card
    ? HStack({ spacing: 0 }, [Spacer(), face, Spacer()]).frame({ width: font * 0.95, height: font * 1.45 }).gradient({ colors: INK.card }).cornerRadius(font * 0.2)
    : face
}
const colon = (font: number) => Text(":").font(font).weight("semibold").loop({ effect: "breathe", period: 2 })

function digits(w: () => Wall, font: number, card = false, seconds = false): View {
  const t = () => hhmm(w(), hour12())
  const at = (part: "h" | "m" | "s", i: number) => () => t()[part].padStart(2, " ")[i]
  return HStack({ spacing: card ? 8 : 0 }, [
    digit(at("h", 0), font, card), digit(at("h", 1), font, card), colon(font),
    digit(at("m", 0), font, card), digit(at("m", 1), font, card),
    seconds ? VStack({ spacing: 0 }, [Spacer(), HStack({ spacing: 0 }, [digit(at("s", 0), font * 0.4, false, INK.accent), digit(at("s", 1), font * 0.4, false, INK.accent)])]) : null,
    hour12() ? Text(() => t().ampm).font("title3").secondary() : null,
  ]).frame({ height: font * 1.5 })
}

/** A day ring: how far through its day a zone is, drawn with trim and eased each tick. */
function ring(w: () => Wall, size: number, label: View): View {
  const stroke = Math.max(4, size / 18)
  return ZStack([
    Circle({ size }).stroke("separator").strokeWidth(stroke),
    Circle({ size }).stroke(() => (isNight(w()) ? INK.tick : INK.accent)).strokeWidth(stroke).trim(() => ({ to: dayFraction(w()) })).animation(SWEEP),
    VStack({ alignment: "center", spacing: 2 }, [Spacer(), label, Spacer()]).frame({ width: size, height: size }),
  ]).frame({ width: size, height: size })
}

function worldRing(now: () => number, here: () => Wall): View {
  const zones = computed(() => zonesFrom(settings().zones))
  return VStack({ alignment: "center", spacing: 28 }, [
    ring(here, 260, VStack({ alignment: "center", spacing: 4 }, [digits(here, 56), Text(() => `${Math.round(dayFraction(here()) * 100)}% of today`).secondary()])),
    HStack({ spacing: 22 }, [
      ForEach({ items: zones, key: (z) => z }, (z) => {
        const w = () => wall(z(), now())
        return VStack({ alignment: "center", spacing: 6 }, [
          ring(w, 92, Text(() => timeText(w(), hour12())).font("headline").monospaced()),
          Text(() => city(z())).weight("semibold"),
          Text(() => (w().ok ? `${distance(w().offset)} · ${w().abbreviation}` : "not a time zone")).font("caption").secondary(),
        ]).transition("pop")
      }),
    ]),
  ])
}

export const renderNewTab = newTab(() => {
  const now = ticking(1000)
  const here = computed(() => wall(null, now()))
  const variant = computed(() => String(settings().variant ?? "analog"))
  const face = () => {
    const v = variant()
    if (v === "flip") return digits(here, 64, true, true).transition("fade")
    if (v === "ring") return worldRing(now, here).transition("fade")
    return VStack({ alignment: "center", spacing: 18 }, [analog(now), digits(here, 34)]).transition("fade")
  }
  return VStack({ alignment: "center", spacing: 22 }, [
    Spacer(),
    Text(() => greeting(here(), settings().name)).font(40).weight("bold"),
    Text(() => longDate(here())).font("title3").secondary(),
    face,
    Spacer(),
  ]).frame({ width: "infinity", height: "infinity" })
})

/** The sidebar: a row per zone, in the same three variants. Redraws once a minute, on the minute. */
export const renderWorldClock = section(() => {
  const now = ticking(60_000)
  const zones = computed(() => zonesFrom(settings().zones))
  const variant = computed(() => String(settings().variant ?? "analog"))
  const row = (v: string, z: () => string): View => {
    const w = () => wall(z(), now())
    const subtitle = () => (w().ok ? `${distance(w().offset)} · ${w().abbreviation}` : "not a time zone")
    if (v === "analog") return Row({ title: () => city(z()), subtitle, symbol: () => (isNight(w()) ? "moon.stars" : "sun.max"), accessory: () => timeText(w(), hour12()) })
    return HStack({ spacing: 8 }, [
      v === "ring" ? ring(w, 18, gap(0)) : null,
      VStack({ spacing: 0 }, [Text(() => city(z())).weight("medium"), Text(subtitle).font("caption").secondary()]),
      Spacer(),
      v === "flip" ? digits(w, 17) : Text(() => timeText(w(), hour12())).monospaced(),
    ]).paddingHorizontal(8).paddingVertical(3)
  }
  // A function child is a live binding: changing the variant redraws the list, ticks do not.
  return VStack({ spacing: 2 }, [() => {
    const v = variant()
    return VStack({ spacing: 2 }, [ForEach({ items: zones, key: (z) => z }, (z) => row(v, z))])
  }])
})
