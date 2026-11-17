// The clock's model, with no view and no host: what the widget shows at an instant.
// The sandbox has no Intl, so names and formats are written here (English) and zone rules
// come from cmux.time.zone (passed in as `zoneOf`, so tests and previews can supply their own).

export type HourCycle = "system" | "12h" | "24h"
export type Face = "digital" | "analog"
export type Size = "small" | "medium" | "large"

/** The time's look (the options of the New Tab clock this widget replaces, cmux#44388). */
export type FontChoice = "rounded" | "system" | "serif" | "mono" | "condensed"
export type WeightChoice = "thin" | "light" | "regular" | "medium" | "semibold" | "bold" | "heavy"

export interface Settings {
  hourCycle?: HourCycle
  cities?: string
  face?: Face
  font?: FontChoice
  weight?: WeightChoice
  /** text, accent, muted, glass, or a #RRGGBB color. */
  color?: string
  /** The date over the time. */
  date?: boolean
}

export interface ZoneInfo {
  offsetMinutes: number
  abbreviation: string
}
export type ZoneOf = (zone: string, at: number) => ZoneInfo

/** Shown with zero setup. A city at the person's own offset is skipped, so nobody sees their own time twice. */
export const DEFAULT_CITIES = "America/Los_Angeles, America/New_York, Europe/London, Asia/Tokyo, Australia/Sydney"
const MINUTE = 60_000
const DAY = 86_400_000

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
/** Regions whose everyday clock is 12-hour (used when the runtime has no Intl to ask). */
const TWELVE_HOUR_REGIONS = new Set(["US", "CA", "AU", "NZ", "IN", "PH", "PK", "BD", "EG", "SA", "KR", "MY", "CO"])

const two = (n: number) => String(n).padStart(2, "0")

/** Whether the person's locale writes a 12-hour clock: Intl when the runtime has it, else by region. */
export function localeIsTwelveHour(locale: string | undefined): boolean {
  try {
    const intl = (globalThis as { Intl?: typeof Intl }).Intl
    if (intl?.DateTimeFormat) return new intl.DateTimeFormat(locale || undefined, { hour: "numeric" }).resolvedOptions().hour12 === true
  } catch {
    // An unknown locale tag: fall through to the table.
  }
  const tag = (locale || "en-US").replace(/_/g, "-")
  const [language, ...rest] = tag.split("-")
  const region = rest.find((part) => /^[A-Za-z]{2}$/.test(part))?.toUpperCase()
  if (region) return TWELVE_HOUR_REGIONS.has(region)
  return language?.toLowerCase() === "en"
}

export function twelveHour(settings: Settings, locale: string | undefined): boolean {
  if (settings.hourCycle === "12h") return true
  if (settings.hourCycle === "24h") return false
  return localeIsTwelveHour(locale)
}

/** A wall clock read through the UTC getters: `wall(at, offset)` is the time at that offset. */
export const wall = (at: number, offsetMinutes: number) => new Date(at + offsetMinutes * MINUTE)
export const localOffset = (at: number) => -new Date(at).getTimezoneOffset()

export interface TimeParts {
  /** "9:41" or "09:41" */
  time: string
  /** "AM" or "PM" on a 12-hour clock, else "" */
  period: string
}

export function timeParts(clock: Date, twelve: boolean): TimeParts {
  const h = clock.getUTCHours()
  const m = two(clock.getUTCMinutes())
  if (!twelve) return { time: `${two(h)}:${m}`, period: "" }
  return { time: `${h % 12 || 12}:${m}`, period: h < 12 ? "AM" : "PM" }
}

/** The Lock Screen's date line: "Monday, November 16". */
export const dateLine = (clock: Date) => `${WEEKDAYS[clock.getUTCDay()]}, ${MONTHS[clock.getUTCMonth()]} ${clock.getUTCDate()}`
/** "MONDAY" */
export const weekday = (clock: Date) => WEEKDAYS[clock.getUTCDay()]!.toUpperCase()
/** "Nov 16" */
export const shortDate = (clock: Date) => `${MONTHS[clock.getUTCMonth()]!.slice(0, 3)} ${clock.getUTCDate()}`
/** "MON" */
export const shortWeekday = (clock: Date) => WEEKDAYS[clock.getUTCDay()]!.slice(0, 3).toUpperCase()

/** "America/Los_Angeles" is "Los Angeles"; "America/Argentina/Buenos_Aires" is "Buenos Aires". */
export const cityName = (zone: string) => (zone.split("/").at(-1) ?? zone).replace(/_/g, " ")

/** The person's zones, in order, without repeats; the defaults when the setting is empty. */
export function zonesFrom(setting: unknown): string[] {
  const text = typeof setting === "string" && setting.trim() ? setting : DEFAULT_CITIES
  const seen = new Set<string>()
  return text
    .split(/[,\n]/)
    .map((zone) => zone.trim())
    .filter((zone) => zone && !seen.has(zone) && (seen.add(zone), true))
}

