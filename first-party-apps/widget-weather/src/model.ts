// The weather widget's data, with no host calls: Open-Meteo's answer turned into what the widget
// draws (current conditions, the next hours, the next days), the units and clock a person reads,
// and the sky behind it. Every function here is pure, so the tests and the preview fixtures drive
// it directly. A forecast is kept in Celsius with Open-Meteo's local times; units and the clock
// are applied when it is drawn, so changing them never needs another read.

export interface Place {
  name: string
  region: string
  /** ISO 3166 code ("US"), when the lookup gave one. */
  country: string
  latitude: number
  longitude: number
  /** How the place was found: typed in Settings, or guessed from the internet address. */
  source: "typed" | "approximate"
}

export interface Hour {
  /** The place's local time, "2026-11-16T22:00". */
  time: string
  /** Celsius. */
  temperature: number
  code: number
  day: boolean
}

export interface Day {
  /** The place's local date, "2026-11-16". */
  date: string
  today: boolean
  code: number
  /** Celsius. */
  high: number
  low: number
}

export interface Forecast {
  /** Celsius. */
  temperature: number
  code: number
  day: boolean
  high: number
  low: number
  hours: Hour[]
  days: Day[]
}

export interface Units {
  fahrenheit: boolean
  twelveHour: boolean
}

/** Open-Meteo's /v1/forecast answer, the fields the widget asks for. */
export interface OpenMeteoForecast {
  current: { time: string; temperature_2m: number; weather_code: number; is_day: number }
  hourly: { time: string[]; temperature_2m: number[]; weather_code: number[]; is_day: number[] }
  daily: { time: string[]; weather_code: number[]; temperature_2m_max: number[]; temperature_2m_min: number[] }
}

export const HOURS_SHOWN = 6
export const DAYS_SHOWN = 6

// Regions whose people read Fahrenheit (Apple's list), and the ones that read a 12-hour clock.
const FAHRENHEIT = new Set(["US", "BS", "BZ", "KY", "LR", "PW", "FM", "MH", "PR", "GU", "VI", "AS", "MP", "UM"])
const TWELVE_HOUR = new Set(["US", "CA", "AU", "NZ", "IN", "PH", "PK", "BD", "EG", "SA", "CO", "MY", "PR", "GU", "VI", "AS", "MP"])

/** The region of a locale like "en-US", "en_US" or "zh-Hant-TW"; "" for a bare language ("en"). */
export function localeRegion(locale: string): string {
  const parts = locale.replace(/_/g, "-").split("-").slice(1)
  return (parts.find((part) => /^[A-Za-z]{2}$/.test(part)) ?? "").toUpperCase()
}

/**
 * The units a person reads: the Units setting when it picks one, else the locale's region, else
 * (a locale with no region, which is what hosts send today) the country of the place shown.
 */
export function unitsFor(locale: string, setting: unknown, country = ""): Units {
  const region = localeRegion(locale) || country.toUpperCase()
  const fahrenheit = setting === "fahrenheit" ? true : setting === "celsius" ? false : FAHRENHEIT.has(region)
  return { fahrenheit, twelveHour: TWELVE_HOUR.has(region) }
}

/** A Celsius reading in the person's units, rounded as Weather shows it. */
export function shown(celsius: number, units: Units): number {
  const value = units.fahrenheit ? (celsius * 9) / 5 + 32 : celsius
  // Math.round(-0.4) is -0: draw it as 0.
  return Math.round(value) || 0
}

export interface Condition {
  text: string
  symbol: string
}

