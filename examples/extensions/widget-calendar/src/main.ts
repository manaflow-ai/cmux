// Calendar widget: today's date and your next events as a card you add to the sidebar, in the three
// sizes system widgets come in. It imports nothing but the public SDK.
// - Small: the day and the date, large, over your next event.
// - Medium: the date beside your next three events.
// - Large: this month over your next five events, by day.
// - The events come from the calendars on this Mac (cmux.system_calendar.events, scope system_calendar:read),
//   the ones the system Calendar app shows. Reading never asks: the first time, the card shows a
//   button, and its click asks macOS for access once.
// - It reads the events every five minutes and redraws once a minute, on the minute, so an event
//   that ended leaves the card.

import { Button, Circle, cmux, computed, ForEach, HStack, Menu, onCleanup, Panel, signal, Spacer, Text, untrack, VStack, type View } from "cmux-extension-sdk"

export type Size = "small" | "medium" | "large"
export const SIZES: Size[] = ["small", "medium", "large"]
export type Access = "granted" | "denied" | "restricted" | "notDetermined" | "unavailable"
export interface CalendarEvent { id: string; title: string; start: number; end: number; allDay: boolean; calendar: string; location?: string; url?: string }

const MINUTE = 60_000
const DAY = 86_400_000
const REFRESH_MS = 5 * MINUTE
const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const SHOWN: Record<Size, number> = { small: 1, medium: 3, large: 5 }

const two = (n: number) => String(n).padStart(2, "0")

export function sizeOf(setting: unknown): Size {
  return SIZES.includes(setting as Size) ? (setting as Size) : "small"
}

/** `at` as a Date whose UTC getters read the local wall clock. */
function wall(at: number): Date {
  return new Date(at - new Date(at).getTimezoneOffset() * MINUTE)
}

/** Local midnight of the day `at` falls on, as a day number (days since 1970 in local time). */
export function dayNumber(at: number): number {
  return Math.floor(wall(at).getTime() / DAY)
}

export function timeText(at: number, hour12: boolean): string {
  const d = wall(at)
  const h = d.getUTCHours()
  if (!hour12) return `${two(h)}:${two(d.getUTCMinutes())}`
  return `${h % 12 || 12}:${two(d.getUTCMinutes())} ${h < 12 ? "AM" : "PM"}`
}

/** "Today", "Tomorrow", else "Wednesday, November 18". */
export function dayTitle(at: number, now: number): string {
  const delta = dayNumber(at) - dayNumber(now)
  if (delta <= 0) return "Today"
  if (delta === 1) return "Tomorrow"
  const d = wall(at)
  return `${DAYS[d.getUTCDay()]}, ${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`
}

/** When an event is, as the card says it: "All day", "Now, until 11:00", "10:00 to 11:00". */
export function when(e: CalendarEvent, now: number, hour12: boolean): string {
  if (e.allDay) return "All day"
  if (e.start <= now) return `Now, until ${timeText(e.end, hour12)}`
  return `${timeText(e.start, hour12)} to ${timeText(e.end, hour12)}`
}

/** The events a size shows at `now`: not ended, in start order, as many as the size holds. */
export function upcoming(events: CalendarEvent[], size: Size, now: number): CalendarEvent[] {
  return events
    .filter((e) => e.end > now)
    .sort((a, b) => a.start - b.start || a.title.localeCompare(b.title))
    .slice(0, SHOWN[size])
}

/** The month `now` is in as weeks of day numbers (0 for the blanks), Sunday first. */
export function monthGrid(now: number): number[][] {
  const d = wall(now)
  const first = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1))
  const length = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate()
  const cells: number[] = Array(first.getUTCDay()).fill(0)
  for (let day = 1; day <= length; day++) cells.push(day)
  while (cells.length % 7) cells.push(0)
  const weeks: number[][] = []
  for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7))
  return weeks
}

/** What the card says for an access state with no events to show, or null when it can read. */
export function accessNote(access: Access): string | null {
  if (access === "granted") return null
  if (access === "notDetermined") return "See your next events here."
  if (access === "unavailable") return "Your calendar shows in cmux on a Mac."
  return "Calendar access is off. Turn it on for cmux in System Settings > Privacy & Security > Calendars."
}

const [now, setNow] = signal(Date.now())
const [events, setEvents] = signal<CalendarEvent[]>([])
const [access, setAccess] = signal<Access | null>(null)
const [problem, setProblem] = signal<string | null>(null)
let inflight: Promise<void> | null = null

function explain(error: unknown): string {
  const e = error as { code?: string; message?: string }
  if (e?.code === "scope.missing") return "Turn on calendar access for Calendar widget in Settings > Apps."
  if (e?.code === "provider.unavailable" || e?.code === "operation.unsupported") return "This cmux can't read calendars yet: update cmux."
  return e?.message ?? String(error)
}

function load(): Promise<void> {
  if (inflight) return inflight
  inflight = (async () => {
    try {
      const answer = await cmux.system_calendar.events({ days: 31, limit: 20 })
      setAccess(answer.access)
      setEvents(answer.events)
      setProblem(null)
    } catch (error) {
      setProblem(explain(error))
    } finally {
      inflight = null
    }
  })()
  return inflight
}

