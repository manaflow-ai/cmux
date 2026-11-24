// The forecast the Add Widget gallery shows (a preview reads and writes nothing): a sunny
// morning, in Celsius with local times like Open-Meteo's, so it draws in the person's own units.
import type { Forecast, Place } from "./model.ts"

export const SAMPLE_PLACE: Place = { name: "Cupertino", region: "California", country: "US", latitude: 37.323, longitude: -122.032, source: "approximate" }

const hours: Array<[string, number, number]> = [
  ["10", 25, 0],
  ["11", 26.7, 1],
  ["12", 27.2, 2],
  ["13", 27.2, 2],
  ["14", 29.4, 0],
  ["15", 31.1, 0]
]
const days: Array<[string, number, number, number]> = [
  ["2026-06-05", 0, 23.9, 15],
  ["2026-06-06", 1, 26, 14],
  ["2026-06-07", 2, 24, 13],
  ["2026-06-08", 3, 21, 12],
  ["2026-06-09", 61, 18, 11],
  ["2026-06-10", 0, 22, 12]
]

export const SAMPLE_FORECAST: Forecast = {
  temperature: 21.1,
  code: 0,
  day: true,
  high: 23.9,
  low: 15,
  hours: hours.map(([h, temperature, code]) => ({ time: `2026-06-05T${h}:00`, temperature, code, day: true })),
  days: days.map(([date, code, high, low], i) => ({ date, today: i === 0, code, high, low }))
}
