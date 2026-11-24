// Invented Open-Meteo answers for the tests and the preview states: one per sky the gallery shows.
// Temperatures are Celsius, as the widget asks for them; times are the place's local time.
import type { GeoJS, OpenMeteoForecast } from "../src/model.ts"

type Sample = { code: number; temperature: number; day: boolean }

function hourly(start: string, samples: Sample[]): OpenMeteoForecast["hourly"] {
  const day = start.slice(0, 11)
  const first = Number(start.slice(11, 13))
  const time = samples.map((_, i) => {
    const h = first + i
    const date = h >= 24 ? nextDay(day.slice(0, 10)) + "T" : day
    return `${date}${String(h % 24).padStart(2, "0")}:00`
  })
  return { time, temperature_2m: samples.map((s) => s.temperature), weather_code: samples.map((s) => s.code), is_day: samples.map((s) => (s.day ? 1 : 0)) }
}

function nextDay(date: string, by = 1): string {
  const [y, m, d] = date.split("-").map(Number)
  return new Date(Date.UTC(y!, m! - 1, d! + by)).toISOString().slice(0, 10)
}

function daily(start: string, rows: Array<[code: number, high: number, low: number]>): OpenMeteoForecast["daily"] {
  return {
    time: rows.map((_, i) => nextDay(start, i)),
    weather_code: rows.map((r) => r[0]),
    temperature_2m_max: rows.map((r) => r[1]),
    temperature_2m_min: rows.map((r) => r[2])
  }
}

/** A sunny morning in Cupertino (21 °C, 70 °F), as in Apple's own widget picture. */
export const clearDay: OpenMeteoForecast = {
  current: { time: "2026-06-05T09:45", temperature_2m: 21.1, weather_code: 0, is_day: 1 },
  hourly: hourly("2026-06-05T09:00", [
    { code: 0, temperature: 21, day: true },
    { code: 0, temperature: 25, day: true },
    { code: 1, temperature: 26.7, day: true },
    { code: 2, temperature: 27.2, day: true },
    { code: 2, temperature: 27.2, day: true },
    { code: 0, temperature: 29.4, day: true },
    { code: 0, temperature: 31.1, day: true }
  ]),
  daily: daily("2026-06-05", [
    [0, 23.9, 15],
    [1, 26, 14],
    [2, 24, 13],
    [3, 21, 12],
    [61, 18, 11],
    [0, 22, 12],
    [0, 24, 13]
  ])
}

/** A rainy afternoon in Lisbon. */
export const rainDay: OpenMeteoForecast = {
  current: { time: "2026-11-16T14:20", temperature_2m: 14.4, weather_code: 63, is_day: 1 },
  hourly: hourly("2026-11-16T14:00", [
    { code: 63, temperature: 14.4, day: true },
    { code: 63, temperature: 14.1, day: true },
    { code: 65, temperature: 13.6, day: true },
    { code: 81, temperature: 13.2, day: true },
    { code: 80, temperature: 12.8, day: false },
    { code: 3, temperature: 12.4, day: false },
    { code: 3, temperature: 12, day: false }
  ]),
  daily: daily("2026-11-16", [
    [63, 15.8, 11.2],
    [80, 16, 10],
    [3, 17, 11],
    [2, 18, 12],
    [0, 19, 11],
    [61, 15, 10],
    [3, 16, 10]
  ])
}

/** A clear night in Tokyo. */
export const clearNight: OpenMeteoForecast = {
  current: { time: "2026-11-16T22:10", temperature_2m: 9.6, weather_code: 0, is_day: 0 },
  hourly: hourly("2026-11-16T22:00", [
    { code: 0, temperature: 9.6, day: false },
    { code: 0, temperature: 9, day: false },
    { code: 1, temperature: 8.4, day: false },
    { code: 2, temperature: 7.9, day: false },
    { code: 2, temperature: 7.5, day: false },
    { code: 0, temperature: 7.1, day: false },
    { code: 0, temperature: 6.8, day: false }
  ]),
  daily: daily("2026-11-16", [
    [1, 16.2, 7.8],
    [0, 17, 8],
    [2, 15, 9],
    [61, 13, 9],
    [3, 14, 8],
    [0, 16, 7],
    [0, 17, 8]
  ])
}

/** Snow in Denver, below freezing. */
export const snow: OpenMeteoForecast = {
  current: { time: "2026-12-02T08:30", temperature_2m: -3.4, weather_code: 73, is_day: 1 },
  hourly: hourly("2026-12-02T08:00", [
    { code: 73, temperature: -3.4, day: true },
    { code: 73, temperature: -2.8, day: true },
    { code: 75, temperature: -2.2, day: true },
    { code: 71, temperature: -1.5, day: true },
    { code: 71, temperature: -1, day: true },
    { code: 3, temperature: -0.6, day: true },
    { code: 3, temperature: -0.4, day: true }
  ]),
  daily: daily("2026-12-02", [
    [73, -0.2, -6.1],
    [3, 2, -7],
    [0, 5, -5],
    [0, 7, -3],
    [71, 1, -6],
    [2, 4, -4],
    [0, 6, -3]
  ])
}

export const places = {
  cupertino: { city: "Cupertino", region: "California", country: "United States", country_code: "US", latitude: "37.323", longitude: "-122.032" } satisfies GeoJS,
  lisbon: { city: "Lisbon", region: "Lisbon", country: "Portugal", country_code: "PT", latitude: "38.716", longitude: "-9.133" } satisfies GeoJS,
  tokyo: { city: "Tokyo", region: "Tokyo", country: "Japan", country_code: "JP", latitude: "35.689", longitude: "139.692" } satisfies GeoJS,
  denver: { city: "Denver", region: "Colorado", country: "United States", country_code: "US", latitude: "39.739", longitude: "-104.990" } satisfies GeoJS
}
