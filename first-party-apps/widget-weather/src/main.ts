// Weather, as Apple's Weather widget draws it: the place, the big current temperature, the sky's
// symbol and words, today's high and low; the medium size adds the next six hours, the large one
// the next days. It imports nothing but the public SDK.
// - Where: the place typed in Settings, else the town the internet address points to (GeoJS), so
//   a fresh install shows real weather with nothing to set up.
// - Data: Open-Meteo, no account. One read per place however many widgets show it, kept in the
//   app's storage so a new window or a restart draws at once; re-read at most every 10 minutes,
//   on the host's 15 minute tick (now()).
// - Units and clock follow the locale's region, else the place's country (Fahrenheit and 12-hour
//   in the US); Units in Settings overrides. They apply when drawing, so changing them reads nothing.

import {
  Button,
  cmux,
  computed,
  HStack,
  Icon,
  signal,
  Spacer,
  Text,
  VStack,
  widget,
  WIDGET_INSET,
  type View,
  type WidgetContext,
  type WidgetSize
} from "cmux-extension-sdk"
import {
  describe,
  forecastURL,
  GEOCODE_URL,
  hourLabel,
  IP_LOCATION_URL,
  isForecast,
  placeFromGeocode,
  placeFromGeoJS,
  shown,
  SKY_COLORS,
  skyFor,
  symbolColor,
  toForecast,
  unitsFor,
  weekday,
  weekRange,
  type Day,
  type Forecast,
  type GeocodeResult,
  type GeoJS,
  type Hour,
  type Place,
  type Units
} from "./model.ts"
import { SAMPLE_FORECAST, SAMPLE_PLACE } from "./sample.ts"

export interface Reading {
  /** The Place setting this reading answers ("" is the automatic location). */
  key: string
  place: Place
  forecast: Forecast
  at: number
}

const REUSE_MS = 10 * 60_000
const REFRESH_MS = 15 * 60_000
const IP_PLACE_MS = 6 * 60 * 60_000
const STORE_READING = "reading"
const STORE_IP_PLACE = "ip-place"

const t = (key: string, fallback: string, params?: Record<string, unknown>) => cmux.t(key, fallback, params)

const [reading, setReading] = signal<Reading | null>(null)
const [problem, setProblem] = signal<string | null>(null)

const typedPlace = (s: Record<string, unknown>) => String(s.place ?? "").trim()
const keyOf = (s: Record<string, unknown>) => typedPlace(s).toLowerCase()

function explain(error: unknown): string {
  const e = error as { code?: string; message?: string }
  if (e?.code === "scope.missing") return t("problem.network", "Allow network access for Weather in Settings > Apps.")
  return e?.message ?? String(error)
}

async function getJSON<T>(url: string): Promise<T> {
  const response = await cmux.net.fetch(url)
  if (!response.ok) throw new Error(t("problem.status", "The weather service answered {status}.", { status: response.status }))
  return response.json<T>()
}

/** The typed place, else the town of the internet address (kept for six hours). */
async function locate(name: string): Promise<Place> {
  if (name) {
    const place = placeFromGeocode(await getJSON<GeocodeResult>(GEOCODE_URL + encodeURIComponent(name)))
    if (!place) throw new Error(t("problem.noPlace", "No place called {name}.", { name }))
    return place
  }
  const kept = await cmux.storage.get<{ place: Place; at: number }>(STORE_IP_PLACE).catch(() => null)
  if (kept && Date.now() - kept.at < IP_PLACE_MS) return kept.place
  const place = placeFromGeoJS(await getJSON<GeoJS>(IP_LOCATION_URL))
  if (!place) throw new Error(t("problem.noLocation", "Couldn't tell where you are. Type a place in Settings > Apps > Weather."))
  void cmux.storage.set(STORE_IP_PLACE, { place, at: Date.now() }).catch(() => undefined)
  return place
}

let restored: Promise<void> | null = null
/** The last reading from storage, once per app run: a new widget draws before any network read. */
function restore(): Promise<void> {
  restored ??= cmux.storage
    .get<Reading>(STORE_READING)
    .then((kept) => {
      if (kept?.forecast && !reading()) setReading(kept)
    })
    .catch(() => undefined)
  return restored
}

const inflight = new Map<string, Promise<void>>()

