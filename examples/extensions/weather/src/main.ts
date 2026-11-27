// Weather: the current conditions for a place you choose, in a sidebar section. It imports nothing
// but the public SDK.
// - The place and the units are the extension's settings (Settings > Apps > Weather), and the
//   section's own text field writes the same setting, so both stay in step.
// - Open-Meteo answers with no account or key. Its two hosts are net: scopes, which you turn on
//   in Settings > Apps; until then the section says so.
// - It reads the weather when the place changes and every 15 minutes. Several windows share one
//   read: a read younger than 10 minutes is reused.

import { Button, cmux, computed, EmptyState, HStack, Icon, Row, signal, Spacer, Text, TextField, VStack, type View } from "cmux-extension-sdk"

interface Place { name: string; region: string; latitude: number; longitude: number }
interface Conditions { temperature: number; feelsLike: number; code: number; high: number; low: number; wind: number; day: boolean }
interface Reading { key: string; place: Place; now: Conditions; at: number }

const REFRESH_MS = 15 * 60_000
const REUSE_MS = 10 * 60_000

// WMO weather codes as a person reads them, with a day and a night symbol.
function describe(code: number, day: boolean): { text: string; symbol: string } {
  if (code === 0) return { text: "Clear", symbol: day ? "sun.max" : "moon.stars" }
  if (code <= 2) return { text: "Partly cloudy", symbol: day ? "cloud.sun" : "cloud.moon" }
  if (code === 3) return { text: "Overcast", symbol: "cloud" }
  if (code <= 48) return { text: "Fog", symbol: "cloud.fog" }
  if (code <= 57) return { text: "Drizzle", symbol: "cloud.drizzle" }
  if (code <= 67) return { text: "Rain", symbol: "cloud.rain" }
  if (code <= 77) return { text: "Snow", symbol: "cloud.snow" }
  if (code <= 82) return { text: "Showers", symbol: "cloud.heavyrain" }
  if (code <= 86) return { text: "Snow showers", symbol: "cloud.snow" }
  return { text: "Thunderstorm", symbol: "cloud.bolt.rain" }
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
  if (e?.code === "scope.missing") return "Turn on network access for Weather in Settings > Apps."
  return e?.message ?? String(error)
}

async function getJSON<T>(url: string): Promise<T> {
  const response = await cmux.net.fetch(url)
  if (!response.ok) throw new Error(`Open-Meteo answered ${response.status}`)
  return response.json<T>()
}

async function locate(name: string): Promise<Place> {
  const body = await getJSON<{ results?: Array<{ name: string; admin1?: string; country?: string; latitude: number; longitude: number }> }>(
    `https://geocoding-api.open-meteo.com/v1/search?count=1&name=${encodeURIComponent(name)}`
  )
  const hit = body.results?.[0]
  if (!hit) throw new Error(`No place called ${name}`)
  return { name: hit.name, region: hit.admin1 ?? hit.country ?? "", latitude: hit.latitude, longitude: hit.longitude }
}

async function forecast(place: Place, inFahrenheit: boolean): Promise<Conditions> {
  const units = inFahrenheit ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : ""
  const body = await getJSON<{
    current: { temperature_2m: number; apparent_temperature: number; weather_code: number; wind_speed_10m: number; is_day: number }
    daily: { temperature_2m_max: number[]; temperature_2m_min: number[] }
  }>(
    `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude}&longitude=${place.longitude}` +
      "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day" +
      `&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1${units}`
  )
  return {
    temperature: Math.round(body.current.temperature_2m),
    feelsLike: Math.round(body.current.apparent_temperature),
    code: body.current.weather_code,
    wind: Math.round(body.current.wind_speed_10m),
    day: body.current.is_day === 1,
    high: Math.round(body.daily.temperature_2m_max[0]!),
    low: Math.round(body.daily.temperature_2m_min[0]!)
  }
}

let located: { name: string; place: Place } | null = null
let inflight: Promise<void> | null = null

/** Reads the weather for the current setting; `force` skips the 10 minute reuse. */
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
      const now = await forecast(place, inFahrenheit)
      // The setting changed while this read was out: its answer is for the old place.
      if (placeName() !== name) return
      setReading({ key, place, now, at: Date.now() })
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

function conditions(r: Reading): View {
  const d = describe(r.now.code, r.now.day)
  const unit = r.key.endsWith("|f") ? "mph" : "km/h"
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Icon(d.symbol).font("title2"),
      Text(`${r.now.temperature}°`).font("title").weight("semibold"),
      Spacer(),
      VStack({ spacing: 0 }, [Text(r.place.name).font("headline").lineLimit(1), Text(r.place.region).font("caption").color(cmux.theme.text.secondary).lineLimit(1)])
    ]),
    Text(`${d.text} · feels like ${r.now.feelsLike}°`).color(cmux.theme.text.secondary).lineLimit(1),
    Text(`High ${r.now.high}° · low ${r.now.low}° · wind ${r.now.wind} ${unit}`).font("caption").color(cmux.theme.text.secondary).lineLimit(1)
  ])
}

export function renderWeather(): View {
  // Each view keeps its own timer (it ends with the view); load() shares one read between them.
  cmux.timer.every(REFRESH_MS, () => void load())
  // The place or the units changed (here or in Settings): read again.
  const key = computed(() => `${placeName()}|${fahrenheit()}`)
  let seen = ""
  const watchKey = () => {
    if (key() !== seen) {
      seen = key()
      void load()
    }
    return null
  }
  return VStack({ spacing: 4 }, [
    watchKey,
    () => {
      if (!placeName()) {
        return VStack({ spacing: 4 }, [
          Text("Where are you?").font("headline"),
          TextField(draft, { placeholder: "A city, for the weather", onEdit: setDraft, onSubmit: choose })
        ])
      }
      const r = reading()
      if (r) return conditions(r)
      if (busy()) return EmptyState({ title: `Reading the weather for ${placeName()}…`, symbol: "cloud.sun" })
      return null
    },
    () =>
      problem()
        ? Row({ title: "Couldn't read the weather", subtitle: problem(), symbol: "exclamationmark.triangle", tint: cmux.theme.warning }).onTap(() => load(true))
        : null
  ]).contextMenu(() => (placeName() ? [Button("Refresh weather", () => load(true)), Button("Change place", changePlace)] : []))
}