/** A WMO weather code as Apple's Weather names it, with its SF Symbol by day and by night. */
export function describe(code: number, day: boolean): Condition {
  if (code === 0) return day ? { text: "Sunny", symbol: "sun.max.fill" } : { text: "Clear", symbol: "moon.stars.fill" }
  if (code === 1) return day ? { text: "Mostly Sunny", symbol: "sun.max.fill" } : { text: "Mostly Clear", symbol: "moon.stars.fill" }
  if (code === 2) return { text: "Partly Cloudy", symbol: day ? "cloud.sun.fill" : "cloud.moon.fill" }
  if (code === 3) return { text: "Cloudy", symbol: "cloud.fill" }
  if (code === 45 || code === 48) return { text: "Foggy", symbol: "cloud.fog.fill" }
  if (code >= 51 && code <= 55) return { text: "Drizzle", symbol: "cloud.drizzle.fill" }
  if (code === 56 || code === 57) return { text: "Freezing Drizzle", symbol: "cloud.sleet.fill" }
  if (code === 61 || code === 63) return { text: "Rain", symbol: "cloud.rain.fill" }
  if (code === 65) return { text: "Heavy Rain", symbol: "cloud.heavyrain.fill" }
  if (code === 66 || code === 67) return { text: "Freezing Rain", symbol: "cloud.sleet.fill" }
  if (code === 71 || code === 73) return { text: "Snow", symbol: "cloud.snow.fill" }
  if (code === 75) return { text: "Heavy Snow", symbol: "snowflake" }
  if (code === 77) return { text: "Flurries", symbol: "cloud.snow.fill" }
  if (code === 80 || code === 81) return { text: "Showers", symbol: day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill" }
  if (code === 82) return { text: "Heavy Showers", symbol: "cloud.heavyrain.fill" }
  if (code === 85 || code === 86) return { text: "Snow Showers", symbol: "cloud.snow.fill" }
  if (code >= 95) return { text: "Thunderstorms", symbol: "cloud.bolt.rain.fill" }
  return { text: "Cloudy", symbol: "cloud.fill" }
}

/** Apple's symbols are multicolor; the scene draws one color, so a lone sun is yellow and the rest white. */
export function symbolColor(symbol: string): string {
  return symbol === "sun.max.fill" ? "#FFD60A" : "#FFFFFF"
}

export type Sky = "clear-day" | "clear-night" | "cloudy-day" | "cloudy-night" | "rain-day" | "rain-night" | "snow" | "fog" | "storm"

/** The sky behind the widget, as Apple's Weather paints it: blue by day, navy at night, grey for rain. */
export function skyFor(code: number, day: boolean): Sky {
  if (code >= 95) return "storm"
  if (code === 45 || code === 48) return "fog"
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return "snow"
  if (code >= 51) return day ? "rain-day" : "rain-night"
  if (code === 3) return day ? "cloudy-day" : "cloudy-night"
  return day ? "clear-day" : "clear-night"
}

/** One color per sky (the scene has no gradients yet): the middle of Apple's gradient for it. */
export const SKY_COLORS: Record<Sky, string> = {
  "clear-day": "#3A86D4",
  "clear-night": "#14203A",
  "cloudy-day": "#62798F",
  "cloudy-night": "#272F3C",
  "rain-day": "#4F6274",
  "rain-night": "#1E2631",
  snow: "#7F93A8",
  fog: "#717D88",
  storm: "#363A4B"
}

/** "10 PM" or "22" from Open-Meteo's local "2026-11-16T22:00". */
export function hourLabel(time: string, twelveHour: boolean): string {
  const hour = Number(time.slice(11, 13))
  if (!twelveHour) return String(hour).padStart(2, "0")
  const h = hour % 12 === 0 ? 12 : hour % 12
  return `${h} ${hour < 12 ? "AM" : "PM"}`
}

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/** "Mon" from "2026-11-16" (the place's own date, so no time zone is involved). */
export function weekday(date: string): string {
  const [y, m, d] = date.split("-").map(Number)
  return WEEKDAYS[new Date(Date.UTC(y!, m! - 1, d!)).getUTCDay()]!
}

/** Open-Meteo's answer as the widget keeps it: the hours after the current one, today and the days after. */
export function toForecast(body: OpenMeteoForecast): Forecast {
  const now = body.current.time
  // The first hour after the current one (the current hour is the big number).
  const nowHour = now.slice(0, 13)
  let start = body.hourly.time.findIndex((t) => t.slice(0, 13) > nowHour)
  if (start < 0) start = body.hourly.time.length
  const hours: Hour[] = []
  for (let i = start; i < body.hourly.time.length && hours.length < HOURS_SHOWN; i++) {
    hours.push({ time: body.hourly.time[i]!, temperature: body.hourly.temperature_2m[i]!, code: body.hourly.weather_code[i]!, day: body.hourly.is_day[i] === 1 })
  }
  const today = now.slice(0, 10)
  let first = body.daily.time.indexOf(today)
  if (first < 0) first = 0
  const days: Day[] = []
  for (let i = first; i < body.daily.time.length && days.length < DAYS_SHOWN; i++) {
    days.push({
      date: body.daily.time[i]!,
      today: i === first,
      code: body.daily.weather_code[i]!,
      high: body.daily.temperature_2m_max[i]!,
      low: body.daily.temperature_2m_min[i]!
    })
  }
  const temperature = body.current.temperature_2m
  const todayRange = days[0] ?? { high: temperature, low: temperature }
  return {
    temperature,
    code: body.current.weather_code,
    day: body.current.is_day === 1,
    // The day's range always holds the current reading, as Apple's does.
    high: Math.max(todayRange.high, temperature),
    low: Math.min(todayRange.low, temperature),
    hours,
    days
  }
}

/** Whether a decoded body has the parts toForecast reads. */
export function isForecast(body: unknown): body is OpenMeteoForecast {
  const b = body as Partial<OpenMeteoForecast> | null
  return !!b?.current && Array.isArray(b.hourly?.time) && Array.isArray(b.daily?.time)
}

/** The forecast URL for a place (Celsius; the widget converts). */
export function forecastURL(place: Pick<Place, "latitude" | "longitude">): string {
  return (
    `https://api.open-meteo.com/v1/forecast?latitude=${place.latitude.toFixed(3)}&longitude=${place.longitude.toFixed(3)}` +
    "&current=temperature_2m,weather_code,is_day" +
    "&hourly=temperature_2m,weather_code,is_day&forecast_hours=24" +
    `&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=${DAYS_SHOWN + 1}&timezone=auto`
  )
}

export const GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search?count=1&name="
export const IP_LOCATION_URL = "https://get.geojs.io/v1/ip/geo.json"

/** GeoJS's answer for the caller's internet address (its numbers are strings). */
export interface GeoJS {
  city?: string
  region?: string
  country?: string
  country_code?: string
  latitude?: string | number
  longitude?: string | number
}

export function placeFromGeoJS(body: GeoJS): Place | null {
  const latitude = Number(body.latitude)
  const longitude = Number(body.longitude)
  if (body.latitude == null || body.longitude == null || !Number.isFinite(latitude) || !Number.isFinite(longitude)) return null
  const name = body.city || body.region || body.country || "Your area"
  const region = body.city ? body.region || body.country || "" : body.country || ""
  return { name, region, country: body.country_code ?? "", latitude, longitude, source: "approximate" }
}

export interface GeocodeResult {
  results?: Array<{ name: string; admin1?: string; country?: string; country_code?: string; latitude: number; longitude: number }>
}

export function placeFromGeocode(body: GeocodeResult): Place | null {
  const hit = body.results?.[0]
  if (!hit) return null
  return {
    name: hit.name,
    region: hit.admin1 ?? hit.country ?? "",
    country: hit.country_code ?? "",
    latitude: hit.latitude,
    longitude: hit.longitude,
    source: "typed"
  }
}

/** The week's span for the large size's range bars, in the units drawn. */
export function weekRange(days: Day[], units: Units): { min: number; max: number } {
  if (days.length === 0) return { min: 0, max: 1 }
  const min = Math.min(...days.map((d) => shown(d.low, units)))
  const max = Math.max(...days.map((d) => shown(d.high, units)))
  return { min, max: max === min ? min + 1 : max }
}