/** Reads the weather for these settings unless a reading for them is younger than ten minutes. */
export function load(settings: Record<string, unknown>, force = false): Promise<void> {
  const key = keyOf(settings)
  const running = inflight.get(key)
  if (running) return running
  const job = (async () => {
    await restore()
    const last = reading()
    if (!force && last?.key === key && Date.now() - last.at < REUSE_MS) return
    try {
      const place = last?.key === key ? last.place : await locate(typedPlace(settings))
      const body = await getJSON<unknown>(forecastURL(place))
      if (!isForecast(body)) throw new Error(t("problem.shape", "The weather service sent an answer Weather can't read."))
      const next: Reading = { key, place, forecast: toForecast(body), at: Date.now() }
      setReading(next)
      setProblem(null)
      void cmux.storage.set(STORE_READING, next).catch(() => undefined)
    } catch (error) {
      setProblem(explain(error))
    } finally {
      inflight.delete(key)
    }
  })()
  inflight.set(key, job)
  return job
}

// ---------------------------------------------------------------------------------------------
// Drawing. Sizes follow Apple's widget grid (small 1x1, medium 2x1, large 2x2) and its type
// scale: 16 pt insets, a 15 pt semibold place, a light big number, 13 pt semibold details.

interface Look {
  sky: boolean
  text: string
  secondary: string
  units: Units
}

const degrees = (celsius: number, look: Look) => `${shown(celsius, look.units)}°`

function symbol(name: string, size: number, look: Look): View {
  const color = symbolColor(name)
  return Icon(name).size(size).font(size).color(look.sky || color !== "#FFFFFF" ? color : look.text)
}

function header(r: Reading, look: Look, big: number): View {
  return VStack({ spacing: 0 }, [
    HStack({ spacing: 3 }, [
      Text(r.place.name).font(15).weight("semibold").color(look.text).lineLimit(1),
      r.place.source === "approximate" ? Icon("location.fill").size(10).font(10).color(look.text) : null
    ]),
    Text(degrees(r.forecast.temperature, look)).font(big).weight("regular").color(look.text).lineLimit(1)
  ])
}

function conditionLines(r: Reading, look: Look, alignment: "leading" | "trailing"): View {
  const c = describe(r.forecast.code, r.forecast.day)
  return VStack({ spacing: 2, alignment }, [
    symbol(c.symbol, 16, look),
    Text(t(`condition.${c.text}`, c.text)).font(13).weight("semibold").color(look.text).lineLimit(1),
    Text(t("highLow", "H:{high} L:{low}", { high: degrees(r.forecast.high, look), low: degrees(r.forecast.low, look) }))
      .font(13)
      .weight("semibold")
      .color(look.text)
      .lineLimit(1)
  ])
}

function hourColumn(h: Hour, look: Look): View {
  return VStack({ spacing: 5, alignment: "center" }, [
    Text(hourLabel(h.time, look.units.twelveHour)).font(11).weight("semibold").color(look.secondary).lineLimit(1),
    symbol(describe(h.code, h.day).symbol, 18, look),
    Text(degrees(h.temperature, look)).font(14).weight("semibold").color(look.text).lineLimit(1)
  ]).frame({ maxWidth: "infinity" })
}

/** Apple's strip: the columns spread evenly over the width, the first and last at the edges. */
function hourStrip(r: Reading, look: Look): View {
  return HStack(
    { spacing: 0 },
    r.forecast.hours.flatMap((h, i) => (i === 0 ? [hourColumn(h, look)] : [Spacer(), hourColumn(h, look)]))
  )
}

const BAR_WIDTH = 72

/** Apple's range bar: the week's span as a track, the day's low-to-high as the filled part. */
function rangeBar(d: Day, span: { min: number; max: number }, look: Look): View {
  const scale = BAR_WIDTH / (span.max - span.min)
  const from = Math.max(0, Math.round((shown(d.low, look.units) - span.min) * scale))
  const to = Math.min(BAR_WIDTH, Math.max(from + 6, Math.round((shown(d.high, look.units) - span.min) * scale)))
  return HStack({ spacing: 0 }, [
    HStack([]).frame({ width: from, height: 4 }),
    HStack([]).frame({ width: to - from, height: 4 }).background(look.sky ? "#FFD60A" : cmux.theme.accent).cornerRadius(2),
    Spacer()
  ])
    .frame({ width: BAR_WIDTH, height: 4 })
    .background(look.sky ? "#FFFFFF33" : cmux.theme.separator)
    .cornerRadius(2)
}

function dayRow(d: Day, span: { min: number; max: number }, look: Look): View {
  const name = d.today ? t("today", "Today") : t(`weekday.${weekday(d.date)}`, weekday(d.date))
  return HStack({ spacing: 8 }, [
    Text(name).font(14).weight("semibold").color(look.text).lineLimit(1).frame({ width: 48 }),
    symbol(describe(d.code, true).symbol, 16, look).frame({ width: 24 }),
    Spacer(),
    Text(degrees(d.low, look)).font(14).weight("semibold").color(look.secondary).frame({ width: 32 }),
    rangeBar(d, span, look),
    Text(degrees(d.high, look)).font(14).weight("semibold").color(look.text).frame({ width: 32 })
  ])
}

