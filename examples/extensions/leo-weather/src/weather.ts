// The data half of leo-weather: where you are, what the sky is doing there, and the next 12 hours.
// Open-Meteo answers with no account or key; each host it reads is a `net:` scope in cmux-app.json.
import { cmux } from "cmux-extension-sdk"

export type Kind = "clear" | "cloudy" | "fog" | "rain" | "snow" | "storm"
export interface Place { name: string; region: string; latitude: number; longitude: number }
export interface Reading {
  place: Place
  temperature: number; feelsLike: number; high: number; low: number; wind: number
  code: number; day: boolean; hour: number // the place's local hour, 0-23
  hours: Array<{ label: string; temperature: number }> // the next 12 hours
}

/** WMO weather code as a person reads it, and the sky to draw for it. */
export function describe(code: number): { text: string; kind: Kind; partly: boolean; heavy: boolean } {
  if (code <= 1) return { text: code ? "Mostly clear" : "Clear", kind: "clear", partly: false, heavy: false }
  if (code === 2) return { text: "Partly cloudy", kind: "clear", partly: true, heavy: false }
  if (code === 3) return { text: "Overcast", kind: "cloudy", partly: false, heavy: false }
  if (code <= 48) return { text: "Fog", kind: "fog", partly: false, heavy: false }
  if (code <= 57) return { text: "Drizzle", kind: "rain", partly: false, heavy: false }
  if (code <= 67) return { text: "Rain", kind: "rain", partly: false, heavy: code === 65 || code === 67 }
  if (code <= 77) return { text: "Snow", kind: "snow", partly: false, heavy: code >= 75 }
  if (code <= 82) return { text: "Showers", kind: "rain", partly: false, heavy: code === 82 }
  if (code <= 86) return { text: "Snow showers", kind: "snow", partly: false, heavy: code === 86 }
  return { text: "Thunderstorm", kind: "storm", partly: false, heavy: true }
}

async function getJSON<T>(url: string): Promise<T> {
  const response = await cmux.net.fetch(url)
  if (!response.ok) throw new Error(`${url.split("/")[2]} answered ${response.status}`)
  return response.json<T>()
}

export async function placeNamed(name: string): Promise<Place> {
  const body = await getJSON<{ results?: Array<{ name: string; admin1?: string; country?: string; latitude: number; longitude: number }> }>(
    `https://geocoding-api.open-meteo.com/v1/search?count=1&name=${encodeURIComponent(name)}`
  )
  const hit = body.results?.[0]
  if (!hit) throw new Error(`No place called ${name}`)
  return { name: hit.name, region: hit.admin1 ?? hit.country ?? "", latitude: hit.latitude, longitude: hit.longitude }
}

/** Opt-in (setting `approximateLocation`, off by default): the city your IP address maps to. */
export async function placeFromIP(): Promise<Place> {
  const b = await getJSON<{ city?: string; region?: string; country?: string; latitude: string; longitude: string }>("https://get.geojs.io/v1/ip/geo.json")
  return { name: b.city || "Near you", region: b.region || b.country || "", latitude: Number(b.latitude), longitude: Number(b.longitude) }
}

const hourLabel = (h: number) => (h === 0 ? "12a" : h < 12 ? `${h}a` : h === 12 ? "12p" : `${h - 12}p`)
const hourOf = (iso: string) => Number(iso.slice(11, 13))

export async function forecast(place: Place, fahrenheit: boolean): Promise<Reading> {
  const units = fahrenheit ? "&temperature_unit=fahrenheit&wind_speed_unit=mph" : ""
  const b = await getJSON<{
    current: { time: string; temperature_2m: number; apparent_temperature: number; weather_code: number; wind_speed_10m: number; is_day: number }
    hourly: { time: string[]; temperature_2m: number[] }
    daily: { temperature_2m_max: number[]; temperature_2m_min: number[] }
  }>(
    `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude}&longitude=${place.longitude}` +
      "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,is_day" +
      `&hourly=temperature_2m&forecast_hours=12&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1${units}`
  )
  return {
    place,
    temperature: Math.round(b.current.temperature_2m),
    feelsLike: Math.round(b.current.apparent_temperature),
    high: Math.round(b.daily.temperature_2m_max[0]!),
    low: Math.round(b.daily.temperature_2m_min[0]!),
    wind: Math.round(b.current.wind_speed_10m),
    code: b.current.weather_code,
    day: b.current.is_day === 1,
    hour: hourOf(b.current.time),
    hours: b.hourly.time.map((t, i) => ({ label: hourLabel(hourOf(t)), temperature: Math.round(b.hourly.temperature_2m[i]!) }))
  }
}

/** A made-up reading for the `preview` setting, so each sky can be shown without the network. */
export function preview(kind: string, tick: number): Reading {
  const code = { sun: 0, rain: 63, snow: 73, storm: 95, night: 1, cloudy: 3 }[kind] ?? 0
  const base = kind === "snow" ? -2 : kind === "night" ? 9 : 18
  const hours = Array.from({ length: 12 }, (_, i) => ({
    label: hourLabel((14 + i) % 24),
    temperature: Math.round(base + 4 * Math.sin((i + tick) / 2) + ((i * 7 + tick * 3) % 5) - 2)
  }))
  return {
    place: { name: "Preview", region: `${kind} sky`, latitude: 0, longitude: 0 },
    temperature: hours[0]!.temperature, feelsLike: hours[0]!.temperature - 2, high: base + 5, low: base - 4, wind: 12,
    code, day: kind !== "night", hour: kind === "night" ? 22 : 14, hours
  }
}
