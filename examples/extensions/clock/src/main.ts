/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Clock: a New Tab widget (cmux.newtab.widget/1). An open New Tab page mounts it when the person
// placed it (right-click the page > Edit New Tab > Add Widgets > Clock), keeps it through a switch to
// another tab and back, and unmounts it when the page closes. The timer below belongs to the mount
// (cmux.timer is floored at 1 s), so it stops then too; it can tick while the page is hidden, so a
// tick is cheap. Each tick that changes the time sends one scene update: the time's one Text node.
// The date is its own signal and changes once a day.

interface Settings {
  showSeconds?: boolean
  hourCycle?: "system" | "12h" | "24h"
}

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const pad = (n: number) => String(n).padStart(2, "0")

/** Whether the person's locale writes a 12 hour clock ("system"); 24 hours where the runtime has no Intl. */
function systemTwelveHour(): boolean {
  try {
    return new Intl.DateTimeFormat(cmux.app.locale || undefined, { hour: "numeric" }).resolvedOptions().hour12 === true
  } catch {
    return false
  }
}

export function formatTime(at: Date, settings: Settings, twelveByDefault = systemTwelveHour()): string {
  const twelve = settings.hourCycle === "12h" || (settings.hourCycle !== "24h" && twelveByDefault)
  const minutes = pad(at.getMinutes()) + (settings.showSeconds ? `:${pad(at.getSeconds())}` : "")
  if (!twelve) return `${pad(at.getHours())}:${minutes}`
  const hour = at.getHours() % 12 || 12
  return `${hour}:${minutes} ${at.getHours() < 12 ? "AM" : "PM"}`
}

export function formatDate(at: Date): string {
  return `${DAYS[at.getDay()]}, ${MONTHS[at.getMonth()]} ${at.getDate()}`
}

export function renderClock() {
  const settings = () => cmux.app.settings() as Settings
  const [now, setNow] = signal(Date.now())
  const [date, setDate] = signal(formatDate(new Date(now())))
  const tick = () => {
    const at = Date.now()
    setNow(at)
    setDate(formatDate(new Date(at)))
  }
  // Every second; a tick whose text is the same (no seconds shown) sends nothing: the bound Text
  // compares its new string with the last one.
  cmux.timer.every(1000, tick)
  const twelve = systemTwelveHour()
  return VStack({ spacing: 0, alignment: "leading" }, [
    Text(() => formatTime(new Date(now()), settings(), twelve)).font("title2").weight("semibold").monospaced(),
    Text(date).font("caption").secondary()
  ])
}
