// Clock: a widget in the iOS Lock Screen style. The date line sits above a big, heavy time.
// - small: the weekday, the date and the time.
// - medium: the same on the left, and two other cities on the right (their time, how far they
//   are from you, and Tomorrow or Yesterday when their day is not yours).
// - large: the time with the date in words, then four cities.
// - face "analog": a dial in small, four city dials in medium (Apple's World Clock widget).
// - the time's font design, weight and color, and whether the date shows, are settings (the options
//   of the New Tab clock this replaces, cmux#44388).
// It imports nothing but the public SDK and asks no host for data: the zone rules come from
// cmux.time.zone. The view redraws once a minute, just after the minute starts, from a one-shot
// timer that arms the next; nothing runs between minutes.

import { BigNumber, cmux, computed, ForEach, HStack, onCleanup, signal, Spacer, Text, untrack, VStack, ZStack, Circle, WIDGET_INSET, type View } from "cmux-extension-sdk"
import {
  CITY_COUNT,
  cities,
  dateLine,
  fitTimeFont,
  handAngles,
  homeName,
  homeOffset,
  PERIOD_FONT,
  PERIOD_GAP,
  shortDate,
  shortWeekday,
  showsDate,
  sizeOf,
  SMALL_TIME_WIDTH,
  timeParts,
  timeStyle,
  twelveHour,
  untilNextMinute,
  wall,
  weekday,
  type City,
  type Settings,
  type Size,
  type TimeStyle,
  type ZoneOf
} from "./clock.ts"

/** The mount context the widget host passes (contract cmux.widget/1). */
export interface WidgetContext {
  size?: Size
  place?: "newtab" | "sidebar"
  settings?: Settings
  instance?: string
  /** The person's locale (BCP 47) and IANA zone, from the page (the sandbox has no Intl). */
  locale?: string
  timeZone?: string
  /** The host's reactive clock (ms), ticked on the minute while the tile shows (manifest refresh: 60 s). */
  now?: () => number
}

/** The big time's point size per size: Apple's widget scale, heavy weight. */
const TIME_FONT: Record<Size, number> = { small: 50, medium: 56, large: 64 }
/** Monospaced digits are wider: smaller, so the small tile still fits the time and AM/PM on one line. */
const MONO_TIME_FONT: Record<Size, number> = { small: 40, medium: 46, large: 56 }

const zoneOf: ZoneOf = (zone, at) => cmux.time.zone(zone, at)

/** The weekday's red (Apple's system red): a hex, since a theme token may not be red. */
const WEEKDAY_RED = "#FF3B30"

/**
 * The font design (rounded, serif, mono) on a text. A host whose scene has `fontDesign` takes the
 * live setting; an older one draws the system design, mono through `monospaced()` as read at mount.
 */
function withDesign(view: View, style: () => TimeStyle): View {
  const designable = view as View & { fontDesign?: (v: () => string) => View }
  if (typeof designable.fontDesign === "function") return designable.fontDesign(() => style().design)
  return untrack(style).design === "monospaced" ? view.monospaced() : view
}

/**
 * The time with its AM/PM beside it, small, on the baseline (the Lock Screen drops it; a widget keeps it).
 * In the small tile the digits are sized to its width, so the widest time ("10:58 PM") fits at every
 * font and weight; medium and large have the room for their fixed size.
 */
function bigTime(time: () => string, period: () => string, hasPeriod: () => boolean, size: Size, style: () => TimeStyle): View {
  const largest = () => (style().design === "monospaced" ? MONO_TIME_FONT : TIME_FONT)[size]
  const font = () =>
    size === "small" ? fitTimeFont(time(), hasPeriod() ? period() : "", style().design === "monospaced", largest(), SMALL_TIME_WIDTH) : largest()
  const digits = BigNumber(time)
    .font(font)
    .weight(() => style().weight)
    .color(() => style().color)
    .opacity(() => style().opacity)
    .lineLimit(1)
    .fixedSize("horizontal")
  return HStack({ spacing: PERIOD_GAP, alignment: "lastTextBaseline" }, [
    withDesign(digits, style),
    () => (hasPeriod() ? Text(period).font(PERIOD_FONT).weight("bold").secondary().lineLimit(1).fixedSize("horizontal") : null)
  ])
}

