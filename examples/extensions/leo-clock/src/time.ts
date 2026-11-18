// Wall time without Intl: the sandbox has none, so zones come from cmux.time.zone() (cmux's own
// time zone database) and everything is formatted by hand.
import { cmux, onCleanup, signal } from "cmux-extension-sdk"

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const DEFAULT_ZONES = "America/Los_Angeles, America/New_York, Europe/London, Asia/Tokyo"
const MINUTE = 60_000

export const two = (n: number) => String(n).padStart(2, "0")
export const city = (zone: string) => (zone.split("/").at(-1) ?? zone).replace(/_/g, " ")

export function zonesFrom(setting: unknown): string[] {
  const text = typeof setting === "string" && setting.trim() ? setting : DEFAULT_ZONES
  return [...new Set(text.split(",").map((z) => z.trim()).filter(Boolean))]
}

/** A clock's reading: read `at` with the getUTC* methods to get that zone's wall time. */
export interface Wall { at: Date; offset: number; abbreviation: string; ok: boolean }

/** The wall time in `zone` (null: here) at `now`. An unknown zone, or a cmux without time zones, reads as here. */
export function wall(zone: string | null, now: number): Wall {
  const here = -new Date(now).getTimezoneOffset()
  let offset = here, abbreviation = "", ok = true
  if (zone) {
    try {
      const z = cmux.time.zone(zone, now)
      if (typeof z?.offsetMinutes !== "number") throw new Error("no time zones in this cmux")
      offset = z.offsetMinutes
      abbreviation = z.abbreviation
    } catch {
      ok = false
    }
  }
  return { at: new Date(now + offset * MINUTE), offset: offset - here, abbreviation, ok }
}

/** Seconds since local midnight of the day `base` falls on: keeps growing past midnight, so hands never spin back. */
export const secondsSince = (base: number, now: number) => {
  const off = -new Date(base).getTimezoneOffset() * MINUTE
  return Math.floor((now + off) / 1000) - Math.floor((base + off) / 86_400_000) * 86_400
}

export const dayFraction = (w: Wall) => (w.at.getUTCHours() * 3600 + w.at.getUTCMinutes() * 60 + w.at.getUTCSeconds()) / 86_400
export const isNight = (w: Wall) => w.at.getUTCHours() < 6 || w.at.getUTCHours() >= 19

export function hhmm(w: Wall, hour12: boolean): { h: string; m: string; s: string; ampm: string } {
  const h = w.at.getUTCHours()
  return {
    h: hour12 ? String(h % 12 || 12) : two(h),
    m: two(w.at.getUTCMinutes()),
    s: two(w.at.getUTCSeconds()),
    ampm: hour12 ? (h < 12 ? "AM" : "PM") : "",
  }
}

export const timeText = (w: Wall, hour12: boolean) => {
  const t = hhmm(w, hour12)
  return `${t.h}:${t.m}${t.ampm ? ` ${t.ampm}` : ""}`
}
export const longDate = (w: Wall) => `${DAYS[w.at.getUTCDay()]}, ${MONTHS[w.at.getUTCMonth()]} ${w.at.getUTCDate()}`
export const distance = (minutes: number) =>
  minutes === 0 ? "here" : `${minutes > 0 ? "+" : "−"}${Math.floor(Math.abs(minutes) / 60)}${Math.abs(minutes) % 60 ? `:${two(Math.abs(minutes) % 60)}` : ""} h`

export function greeting(w: Wall, name: unknown): string {
  const h = w.at.getUTCHours()
  const hello = h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
  return typeof name === "string" && name.trim() ? `${hello}, ${name.trim()}` : hello
}

/** The time now, as a signal that changes on each `period` boundary (1 s or 1 min) while the view is open. */
export function ticking(period: number): () => number {
  const [now, setNow] = signal(Date.now())
  let timer = 0
  let open = true
  // One-shot timers aligned to the boundary, each arming the next (cmux.timer floors to 1 s).
  const arm = () => {
    timer = cmux.timer.after(period - (Date.now() % period) + 20, () => {
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
