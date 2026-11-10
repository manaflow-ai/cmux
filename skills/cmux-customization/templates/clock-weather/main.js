// A widget section: the time, the date and the weather for a city you type in. The clock
// needs nothing. The weather comes from Open-Meteo (no key) once both net: scopes are on in
// Settings > Apps > My views; the city is kept with storage:local. It reads the weather
// every 15 minutes and the clock every 15 seconds, so it never costs a frame.

const [now, setNow] = signal(Date.now())
const [place, setPlace] = signal(null) // { name, latitude, longitude }
const [weather, setWeather] = signal(null) // { temperature, code, high, low }
const [error, setError] = signal(null)
const [draft, setDraft] = signal("")
let loaded = false

// WMO weather codes, grouped the way a person reads them.
function describe(code) {
  if (code === 0) return { text: "Clear", symbol: "sun.max" }
  if (code <= 3) return { text: "Partly cloudy", symbol: "cloud.sun" }
  if (code <= 48) return { text: "Fog", symbol: "cloud.fog" }
  if (code <= 67) return { text: "Rain", symbol: "cloud.rain" }
  if (code <= 77) return { text: "Snow", symbol: "cloud.snow" }
  if (code <= 82) return { text: "Showers", symbol: "cloud.heavyrain" }
  if (code <= 86) return { text: "Snow showers", symbol: "cloud.snow" }
  return { text: "Thunderstorm", symbol: "cloud.bolt" }
}

const two = (n) => String(n).padStart(2, "0")
const time = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})
const date = computed(() => {
  const d = new Date(now())
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()}`
})

const message = (e) => (e instanceof Error ? e.message : String(e))

async function loadWeather() {
  const p = place()
  if (!p) return
  try {
    const r = await cmux.net.fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${p.latitude}&longitude=${p.longitude}&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1`
    )
    if (!r.ok) throw new Error(`Open-Meteo answered ${r.status}`)
    const body = r.json()
    // A city changed while this read was out: its answer is for the old one.
    if (place() !== p) return
    setWeather({
      temperature: Math.round(body.current.temperature_2m),
      code: body.current.weather_code,
      high: Math.round(body.daily.temperature_2m_max[0]),
      low: Math.round(body.daily.temperature_2m_min[0])
    })
    setError(null)
  } catch (e) {
    if (place() === p) setError(message(e))
  }
}

async function choose(text) {
  const name = String(text || "").trim()
  if (!name) return
  try {
    const r = await cmux.net.fetch(`https://geocoding-api.open-meteo.com/v1/search?count=1&name=${encodeURIComponent(name)}`)
    if (!r.ok) throw new Error(`Open-Meteo answered ${r.status}`)
    const hit = (r.json().results || [])[0]
    if (!hit) throw new Error(`No place called ${name}`)
    const next = { name: hit.name, latitude: hit.latitude, longitude: hit.longitude }
    setPlace(next)
    setDraft("")
    cmux.storage.set("place", next).catch(() => undefined)
    await loadWeather()
  } catch (e) {
    setError(message(e))
  }
}

// Timers belong to the view that started them and end with it, so every render starts its own;
// the saved city is read once.
function changeCity() {
  setPlace(null)
  setWeather(null)
  cmux.storage.delete("place").catch(() => undefined)
}

function start() {
  cmux.timer.every(15000, () => setNow(Date.now()))
  cmux.timer.every(15 * 60_000, loadWeather)
  if (loaded) return
  loaded = true
  cmux.storage.get("place").then(
    (saved) => {
      if (saved && typeof saved.latitude === "number") {
        setPlace(saved)
        loadWeather()
      }
    },
    () => undefined
  )
}

function renderClock() {
  start()
  return VStack({ spacing: 4 }, [
    HStack({ spacing: 8 }, [
      Text(time).font("title").weight("semibold").monospaced(),
      Spacer(),
      () => {
        const w = weather()
        if (!w) return null
        return HStack({ spacing: 4 }, [Icon(describe(w.code).symbol), Text(`${w.temperature}°`).font("title3")])
      }
    ]),
    Text(() => {
      const w = weather()
      const p = place()
      return w && p ? `${date()} · ${p.name}, ${describe(w.code).text}, ${w.low}° to ${w.high}°` : date()
    }).color(cmux.theme.text.secondary),
    () => (place() ? null : TextField(draft, { placeholder: "Your city, for the weather", onEdit: setDraft, onSubmit: choose })),
    () => (error() ? Text(error()).font("caption").color(cmux.theme.warning) : null)
  ]).contextMenu([Button("Change city", changeCity), Button("Refresh weather", () => loadWeather())])
}

globalThis.__cmuxAppExports = { renderClock }