function small(r: Reading, look: Look): View {
  return VStack({ spacing: 0 }, [header(r, look, 44), Spacer(), conditionLines(r, look, "leading")])
}

function top(r: Reading, look: Look): View {
  return HStack({ spacing: 8 }, [header(r, look, 40), Spacer(), conditionLines(r, look, "trailing")])
}

function medium(r: Reading, look: Look): View {
  return VStack({ spacing: 0 }, [top(r, look), Spacer(), hourStrip(r, look)])
}

function large(r: Reading, look: Look): View {
  const span = weekRange(r.forecast.days, look.units)
  return VStack({ spacing: 10 }, [
    top(r, look),
    hourStrip(r, look),
    HStack([]).frame({ height: 1, maxWidth: "infinity" }).background(look.sky ? "#FFFFFF40" : cmux.theme.separator),
    VStack({ spacing: 6 }, r.forecast.days.map((d) => dayRow(d, span, look))),
    Spacer()
  ])
}

/** Before the first reading for these settings: the frame and what is happening. */
function waiting(look: Look, message: string | null): View {
  return VStack({ spacing: 4 }, [
    Text(t("title", "Weather")).font(15).weight("semibold").color(look.text),
    Text("--°").font(44).weight("light").color(look.text),
    Spacer(),
    Text(message ?? t("loading", "Finding the weather near you…")).font(12).weight("medium").color(look.secondary).lineLimit(3)
  ])
}

// `widget()` keeps a throwing render to its own tile (let it crash); the named function is the export
// cmux.widget/1 calls (first-party-apps/build.ts checks dist/main.js defines it).
const drawWeather = widget((ctx: Partial<WidgetContext> = {}): View => {
  const size: WidgetSize = ctx.size ?? "small"
  const preview = ctx.preview === true
  const settings = computed(() => ({ ...cmux.app.settings(), ...(ctx.settings ?? {}) }))
  // The host owns the clock: now() ticks on the manifest's 15 minutes while the tile is shown, and
  // each tick asks load(), which reads only when the kept reading is older than 10 minutes. A host
  // with no clock (an older one) gets the same cadence from a timer that ends with the view.
  if (!ctx.now && !preview) cmux.timer.every(REFRESH_MS, () => void load(settings()))
  let seen: string | null = null
  const watchKey = () => {
    if (preview) return null
    const key = `${keyOf(settings())}|${ctx.now?.() ?? 0}`
    if (key !== seen) {
      seen = key
      void load(settings())
    }
    return null
  }
  const shownReading = computed<Reading | null>(() =>
    preview ? { key: keyOf(settings()), place: SAMPLE_PLACE, forecast: SAMPLE_FORECAST, at: 0 } : reading()
  )
  const look = computed<Look>(() => {
    const s = settings()
    const units = unitsFor(cmux.app.locale || "en", s.units, shownReading()?.place.country ?? "")
    return s.look === "plain"
      ? { sky: false, text: cmux.theme.text.primary, secondary: cmux.theme.text.secondary, units }
      : { sky: true, text: "#FFFFFF", secondary: "#FFFFFFB3", units }
  })
  const sky = computed(() => {
    if (!look().sky) return null
    const r = shownReading()
    return r ? SKY_COLORS[skyFor(r.forecast.code, r.forecast.day)] : SKY_COLORS["clear-day"]
  })
  return VStack({ spacing: 0 }, [
    watchKey,
    () => {
      const r = shownReading()
      const l = look()
      // A reading for another place (the setting changed) is never shown as this one's weather.
      if (!r || r.key !== keyOf(settings())) return waiting(l, problem())
      if (size === "large") return large(r, l)
      if (size === "medium") return medium(r, l)
      return small(r, l)
    }
  ])
    .padding(ctx.place === "sidebar" ? WIDGET_INSET.sidebar : WIDGET_INSET.newtab)
    .frame({ maxWidth: "infinity", maxHeight: "infinity" })
    .background(sky)
    .contextMenu(() => (preview ? [] : [Button(t("refresh", "Refresh weather"), () => load(settings(), true))]))
})

/** The `cmux.widget/1` export the manifest names. */
export function renderWeather(ctx: WidgetContext): View {
  return drawWeather(ctx)
}
