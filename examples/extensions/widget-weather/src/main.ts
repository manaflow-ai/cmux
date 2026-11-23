// Weather widget: the weather where you are as a card you add to the sidebar, in the three sizes
// system widgets come in. It imports nothing but the public SDK.
// - Small: the place, the temperature, the sky and today's high and low.
// - Medium: the same over the next six hours.
// - Large: the next six hours and the next six days.
// - Open-Meteo answers with no account or key. Its two hosts are net: scopes you turn on in
//   Settings > Apps > Weather widget; until then the card says so.
// - The place, the units and the size are the extension's settings; the card's own text field
//   writes the place, and a right-click changes the size. It reads the forecast when the place
//   changes and every 15 minutes, and several windows share one read.

import { Button, cmux, computed, ForEach, HStack, Menu, Panel, Row, signal, Spacer, Text, TextField, VStack, type View } from "cmux-extension-sdk"

export type Size = "small" | "medium" | "large"
export const SIZES: Size[] = ["small", "medium", "large"]

export interface Place { name: string; latitude: number; longitude: number }
export interface Hour { label: string; code: number; day: boolean; temperature: number }
export interface Day { label: string; code: number; high: number; low: number }
export interface Forecast { temperature: number; feelsLike: number; code: number; day: boolean; high: number; low: number; hours: Hour[]; days: Day[] }
interface Reading { key: string; place: Place; forecast: Forecast; at: number }

const REFRESH_MS = 15 * 60_000
const REUSE_MS = 10 * 60_000
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

export function sizeOf(setting: unknown): Size {
  return SIZES.includes(setting as Size) ? (setting as Size) : "small"
}

/** WMO weather codes as a person reads them, with a color glyph that reads the same in every renderer. */
export function describe(code: number, day: boolean): { text: string; glyph: string } {
  if (code === 0) return { text: day ? "Sunny" : "Clear", glyph: day ? "☀️" : "🌙" }
  if (code <= 2) return { text: "Partly Cloudy", glyph: day ? "⛅️" : "☁️" }
  if (code === 3) return { text: "Cloudy", glyph: "☁️" }
  if (code <= 48) return { text: "Foggy", glyph: "🌫️" }
  if (code <= 57) return { text: "Drizzle", glyph: "🌦️" }
  if (code <= 67) return { text: "Rain", glyph: "🌧️" }
  if (code <= 77) return { text: "Snow", glyph: "🌨️" }
  if (code <= 82) return { text: "Showers", glyph: "🌧️" }
  if (code <= 86) return { text: "Snow Showers", glyph: "🌨️" }
  return { text: "Thunderstorms", glyph: "⛈️" }
}

function hourLabel(iso: string): string {
  const h = Number(iso.slice(11, 13))
  return `${h % 12 || 12}${h < 12 ? "AM" : "PM"}`
}

function dayLabel(iso: string, index: number): string {
  if (index === 0) return "Today"
  const [y, m, d] = iso.split("-").map(Number)
  return WEEKDAYS[new Date(Date.UTC(y!, m! - 1, d!)).getUTCDay()]!
}

export interface OpenMeteoForecast {
  current: { time: string; temperature_2m: number; apparent_temperature: number; weather_code: number; is_day: number }
  hourly: { time: string[]; temperature_2m: number[]; weather_code: number[]; is_day: number[] }
  daily: { time: string[]; weather_code: number[]; temperature_2m_max: number[]; temperature_2m_min: number[] }
}