function cityRow(c: () => City, hasPeriod: () => boolean, style: () => TimeStyle): View {
  return HStack({ spacing: 8, alignment: "center" }, [
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => c().name).font("subheadline").weight("semibold").lineLimit(1),
      Text(() => [c().day, c().offset].filter(Boolean).join(", ")).font("caption").secondary().lineLimit(1)
    ]),
    Spacer(),
    HStack({ spacing: 2, alignment: "lastTextBaseline" }, [
      withDesign(Text(() => c().time).font("title3").weight("semibold").lineLimit(1).contentTransition("numericText"), style),
      () => (hasPeriod() ? Text(() => c().period).font("caption2").weight("semibold").secondary() : null)
    ])
  ])
}

/** One clock hand: a D x D square turned about its center, with the hand drawn from the center up. */
function hand(dial: number, length: number, width: number, angle: () => number, tone: string): View {
  return VStack({ spacing: 0, alignment: "center" }, [
    VStack([]).frame({ width, height: dial / 2 - length }),
    VStack([]).frame({ width, height: length }).background(tone).cornerRadius(width / 2),
    VStack([]).frame({ width, height: dial / 2 })
  ])
    .frame({ width: dial, height: dial })
    .rotation(angle)
    .animation("smooth")
}

function tick(dial: number, angle: number, major: boolean): View {
  const width = major ? 2 : 1.5
  return VStack({ spacing: 0, alignment: "center" }, [
    VStack([]).frame({ width, height: dial * 0.04 }),
    VStack([]).frame({ width, height: major ? dial * 0.09 : dial * 0.05 }).background(major ? "primary" : "tertiary"),
    Spacer()
  ])
    .frame({ width: dial, height: dial })
    .rotation(angle)
}

/** An analog face: the dial, twelve ticks (four at quarter hours stronger), hour and minute hands. */
function dialFace(dial: number, angles: () => { hourAngle: number; minuteAngle: number }, ticks = 12): View {
  const step = 360 / ticks
  return ZStack([
    Circle().size(dial).fill("hover").stroke("separator").strokeWidth(1),
    ...Array.from({ length: ticks }, (_, i) => tick(dial, i * step, (i * step) % 90 === 0)),
    hand(dial, dial * 0.27, Math.max(3, dial * 0.045), () => angles().hourAngle, "primary"),
    hand(dial, dial * 0.4, Math.max(2, dial * 0.03), () => angles().minuteAngle, "primary"),
    VStack({ spacing: 0, alignment: "center" }, [Spacer(), Circle().size(Math.max(5, dial * 0.07)).fill("primary"), Spacer()]).frame({ width: dial, height: dial })
  ]).frame({ width: dial, height: dial })
}

/** The widget's render export: the view fills the tile the host gives it. */
export function renderClock(context: WidgetContext = {}): View {
  // The host draws the tile (its card and corner); the widget insets its content as Apple's
  // widgets do: 16 points, 12 in the narrower sidebar.
  return clockView(context ?? {})
    .padding(WIDGET_INSET[context?.place === "sidebar" ? "sidebar" : "newtab"])
    .frame({ maxWidth: "infinity", minHeight: "infinity", maxHeight: "infinity" })
}

/**
 * The minute clock. The widget host ticks `now()` on the minute only while the tile shows, which
 * costs the app nothing between minutes; a host without it (a sidebar section, an older cmux)
 * gets one one-shot timer per minute that arms the next and is cleared with the view.
 */
function minuteClock(context: WidgetContext): () => number {
  if (typeof context.now === "function") return context.now
  const [now, setNow] = signal(Date.now())
  let timer = 0
  let open = true
  const arm = () => {
    timer = cmux.timer.after(untilNextMinute(Date.now()), () => {
      setNow(Date.now())
      if (open) arm()
    })
  }
  arm()
  onCleanup(() => {
    open = false
    cmux.timer.clear(timer)
  })
  return now
}