async function ask() {
  try {
    const answer = await cmux.system_calendar.request_access({})
    setAccess(answer.access)
    if (answer.access === "granted") await load()
  } catch (error) {
    setProblem(explain(error))
  }
}

function sizeMenu(current: () => Size): View {
  const pick = (size: Size, title: string) =>
    Button(current() === size ? `✓ ${title}` : title, () => void cmux.app.settings.set({ size }).catch(() => undefined))
  return Menu("Size", [pick("small", "Small"), pick("medium", "Medium"), pick("large", "Large")])
}

const secondary = cmux.theme.text.secondary
const accent = cmux.theme.accent

export function renderCalendar(): View {
  setNow(Date.now())
  let timer = 0
  let open = true
  const arm = () => {
    timer = cmux.timer.after(MINUTE - (Date.now() % MINUTE) + 50, () => {
      setNow(Date.now())
      if (open) arm()
    })
  }
  arm()
  cmux.timer.every(REFRESH_MS, () => void load())
  onCleanup(() => {
    open = false
    cmux.timer.clear(timer)
  })
  void load()

  const settings = computed(() => cmux.app.settings())
  const size = computed(() => sizeOf(settings().size))
  const hour12 = computed(() => settings().hour12 === true)
  const next = computed(() => upcoming(events(), size(), now()))
  const today = computed(() => {
    const d = wall(now())
    return { weekday: DAYS[d.getUTCDay()]!, day: d.getUTCDate(), month: MONTHS[d.getUTCMonth()]! }
  })

  const dateBlock = () =>
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => today().weekday.toUpperCase()).font("caption").weight("semibold").color(accent),
      Text(() => String(today().day)).font("largeTitle").weight("regular")
    ])

  const eventLine = (e: () => CalendarEvent, showDay: boolean) =>
    HStack({ spacing: 8 }, [
      Circle({ fill: accent, size: 8 }),
      VStack({ spacing: 0, alignment: "leading" }, [
        Text(() => e().title).font("subheadline").weight("semibold").lineLimit(1),
        Text(() => (showDay && dayNumber(e().start) !== dayNumber(now()) ? `${dayTitle(e().start, now())}, ${when(e(), now(), hour12())}` : when(e(), now(), hour12())))
          .font("caption")
          .color(secondary)
          .lineLimit(1)
      ]),
      Spacer()
    ]).help(() => [e().calendar, e().location].filter(Boolean).join(" · "))

  const nothing = () => Text(() => (events().length || access() === "granted" ? "No more events" : "")).font("caption").color(secondary)

  const notice = () => {
    const a = access()
    const note = a ? accessNote(a) : null
    if (!note) return null
    return VStack({ spacing: 6, alignment: "leading" }, [
      Text(note).font("caption").color(secondary),
      a === "notDetermined" ? Button("Show my calendar", ask) : null
    ])
  }

  const list = (showDay: boolean) =>
    VStack({ spacing: 6 }, [ForEach({ items: next, key: (e) => e.id }, (e) => eventLine(e, showDay)), () => (next().length ? null : nothing())])

  // The month as fixed-width cells with a Spacer between each, so both renderers line the
  // columns up; rebuilt once a day, not every minute.
  const todayNumber = computed(() => dayNumber(now()))
  const cell = (text: string, today: boolean, head: boolean) =>
    Text(text)
      .font(head ? "caption2" : "caption")
      .weight(head || today ? "bold" : "regular")
      .color(today ? accent : head ? secondary : cmux.theme.text.primary)
      .frame({ width: 20 })
  const row = (cells: View[]) => {
    const out: View[] = []
    cells.forEach((c, i) => {
      if (i > 0) out.push(Spacer())
      out.push(c)
    })
    return HStack({ spacing: 0 }, out)
  }
  const grid = () =>
    VStack({ spacing: 2 }, [
      row(["S", "M", "T", "W", "T", "F", "S"].map((l) => cell(l, false, true))),
      () => {
        todayNumber()
        const day = untrack(() => today().day)
        return VStack({ spacing: 2 }, untrack(() => monthGrid(now())).map((week) => row(week.map((d) => cell(d ? String(d) : "", d === day, false)))))
      }
    ])

  return Panel({ style: "card", spacing: 10 }, [
    () => {
      const s = size()
      const blocked = access() !== null && access() !== "granted"
      if (s === "small") return VStack({ spacing: 6, alignment: "leading" }, [dateBlock(), blocked ? notice() : list(false)])
      if (s === "medium") return HStack({ spacing: 12 }, [dateBlock(), blocked ? notice() : list(true)])
      return VStack({ spacing: 10, alignment: "leading" }, [
        HStack({ spacing: 6 }, [Text(() => today().month).font("headline").color(accent), Spacer(), Text(() => today().weekday).font("caption").color(secondary)]),
        grid(),
        blocked ? notice() : list(true)
      ])
    },
    () => (problem() ? Text(() => problem()!).font("caption").color(cmux.theme.warning) : null)
  ]).contextMenu(() => [sizeMenu(size), Button("Refresh", () => void load())])
}