export interface City {
  zone: string
  name: string
  time: string
  period: string
  /** "+8h", "−3h", "+5:30h"; "" at the person's own offset */
  offset: string
  /** "Today", "Tomorrow" or "Yesterday" */
  day: string
  /** For an analog dial: hour and minute hand angles (degrees from 12 o'clock). */
  hourAngle: number
  minuteAngle: number
  /** Night at that city (before 6 AM or from 6 PM): a dark dial, as Apple's World Clock does. */
  night: boolean
  /** The zone name is not one cmux knows */
  problem: boolean
}

function relative(minutes: number): string {
  if (minutes === 0) return ""
  const abs = Math.abs(minutes)
  const rest = abs % 60
  return `${minutes > 0 ? "+" : "−"}${Math.floor(abs / 60)}${rest ? `:${two(rest)}` : ""}h`
}

/**
 * Hand angles in degrees clockwise from 12. They only grow (whole turns are kept, not wrapped), so
 * a hand the host animates moves forward from :59 to :00 instead of spinning back a full turn.
 */
export function handAngles(clock: Date): { hourAngle: number; minuteAngle: number } {
  const minutes = Math.floor(clock.getTime() / 60_000)
  return { hourAngle: minutes * 0.5, minuteAngle: minutes * 6 }
}

export function city(zone: string, at: number, twelve: boolean, zoneOf: ZoneOf): City {
  const name = cityName(zone)
  try {
    const { offsetMinutes } = zoneOf(zone, at)
    const here = localOffset(at)
    const clock = wall(at, offsetMinutes)
    const mine = wall(at, here)
    const days = Math.round((Date.UTC(clock.getUTCFullYear(), clock.getUTCMonth(), clock.getUTCDate()) - Date.UTC(mine.getUTCFullYear(), mine.getUTCMonth(), mine.getUTCDate())) / DAY)
    const hour = clock.getUTCHours()
    return {
      zone,
      name,
      ...timeParts(clock, twelve),
      offset: relative(offsetMinutes - here),
      day: days === 0 ? "Today" : days > 0 ? "Tomorrow" : "Yesterday",
      ...handAngles(clock),
      night: hour < 6 || hour >= 18,
      problem: false
    }
  } catch {
    return { zone, name, time: "--:--", period: "", offset: "", day: "Unknown zone", hourAngle: 0, minuteAngle: 0, night: false, problem: true }
  }
}

/**
 * The cities a widget shows: the person's list, minus cities at their own offset when the list is
 * the default one (an explicit list is shown as written), at most `count`.
 */
export function cities(setting: unknown, at: number, twelve: boolean, zoneOf: ZoneOf, count: number): City[] {
  const explicit = typeof setting === "string" && setting.trim() !== ""
  const all = zonesFrom(setting).map((zone) => city(zone, at, twelve, zoneOf))
  const shown = explicit ? all : all.filter((c) => c.offset !== "")
  return shown.slice(0, count)
}

/** Milliseconds from `at` to just after the next minute starts: one tick per minute, on the minute. */
export const untilNextMinute = (at: number) => MINUTE - (at % MINUTE) + 25

/** How many cities each size lists. */
export const CITY_COUNT: Record<Size, number> = { small: 0, medium: 2, large: 4 }

export function sizeOf(value: unknown): Size {
  return value === "medium" || value === "large" ? value : "small"
}

const FONTS: readonly FontChoice[] = ["rounded", "system", "serif", "mono", "condensed"]
const WEIGHTS: readonly WeightChoice[] = ["thin", "light", "regular", "medium", "semibold", "bold", "heavy"]
const NAMED_COLORS: Record<string, string> = { text: "primary", accent: "accent", muted: "secondary", glass: "primary" }

/** How the big time is drawn. `design` is the scene's font design (condensed has none yet: the system design). */
export interface TimeStyle {
  font: FontChoice
  design: "rounded" | "default" | "serif" | "monospaced"
  weight: WeightChoice
  /** A scene color: a theme token or #RRGGBB. */
  color: string
  /** Glass: the theme's text, translucent. */
  opacity: number
}

/** Reads the look settings; a value that is no choice reads as the default (rounded, heavy, the theme's text). */
export function timeStyle(settings: Settings): TimeStyle {
  const font = FONTS.includes(settings.font as FontChoice) ? (settings.font as FontChoice) : "rounded"
  const weight = WEIGHTS.includes(settings.weight as WeightChoice) ? (settings.weight as WeightChoice) : "heavy"
  const raw = typeof settings.color === "string" ? settings.color.trim() : ""
  const hex = /^#[\da-f]{6}$/i.test(raw) ? raw.toUpperCase() : undefined
  const named = raw.toLowerCase()
  const color = hex ?? NAMED_COLORS[named] ?? "primary"
  const design = font === "rounded" ? "rounded" : font === "serif" ? "serif" : font === "mono" ? "monospaced" : "default"
  return { font, design, weight, color, opacity: !hex && named === "glass" ? 0.55 : 1 }
}

/** Whether the date shows over the time (on unless turned off). */
export const showsDate = (settings: Settings) => settings.date !== false
