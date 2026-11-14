// World clock: the time in the places you work with, in a sidebar section. It imports nothing but
// the public SDK.
// - The zones are a setting (Settings > Apps > World clock): IANA names such as Europe/London,
//   separated by commas. Each row names the city, how far it is from you, and its day when that is
//   not yours.
// - The sandbox has no Intl, so the zone rules come from cmux.time.zone(), which answers with
//   cmux's own time zone database. It costs nothing: the section redraws once a minute, on the
//   minute, and asks no host for anything.

import { cmux, computed, EmptyState, ForEach, onCleanup, Row, signal, VStack, type View } from "cmux-extension-sdk"

export const DEFAULT_ZONES = "America/Los_Angeles, America/New_York, Europe/London, Asia/Tokyo"
const MINUTE = 60_000

interface Clock { zone: string; city: string; time: string; subtitle: string; problem: boolean }

const two = (n: number) => String(n).padStart(2, "0")

/** "America/Los_Angeles" is "Los Angeles"; "America/Argentina/Buenos_Aires" is "Buenos Aires". */
export function city(zone: string): string {
  return (zone.split("/").at(-1) ?? zone).replace(/_/g, " ")
}

function clockTime(wall: Date, hour12: boolean): string {
  const h = wall.getUTCHours()
  const m = two(wall.getUTCMinutes())
  if (!hour12) return `${two(h)}:${m}`
  return `${h % 12 || 12}:${m} ${h < 12 ? "AM" : "PM"}`
}

function distance(minutes: number): string {
  if (minutes === 0) return "Same time as you"
  const sign = minutes > 0 ? "+" : "−"
  const abs = Math.abs(minutes)
  const hours = Math.floor(abs / 60)
  const rest = abs % 60
  return `${sign}${hours}${rest ? `:${two(rest)}` : ""} h`
}

/** One row: the wall time in `zone` at `now`, and how it compares with the local clock. */
export function clock(zone: string, now: number, hour12: boolean): Clock {
  try {
    const z = cmux.time.zone(zone, now) as ReturnType<typeof cmux.time.zone> | Promise<unknown>
    // A cmux older than cmux.time sends the call to the host as an op, which answers later
    // (and refuses): that is no time zone database.
    if (z instanceof Promise) {
      z.catch(() => {})
      throw { code: "operation.unsupported" }
    }
    const localOffset = -new Date(now).getTimezoneOffset()
    // A Date shifted by the zone's offset reads that zone's wall time through its UTC getters.
    const wall = new Date(now + z.offsetMinutes * MINUTE)
    const local = new Date(now + localOffset * MINUTE)
    const dayDelta = Math.round((Date.UTC(wall.getUTCFullYear(), wall.getUTCMonth(), wall.getUTCDate()) - Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate())) / 86_400_000)
    const day = dayDelta === 0 ? null : dayDelta > 0 ? "Tomorrow" : "Yesterday"
    const parts = [day, `${distance(z.offsetMinutes - localOffset)} · ${z.abbreviation}`].filter(Boolean)
    return { zone, city: city(zone), time: clockTime(wall, hour12), subtitle: parts.join(" · "), problem: false }
  } catch (error) {
    const e = error as { code?: string; message?: string }
    const subtitle = e?.code === "operation.unsupported" ? "This cmux has no time zones yet: update cmux" : `Not a time zone (${e?.message ?? String(error)})`
    return { zone, city: city(zone), time: "", subtitle, problem: true }
  }
}

export function zonesFrom(setting: unknown): string[] {
  const text = typeof setting === "string" && setting.trim() ? setting : DEFAULT_ZONES
  const seen = new Set<string>()
  return text.split(",").map((z) => z.trim()).filter((z) => z && !seen.has(z) && seen.add(z))
}

const [now, setNow] = signal(Date.now())

export function renderWorldClock(): View {
  setNow(Date.now())
  // Tick just after each minute starts. Each timer is one-shot and arms the next; the view's
  // cleanup clears the one pending, since a timer armed inside a timer belongs to no view.
  let timer = 0
  let open = true
  const arm = () => {
    timer = cmux.timer.after(MINUTE - (Date.now() % MINUTE) + 50, () => {
      setNow(Date.now())
      if (open) arm()
    })
  }
  arm()
  onCleanup(() => {
    open = false
    cmux.timer.clear(timer)
  })
  const settings = computed(() => cmux.app.settings())
  const hour12 = computed(() => settings().hour12 === true)
  const clocks = computed(() => zonesFrom(settings().zones).map((zone) => clock(zone, now(), hour12())))
  return VStack({ spacing: 2 }, [
    ForEach({ items: clocks, key: (c) => c.zone }, (c) =>
      Row({
        title: () => c().city,
        subtitle: () => c().subtitle,
        symbol: () => (c().problem ? "exclamationmark.triangle" : "globe"),
        tint: () => (c().problem ? cmux.theme.warning : null),
        accessory: () => c().time || null
      })
    ),
    () => (clocks().length === 0 ? EmptyState({ title: "No time zones", message: "Add some in Settings > Apps > World clock.", symbol: "globe" }) : null)
  ])
}
