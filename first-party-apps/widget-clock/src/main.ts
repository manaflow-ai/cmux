// Clock: a widget in the iOS Lock Screen style. The date line sits above a big, heavy time.
// - small: the weekday, the date and the time.
// - medium: the same on the left, and two other cities on the right (their time, how far they
//   are from you, and Tomorrow or Yesterday when their day is not yours).
// - large: the time with the date in words, then four cities.
// - face "analog": a dial in small, four city dials in medium (Apple's World Clock widget).
// It imports nothing but the public SDK and asks no host for data: the zone rules come from
// cmux.time.zone. The view redraws once a minute, just after the minute starts, from a one-shot
// timer that arms the next; nothing runs between minutes.

import { cmux, computed, ForEach, HStack, onCleanup, signal, Spacer, Text, VStack, ZStack, Circle, WIDGET_INSET, type View } from "cmux-extension-sdk"
import {
  CITY_COUNT,
  cities,
  dateLine,
  handAngles,
  localOffset,
  shortDate,
  shortWeekday,
  sizeOf,
  timeParts,
  twelveHour,
  untilNextMinute,
  wall,
  weekday,
  type City,
  type Settings,
  type Size,
  type ZoneOf
} from "./clock.ts"

/** The mount context the widget host passes (contract cmux.widget/1). */
export interface WidgetContext {
  size?: Size
  place?: "newtab" | "sidebar"
  settings?: Settings
  instance?: string
  /** The host's reactive clock (ms), ticked on the minute while the tile shows (manifest refresh: 60 s). */
  now?: () => number
}

/** The big time's point size per size: Apple's widget scale, heavy weight. */
const TIME_FONT: Record<Size, number> = { small: 50, medium: 56, large: 64 }

const zoneOf: ZoneOf = (zone, at) => cmux.time.zone(zone, at)

/** The time with its AM/PM beside it, small, on the baseline (the Lock Screen drops it; a widget keeps it). */
function bigTime(time: () => string, period: () => string, hasPeriod: () => boolean, size: Size): View {
  return HStack({ spacing: 3, alignment: "lastTextBaseline" }, [
    Text(time).font(TIME_FONT[size]).weight("heavy").lineLimit(1).fixedSize("horizontal"),
    () => (hasPeriod() ? Text(period).font("headline").weight("bold").secondary() : null)
  ])
}

function cityRow(c: () => City, hasPeriod: () => boolean): View {
  return HStack({ spacing: 8, alignment: "center" }, [
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => c().name).font("subheadline").weight("semibold").lineLimit(1),
      Text(() => [c().day, c().offset].filter(Boolean).join(", ")).font("caption").secondary().lineLimit(1)
    ]),
    Spacer(),
    HStack({ spacing: 2, alignment: "lastTextBaseline" }, [
      Text(() => c().time).font("title3").weight("semibold").lineLimit(1),
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
  const twelve = computed(() => twelveHour(settings(), cmux.app.locale))
  const here = computed(() => wall(now(), localOffset(now())))
  const parts = computed(() => timeParts(here(), twelve()))
  const others = computed(() => cities(settings().cities, now(), twelve(), zoneOf, size === "medium" && settings().face === "analog" ? 3 : CITY_COUNT[size]))
  const time = () => parts().time
  const period = () => parts().period

  if (settings().face === "analog") {
    if (size === "small") {
      return VStack({ spacing: 6, alignment: "center" }, [
        dialFace(112, () => handAngles(here())),
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
        dial(() => "Here", () => [time(), period()].filter(Boolean).join(" "), () => handAngles(here())),
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
      Text(() => weekday(here())).font("caption").weight("bold").color("danger"),
      Text(() => shortDate(here())).font("title3").weight("semibold"),
      Spacer(),
      bigTime(time, period, twelve, size)
    ])
  }

  const list = () =>
    VStack({ spacing: size === "large" ? 16 : 8, alignment: "leading" }, [
      ForEach({ items: others, key: (c) => c.zone }, (c) => cityRow(c, twelve))
    ])

  if (size === "medium") {
    return HStack({ spacing: 16, alignment: "center" }, [
      VStack({ spacing: 0, alignment: "leading" }, [
        Text(() => weekday(here())).font("caption").weight("bold").color("danger"),
        Text(() => shortDate(here())).font("title3").weight("semibold"),
        Spacer(),
        bigTime(time, period, twelve, size)
      ]).frame({ minHeight: "infinity" }),
      list()
    ])
  }

  return VStack({ spacing: 20, alignment: "leading" }, [
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => dateLine(here())).font("headline").weight("semibold").secondary(),
      bigTime(time, period, twelve, size)
    ]),
    list()
  ])
}