/** Open-Meteo's answer as the card reads it: now, the next six hours from this one, six days from today. */
export function forecastFrom(body: OpenMeteoForecast): Forecast {
  const hour = body.current.time.slice(0, 13)
  let start = body.hourly.time.findIndex((t) => t.slice(0, 13) === hour)
  if (start < 0) start = 0
  const hours: Hour[] = []
  for (let i = start; i < Math.min(start + 6, body.hourly.time.length); i++) {
    hours.push({
      label: i === start ? "Now" : hourLabel(body.hourly.time[i]!),
      code: body.hourly.weather_code[i]!,
      day: body.hourly.is_day[i] === 1,
      temperature: Math.round(body.hourly.temperature_2m[i]!)
    })
  }
  const days: Day[] = body.daily.time.slice(0, 6).map((t, i) => ({
    label: dayLabel(t, i),
    code: body.daily.weather_code[i]!,
    high: Math.round(body.daily.temperature_2m_max[i]!),
    low: Math.round(body.daily.temperature_2m_min[i]!)
  }))
  return {
    temperature: Math.round(body.current.temperature_2m),
    feelsLike: Math.round(body.current.apparent_temperature),
    code: body.current.weather_code,
    day: body.current.is_day === 1,
    high: days[0]?.high ?? Math.round(body.current.temperature_2m),
    low: days[0]?.low ?? Math.round(body.current.temperature_2m),
    hours,
    days
  }
}

const [reading, setReading] = signal<Reading | null>(null)
const [problem, setProblem] = signal<string | null>(null)
const [busy, setBusy] = signal(false)
// What the text field wrote, until the host sends the saved settings back.
const [typed, setTyped] = signal<string | null>(null)
const [draft, setDraft] = signal("")

const setting = (name: string) => String(cmux.app.settings()[name] ?? "").trim()
const placeName = computed(() => typed() ?? setting("place"))
const fahrenheit = computed(() => setting("units") === "fahrenheit")

function explain(error: unknown): string {
  const e = error as { code?: string; message?: string }
  if (e?.code === "scope.missing") return "Turn on network access for Weather widget in Settings > Apps."
  return e?.message ?? String(error)
}

async function getJSON<T>(url: string): Promise<T> {
  const response = await cmux.net.fetch(url)
  if (!response.ok) throw new Error(`Open-Meteo answered ${response.status}`)
  return response.json<T>()
}

async function locate(name: string): Promise<Place> {
  const body = await getJSON<{ results?: Array<{ name: string; latitude: number; longitude: number }> }>(
    `https://geocoding-api.open-meteo.com/v1/search?count=1&name=${encodeURIComponent(name)}`
  )
  const hit = body.results?.[0]
  if (!hit) throw new Error(`No place called ${name}`)
  return { name: hit.name, latitude: hit.latitude, longitude: hit.longitude }
}

export function forecastURL(place: Place, inFahrenheit: boolean): string {
  return (
    `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude}&longitude=${place.longitude}` +
    "&current=temperature_2m,apparent_temperature,weather_code,is_day" +
    "&hourly=temperature_2m,weather_code,is_day" +
    "&daily=weather_code,temperature_2m_max,temperature_2m_min" +
    `&timezone=auto&forecast_days=7${inFahrenheit ? "&temperature_unit=fahrenheit" : ""}`
  )
}

let located: { name: string; place: Place } | null = null
let inflight: Promise<void> | null = null

/** Reads the forecast for the current setting; `force` skips the 10 minute reuse. */
function load(force = false): Promise<void> {
  const name = placeName()
  if (!name) return Promise.resolve()
  const key = `${name.toLowerCase()}|${fahrenheit() ? "f" : "c"}`
  const last = reading()
  if (!force && last?.key === key && Date.now() - last.at < REUSE_MS) return Promise.resolve()
  if (inflight) return inflight
  const inFahrenheit = fahrenheit()
  setBusy(true)
  inflight = (async () => {
    try {
      const place = located?.name === name ? located.place : await locate(name)
      located = { name, place }
      const forecast = forecastFrom(await getJSON<OpenMeteoForecast>(forecastURL(place, inFahrenheit)))
      // The setting changed while this read was out: its answer is for the old place.
      if (placeName() !== name) return
      setReading({ key, place, forecast, at: Date.now() })
      setProblem(null)
    } catch (error) {
      if (placeName() === name) setProblem(explain(error))
    } finally {
      inflight = null
      setBusy(false)
    }
  })()
  return inflight
}

async function choose(text: string) {
  const name = text.trim()
  if (!name) return
  setTyped(name)
  setDraft("")
  setReading(null)
  cmux.app.settings.set({ place: name }).catch((error) => setProblem(explain(error)))
  await load(true)
}