function clockView(context: WidgetContext): View {
  const now = minuteClock(context)
  const settings = computed<Settings>(() => ({ ...(cmux.app.settings() as Settings), ...(context.settings ?? {}) }))
  const size = sizeOf(context.size)
  const twelve = computed(() => twelveHour(settings(), context.locale || cmux.app.locale))
  // The person's offset by their zone's rules (the context's timeZone), else the runtime's.
  const offset = computed(() => homeOffset(context.timeZone, now(), zoneOf))
  const here = computed(() => wall(now(), offset()))
  const parts = computed(() => timeParts(here(), twelve()))
  const others = computed(() => cities(settings().cities, now(), twelve(), zoneOf, size === "medium" && settings().face === "analog" ? 3 : CITY_COUNT[size], offset()))
  const time = () => parts().time
  const period = () => parts().period
  const style = computed(() => timeStyle(settings()))
  const dated = () => showsDate(settings())
  /** The weekday in red over the short date (small and medium), unless the date is off. */
  const dateStack = (): Array<() => View | null> => [
    () => (dated() ? Text(() => weekday(here())).font("caption").weight("bold").color(WEEKDAY_RED) : null),
    () => (dated() ? Text(() => shortDate(here())).font("title3").weight("semibold") : null)
  ]

  if (settings().face === "analog") {
    if (size === "small") {
      return VStack({ spacing: 6, alignment: "center" }, [
        // 88 points: the dial and the day under it fit the 116 points inside the 148-point tile.
        dialFace(88, () => handAngles(here())),
        Text(() => `${shortWeekday(here())} ${here().getUTCDate()}`).font("caption").weight("semibold").secondary()
      ])
    }
    if (size === "medium") {
      // Apple's World Clock: a row of dials, here first, each named underneath.
      const dial = (label: () => string, sub: () => string, angles: () => { hourAngle: number; minuteAngle: number }) =>
        VStack({ spacing: 4, alignment: "center" }, [
          dialFace(64, angles, 4),
          Text(label).font("caption").weight("semibold").lineLimit(1),
          Text(sub).font("caption2").secondary().lineLimit(1)
        ])
      return HStack({ spacing: 12, alignment: "center" }, [
        dial(() => homeName(context.timeZone, now(), zoneOf), () => [time(), period()].filter(Boolean).join(" "), () => handAngles(here())),
        ...[0, 1, 2].map((i) =>
          dial(
            () => others()[i]?.name ?? "",
            () => (others()[i] ? [others()[i]!.day === "Today" ? "" : others()[i]!.day, others()[i]!.offset].filter(Boolean).join(" ") || "Same time" : ""),
            () => others()[i] ?? { hourAngle: 0, minuteAngle: 0 }
          )
        )
      ])
    }
  }

  if (size === "small") {
    return VStack({ spacing: 0, alignment: "leading" }, [
      ...dateStack(),
      Spacer(),
      bigTime(time, period, twelve, size, style)
    ])
  }

  const list = () =>
    VStack({ spacing: size === "large" ? 16 : 8, alignment: "leading" }, [
      ForEach({ items: others, key: (c) => c.zone }, (c) => cityRow(c, twelve, style))
    ])

  if (size === "medium") {
    return HStack({ spacing: 16, alignment: "center" }, [
      VStack({ spacing: 0, alignment: "leading" }, [
        ...dateStack(),
        Spacer(),
        bigTime(time, period, twelve, size, style)
      ]).frame({ minHeight: "infinity" }),
      list()
    ])
  }

  return VStack({ spacing: 20, alignment: "leading" }, [
    VStack({ spacing: 0, alignment: "leading" }, [
      () => (dated() ? Text(() => dateLine(here())).font("headline").weight("semibold").secondary() : null),
      bigTime(time, period, twelve, size, style)
    ]),
    list()
  ])
}
