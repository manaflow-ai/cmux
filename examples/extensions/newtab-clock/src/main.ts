// Clock: a New Tab page with the time, the date, and where the tab starts.
// The sandbox has no setInterval and no Intl: tick with cmux.timer, format by hand.
import { cmux, newTab, onCleanup, Panel, signal, Spacer, Text, VStack } from "cmux-extension-sdk"

const DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
const pad = (n: number) => (n < 10 ? `0${n}` : `${n}`)

// signal returns [read, write], as in every cmux extension.
const [now, setNow] = signal(Date.now())
const d = () => new Date(now())
const time = () => {
  const t = d(), h = t.getHours()
  return `${h % 12 || 12}:${pad(t.getMinutes())}:${pad(t.getSeconds())} ${h < 12 ? "AM" : "PM"}`
}
const date = () => `${DAYS[d().getDay()]}, ${MONTHS[d().getMonth()]} ${d().getDate()}`
const greeting = () => {
  const h = d().getHours()
  return h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
}

export const renderNewTab = newTab(({ cwd }) => {
  const id = cmux.timer.every(1000, () => setNow(Date.now()))
  onCleanup(() => cmux.timer.clear(id))
  return VStack([
    Spacer(),
    Panel({ title: greeting }, [
      Text(time),
      Text(date),
      Text(cwd ? `Starting in ${cwd.replace(/^\/Users\/[^/]+/, "~")}` : "A new tab"),
    ]),
    Spacer(),
  ])
})