function changePlace() {
  setTyped("")
  setReading(null)
  setProblem(null)
  cmux.app.settings.set({ place: "" }).catch(() => undefined)
}

function sizeMenu(current: () => Size): View {
  const pick = (size: Size, title: string) =>
    Button(current() === size ? `✓ ${title}` : title, () => void cmux.app.settings.set({ size }).catch(() => undefined))
  return Menu("Size", [pick("small", "Small"), pick("medium", "Medium"), pick("large", "Large")])
}

const secondary = cmux.theme.text.secondary

/** The top of every size: where, how warm, the sky, today's range. */
function now(r: Reading, wide: boolean): View {
  const f = r.forecast
  const sky = describe(f.code, f.day)
  const range = Text(`H:${f.high}°  L:${f.low}°`).font("caption").color(secondary)
  const head = VStack({ spacing: 0, alignment: "leading" }, [
    Text(r.place.name).font("headline").lineLimit(1),
    Text(`${f.temperature}°`).font("largeTitle").weight("light")
  ])
  const sideways = VStack({ spacing: 2, alignment: wide ? "trailing" : "leading" }, [
    Text(sky.glyph).font("title2"),
    Text(sky.text).font("caption").weight("medium").lineLimit(1),
    range
  ])
  return wide ? HStack({ spacing: 8 }, [head, Spacer(), sideways]) : VStack({ spacing: 4, alignment: "leading" }, [head, sideways])
}

/** Six columns spread across the card: a Spacer between each, so both renderers justify them. */
function hours(f: Forecast): View {
  const columns: View[] = []
  f.hours.forEach((h, i) => {
    if (i > 0) columns.push(Spacer())
    columns.push(
      VStack({ spacing: 4, alignment: "center" }, [
        Text(h.label).font("caption2").color(secondary),
        Text(describe(h.code, h.day).glyph).font("body"),
        Text(`${h.temperature}°`).font("caption").weight("medium")
      ])
    )
  })
  return HStack({ spacing: 0 }, columns)
}

function days(f: Forecast): View {
  return VStack({ spacing: 6 }, [
    ForEach({ items: () => f.days, key: (d) => d.label }, (d) =>
      HStack({ spacing: 8 }, [
        Text(() => d().label).font("subheadline").weight("medium").frame({ width: 48 }),
        Text(() => describe(d().code, true).glyph).font("body"),
        Spacer(),
        Text(() => `${d().low}°`).font("subheadline").color(secondary),
        Text(() => `${d().high}°`).font("subheadline").weight("medium")
      ])
    )
  ])
}

export function renderWeather(): View {
  // Each view keeps its own timer (it ends with the view); load() shares one read between them.
  cmux.timer.every(REFRESH_MS, () => void load())
  const size = computed(() => sizeOf(cmux.app.settings().size))
  const key = computed(() => `${placeName()}|${fahrenheit()}`)
  let seen = ""
  const watchKey = () => {
    if (key() !== seen) {
      seen = key()
      void load()
    }
    return null
  }
  return Panel({ style: "card", spacing: 10 }, [
    watchKey,
    () => {
      if (!placeName()) {
        return VStack({ spacing: 6, alignment: "leading" }, [
          Text("⛅️ Weather").font("headline"),
          TextField(draft, { placeholder: "Your city", onEdit: setDraft, onSubmit: choose })
        ])
      }
      const r = reading()
      if (!r) return busy() ? Text(`Reading the weather for ${placeName()}…`).font("caption").color(secondary) : null
      const s = size()
      if (s === "small") return now(r, false)
      if (s === "medium") return VStack({ spacing: 10 }, [now(r, true), hours(r.forecast)])
      return VStack({ spacing: 10 }, [now(r, true), hours(r.forecast), days(r.forecast)])
    },
    () =>
      problem()
        ? Row({ title: "Couldn't read the weather", subtitle: problem(), symbol: "exclamationmark.triangle", tint: cmux.theme.warning }).onTap(() => load(true))
        : null
  ]).contextMenu(() => [sizeMenu(size), ...(placeName() ? [Button("Refresh", () => load(true)), Button("Change place", changePlace)] : [])])
}
