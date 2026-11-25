// The collection, redone for the demo. Same three cards and the same reads as the showcase's
// collection; what changed is how they are drawn: each card has an icon header with a tinted disc,
// the clock is the hero of its card and rolls its digits, the weather symbol draws in its own
// colors, each usage meter is a labelled block with its percent large and its details small, and
// the gacha reel sits in a glowing ring that pulses brighter for rarer chiefs. The New Tab page
// lays the cards out as a deck under a header; the sidebar stacks them.
//
// The collection: a suite of small things that show what a view can do, each one a short
// function you can copy into your own ~/.config/cmux/customize/main.js. The sidebar section and
// the New Tab page draw the same three cards:
//
// - Today: the time, the date and the weather (Open-Meteo, no key) for a city you type in.
// - Usage: what is left this week on every Claude and Codex account cmux's Usage app reads,
//   with the pace and any extra spend, counting up when it changes.
// - Chief gacha: pull a chief from an animated reel; rarer chiefs glow, and the ones you have
//   are kept with storage:local.
//
// Animation is signals driven by one-shot timers: each frame sets a signal (a rotation, an
// opacity, a symbol) and arms the next frame. Repeating timers fire at most once a second, so a
// reel chains cmux.timer.after instead, and stops when it lands; nothing runs while idle.

const message = (e) => (e instanceof Error ? e.message : String(e))
const two = (n) => String(n).padStart(2, "0")

// Frames are armed from callbacks (a tap, a read), so no view owns them. `epoch` moves when the
// last view closes; a frame armed before that sees it moved and stops.
let epoch = 0

// Moves a number from `from` to `to` over `frames` frames of 50 ms, easing out. A newer tween
// of the same key, stopTween(key) or the last view closing ends the one before it.
const tweens = {}
const stopTween = (key) => (tweens[key] = (tweens[key] ?? 0) + 1)
function tween(key, set, from, to, frames = 12) {
  const gen = stopTween(key)
  const born = epoch
  let i = 0
  const step = () => {
    if (tweens[key] !== gen || epoch !== born) return
    i += 1
    const t = 1 - Math.pow(1 - i / frames, 3)
    set(from + (to - from) * t)
    if (i < frames) cmux.timer.after(50, step)
  }
  step()
}

// ---- Today: the time and the weather ---------------------------------------------------------

const [now, setNow] = signal(Date.now())
const [place, setPlace] = signal(null) // { name, latitude, longitude }
const [weather, setWeather] = signal(null) // { temperature, code, high, low }
const [weatherError, setWeatherError] = signal(null)
const [draft, setDraft] = signal("")

// Icons: the sidebar draws SF Symbols, but the New Tab page is a web page that draws only cmux's
// icon pack (an SF name it does not know is the missing-icon box), so every icon the page shows is
// a pack name (`appearance.light`, `history`), which the sidebar draws too. Only the weather keeps
// its SF symbol in the sidebar, where it draws in its own colors; `pack` is its page icon.
function sky(code) {
  if (code === 0) return { text: "Clear", symbol: "sun.max", pack: "appearance.light" }
  if (code <= 3) return { text: "Partly cloudy", symbol: "cloud.sun", pack: "cloud" }
  if (code <= 48) return { text: "Fog", symbol: "cloud.fog", pack: "cloud" }
  if (code <= 67) return { text: "Rain", symbol: "cloud.rain", pack: "cloud" }
  if (code <= 77) return { text: "Snow", symbol: "cloud.snow", pack: "cloud" }
  if (code <= 82) return { text: "Showers", symbol: "cloud.heavyrain", pack: "cloud" }
  if (code <= 86) return { text: "Snow showers", symbol: "cloud.snow", pack: "cloud" }
  return { text: "Thunderstorm", symbol: "cloud.bolt", pack: "cloud" }
}

const clock = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})
const day = computed(() => {
  const d = new Date(now())
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()}`
})

async function loadWeather() {
  const p = place()
  if (!p) return
  try {
    const r = await cmux.net.fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${p.latitude}&longitude=${p.longitude}&current=temperature_2m,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1`
    )
    if (!r.ok) throw new Error(`Open-Meteo answered ${r.status}`)
    const body = r.json()
    if (place() !== p) return
    setWeather({
      temperature: Math.round(body.current.temperature_2m),
      code: body.current.weather_code,
      high: Math.round(body.daily.temperature_2m_max[0]),
      low: Math.round(body.daily.temperature_2m_min[0])
    })
    setWeatherError(null)
  } catch (e) {
    if (place() === p) setWeatherError(weatherProblem(e))
  }
}

async function chooseCity(text) {
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
    setWeatherError(weatherProblem(e))
  }
}

// A customize app installs sandboxed (no network) until you turn that off, so a refused read says how.
function weatherProblem(e) {
  if (e && e.code === "scope.missing") return "The weather needs the network: turn off Run sandboxed for this app in Settings > Apps, and allow its two weather hosts."
  if (e && String(e.message || "").startsWith("No place called")) return e.message
  return "The weather did not answer. Right-click the card to try again."
}

function changeCity() {
  setPlace(null)
  setWeather(null)
  cmux.storage.delete("place").catch(() => undefined)
}

// A card's header: the symbol in a tinted disc, the title, and a trailing note.
function cardHeader(symbol, title, tone, note) {
  return HStack({ spacing: 8 }, [
    ZStack([
      Circle().fill(tone).opacity(0.2).frame({ width: 26, height: 26 }),
      Icon(symbol).font("callout").color(tone).symbolRendering("hierarchical")
    ]).frame({ width: 26, height: 26 }),
    Text(title).font("headline").fixedSize("horizontal"),
    Spacer(),
    note ? Text(note).font("caption").color(cmux.theme.text.tertiary).lineLimit(1) : null
  ])
}

function today(page = false) {
  return Panel({ style: "glass", spacing: 10 }, [
    cardHeader("history", "Today", cmux.theme.accent, () => (place() ? place().name : "")),
    HStack({ spacing: 10, alignment: "bottom" }, [
      Text(clock).font("largeTitle").weight("bold").monospaced().contentTransition("numericText"),
      Spacer(),
      () => {
        const w = weather()
        if (!w) return null
        return HStack({ spacing: 6 }, [
          page ? Icon(sky(w.code).pack).font("title").color(cmux.theme.warning) : Icon(sky(w.code).symbol).font("title").symbolRendering("multicolor"),
          Text(`${w.temperature}°`).font("title").weight("light").contentTransition("numericText")
        ]).transition("opacity")
      }
    ]),
    Text(day).font("callout").weight("medium").color(cmux.theme.text.secondary),
    () => {
      const w = weather()
      if (!w) return null
      return HStack({ spacing: 6 }, [
        Badge(sky(w.code).text, cmux.theme.accent),
        Icon("disclosure.expanded").font("caption").color(cmux.theme.text.tertiary),
        Text(`${w.low}°`).font("caption").monospaced().color(cmux.theme.text.secondary),
        Icon("disclosure.folded").font("caption").color(cmux.theme.text.tertiary),
        Text(`${w.high}°`).font("caption").monospaced().color(cmux.theme.text.secondary),
        Spacer()
      ])
    },
    () => (place() ? null : TextField(draft, { placeholder: "Type your city for the weather", onEdit: setDraft, onSubmit: chooseCity })),
    () => (weatherError() ? Text(weatherError()).font("caption").color(cmux.theme.warning) : null)
  ])
    .frame({ maxWidth: "infinity" })
    .contextMenu([Button("Change city", changeCity), Button("Refresh weather", () => loadWeather())])
}

// ---- Usage: what is left on every account ----------------------------------------------------

// One row per provider: { id, accounts, usable, weeklyLeft (0...100, the mean over accounts that
// report it), sessionLeft (the lowest), extraUsd, verdict }.
const [usage, setUsage] = signal(null)
const [usageError, setUsageError] = signal(null)
const [shown, setShown] = signal({}) // provider id -> the weekly percent drawn now, for the count-up

const NAMES = { claude: "Claude", codex: "Codex" }
const PACE = { under: "under pace", onPace: "on pace", over: "over pace" }

function summarize(status) {
  return (status.providers || []).map((p) => {
    const accounts = p.accounts || []
    const weekly = accounts.map((a) => a.weekly_left_pct).filter((n) => typeof n === "number")
    const session = accounts.map((a) => a.session_left_pct).filter((n) => typeof n === "number")
    const extra = accounts.reduce((sum, a) => sum + (typeof a.extra_usage_usd === "number" ? a.extra_usage_usd : 0), 0)
    return {
      id: p.id,
      accounts: accounts.length,
      usable: p.summary?.usable ?? 0,
      weeklyLeft: weekly.length ? weekly.reduce((a, b) => a + b, 0) / weekly.length : null,
      sessionLeft: session.length ? Math.min(...session) : null,
      extraUsd: extra,
      verdict: p.pace?.verdict ?? null
    }
  })
}

async function loadUsage(refresh = false) {
  try {
    const status = await cmux.call("usage_app.status", { accounts: true, refresh })
    // A refused scope or a router error answers with no providers and a problem: say that, not
    // "no accounts". A failed refresh keeps the last reading with a problem: draw the reading.
    if (!(status.providers || []).length && (status.problem || (status.state && status.state !== "ready"))) {
      setUsageError(status.problem?.message ?? `The Usage app is ${status.state}`)
      return
    }
    const rows = summarize(status)
    const before = untrack(shown)
    setUsage(rows)
    setUsageError(null)
    for (const row of rows) {
      if (row.weeklyLeft === null) continue
      tween(`usage:${row.id}`, (v) => setShown((s) => ({ ...s, [row.id]: v })), before[row.id] ?? 0, row.weeklyLeft)
    }
  } catch (e) {
    setUsageError(usageProblem(e))
  }
}

// What a failed usage read says, in words: a cmux whose views cannot reach the Usage app yet answers
// operation.unsupported (or provider.unavailable while it starts); never the raw reason.
function usageProblem(e) {
  const code = e && e.code
  if (code === "operation.unsupported" || code === "provider.unavailable") return "This cmux does not share the Usage app with views yet."
  if (code === "scope.missing") return "Turn on Usage for this app in Settings > Apps."
  return "The Usage app did not answer. Right-click to read it again."
}

function meter(row) {
  const left = () => (row().weeklyLeft === null ? null : shown()[row().id] ?? 0)
  const tone = () => {
    const v = row().weeklyLeft
    return v === null ? cmux.theme.text.secondary : v < 15 ? cmux.theme.danger : v < 40 ? cmux.theme.warning : cmux.theme.success
  }
  const symbol = () => (row().id === "codex" ? "code" : "task.ai")
  return VStack({ spacing: 5 }, [
    HStack({ spacing: 8, alignment: "bottom" }, [
      Icon(symbol).color(cmux.theme.accent).symbolRendering("hierarchical"),
      VStack({ spacing: 0, alignment: "leading" }, [
        Text(() => NAMES[row().id] ?? row().id).font("callout").weight("semibold"),
        Text(() => `${row().usable} of ${row().accounts} ${row().accounts === 1 ? "account" : "accounts"} ready`)
          .font("caption2")
          .color(cmux.theme.text.tertiary)
      ]),
      Spacer(),
      Text(() => (left() === null ? "–" : `${Math.round(left())}%`))
        .font("title2")
        .weight("semibold")
        .monospaced()
        .color(tone)
        .animation("smooth")
    ]),
    ProgressView(() => (left() === null ? null : left() / 100)),
    // One line of details that wraps between its parts in a narrow card (a row of badges cannot).
    Text(() => {
      const r = row()
      const parts = ["left this week"]
      if (r.sessionLeft !== null) parts.push(`session ${Math.round(r.sessionLeft)}%`)
      if (r.verdict && PACE[r.verdict]) parts.push(PACE[r.verdict])
      if (r.extraUsd > 0) parts.push(`$${r.extraUsd.toFixed(2)} extra`)
      return parts.join(" · ")
    })
      .font("caption")
      .color(() => (row().verdict === "over" || row().extraUsd > 0 ? cmux.theme.warning : cmux.theme.text.secondary))
  ])
}

function usageCard() {
  return Panel({ style: "glass", spacing: 10 }, [
    cardHeader("context.usage", "Usage", cmux.theme.success, "this week"),
    () => {
      if (usageError() && !usage()) return EmptyState({ title: "No usage here yet", message: usageError(), symbol: "context.usage" })
      const rows = usage()
      if (!rows) return ProgressView()
      if (!rows.length) return EmptyState({ title: "No accounts", message: "Add a Claude or Codex account in the Usage pane.", symbol: "account" })
      return VStack({ spacing: 12 }, [ForEach({ items: usage, key: (r) => r.id }, meter)])
    }
  ])
    .frame({ maxWidth: "infinity" })
    .contextMenu([Button("Read usage now", () => loadUsage(true))])
}

// ---- Chief gacha ------------------------------------------------------------------------------

const RARITY = {
  common: { label: "Common", tone: cmux.theme.text.secondary, weight: 60 },
  rare: { label: "Rare", tone: cmux.theme.success, weight: 28 },
  epic: { label: "Epic", tone: cmux.theme.accent, weight: 10 },
  legendary: { label: "Legendary", tone: cmux.theme.warning, weight: 2 }
}
const CHIEFS = [
  { id: "intern", name: "Intern Chief", symbol: "account", rarity: "common" },
  { id: "lint", name: "Lint Chief", symbol: "trust.verified", rarity: "common" },
  { id: "coffee", name: "Coffee Chief", symbol: "history", rarity: "common" },
  { id: "rebase", name: "Rebase Chief", symbol: "git.branch", rarity: "common" },
  { id: "merge", name: "Merge Chief", symbol: "git.pullrequest.merged", rarity: "rare" },
  { id: "cache", name: "Cache Chief", symbol: "automation", rarity: "rare" },
  { id: "review", name: "Review Chief", symbol: "action.show", rarity: "rare" },
  { id: "fleet", name: "Fleet Chief", symbol: "machine.remote", rarity: "epic" },
  { id: "nightly", name: "Nightly Chief", symbol: "state.idle", rarity: "epic" },
  { id: "cloud", name: "Cloud Chief", symbol: "cloud.workspace", rarity: "legendary" }
]
// A legendary is certain by this many pulls without one.
const PITY = 30

const [owned, setOwned] = signal({}) // chief id -> how many
const [sincePity, setSincePity] = signal(0)
const [hydrated, setHydrated] = signal(false) // the saved chiefs have been read
const [reel, setReel] = signal({ chief: null, angle: 0, glow: 0, spinning: false, at: 0 })

function draw() {
  const rarity = sincePity() + 1 >= PITY ? "legendary" : (() => {
    let roll = Math.random() * 100
    for (const [key, r] of Object.entries(RARITY)) {
      if ((roll -= r.weight) < 0) return key
    }
    return "common"
  })()
  const pool = CHIEFS.filter((c) => c.rarity === rarity)
  return pool[Math.floor(Math.random() * pool.length)]
}

function pull() {
  // Until the saved chiefs are read, a pull would count pity from 0 and be overwritten by them.
  if (!hydrated()) return
  const r = reel()
  // A reel whose view closed mid-spin stopped with it; let the next pull start over.
  if (r.spinning && Date.now() - r.at < 1500) return
  const result = draw()
  stopTween("glow")
  const frames = 26
  const born = epoch
  let i = 0
  let angle = 0
  const frame = () => {
    // The last view closed mid-spin: nothing is drawn, so nothing is kept or toasted.
    if (epoch !== born) return
    i += 1
    const t = i / frames
    if (i < frames) {
      // Spin fast, then slow down: the step shrinks and the delay grows as t goes to 1.
      angle = (angle + 50 * (1 - t) + 6) % 360
      setReel({ chief: CHIEFS[Math.floor(Math.random() * CHIEFS.length)], angle, glow: 0, spinning: true, at: Date.now() })
      cmux.timer.after(Math.round(45 + 220 * t * t), frame)
      return
    }
    land(result)
  }
  frame()
}

function land(chief) {
  setOwned((o) => ({ ...o, [chief.id]: (o[chief.id] ?? 0) + 1 }))
  setSincePity((n) => (chief.rarity === "legendary" ? 0 : n + 1))
  cmux.storage.set("gacha", { owned: untrack(owned), sincePity: untrack(sincePity) }).catch(() => undefined)
  // The reveal: the card snaps upright and its glow pulses out, brighter for rarer chiefs.
  const peak = { common: 0.35, rare: 0.55, epic: 0.8, legendary: 1 }[chief.rarity]
  setReel({ chief, angle: 0, glow: peak, spinning: false, at: Date.now() })
  tween("glow", (g) => setReel((r) => ({ ...r, glow: g })), peak, peak * 0.25, 16)
  if (chief.rarity === "legendary" || chief.rarity === "epic") {
    cmux.toast({ title: `${RARITY[chief.rarity].label}: ${chief.name}`, tone: chief.rarity === "legendary" ? "success" : undefined })
  }
}

const collected = computed(() => CHIEFS.filter((c) => owned()[c.id]).length)

function gacha() {
  const chief = () => reel().chief
  const tone = () => (chief() ? RARITY[chief().rarity].tone : cmux.theme.text.tertiary)
  const left = () => PITY - sincePity()
  return Panel({ style: "glass", spacing: 10 }, [
    cardHeader("agent.chief", "Chief gacha", cmux.theme.warning, () => `${collected()} of ${CHIEFS.length}`),
    HStack({ spacing: 14 }, [
      // The reel: a soft halo, a ring in the rarity's tone, the chief spinning inside.
      ZStack([
        Circle().fill(() => radialGradient([tone(), "clear"])).opacity(() => 0.25 + reel().glow * 0.75).frame({ width: 72, height: 72 }),
        Circle().stroke(tone).strokeWidth(2).opacity(() => 0.35 + reel().glow * 0.65).frame({ width: 56, height: 56 }),
        Icon(() => chief()?.symbol ?? "agent.session")
          .font(() => (reel().glow > 0.5 ? "largeTitle" : "title"))
          .color(tone)
          .symbolRendering("hierarchical")
          .rotation(() => reel().angle)
      ]).frame({ width: 72, height: 72 }),
      VStack({ spacing: 3, alignment: "leading" }, [
        Text(() => (reel().spinning ? "Rolling…" : chief()?.name ?? "Pull a chief")).font("title3").weight("semibold").lineLimit(1),
        () => (chief() && !reel().spinning ? Badge(RARITY[chief().rarity].label, tone()) : Text("Ten chiefs, four rarities").font("caption").color(cmux.theme.text.secondary)),
        Text(() => (left() === 1 ? "The next pull is a legendary" : `Legendary in ${left()} pulls or sooner`))
          .font("caption2")
          .color(cmux.theme.text.tertiary)
      ]),
      Spacer()
    ]),
    ProgressView(() => collected() / CHIEFS.length),
    HStack({ spacing: 8 }, [
      Button(HStack({ spacing: 4 }, [Icon("agent.session"), Text("Pull")]), pull).disabled(() => !hydrated() || reel().spinning),
      Spacer(),
      Text(() => `${collected()} collected`).font("caption").color(cmux.theme.text.secondary)
    ])
  ])
    .frame({ maxWidth: "infinity" })
    .contextMenu([
      Button("Show my chiefs", () =>
        cmux.toast({
          title: `${collected()} of ${CHIEFS.length} chiefs`,
          message: CHIEFS.filter((c) => owned()[c.id]).map((c) => `${c.name} ×${owned()[c.id]}`).join(", ") || "None yet: pull one."
        })
      )
    ])
}

// ---- Start, and the two places --------------------------------------------------------------

// The clock and the two reads run once however many views are open (the section and every New
// Tab page share this script): the first view arms them, and each view that closes re-arms them
// for the views left, or stops them with the last one. Saved state is read once.
let loaded = false
let mounts = 0
let polls = []

function armPolls() {
  polls = [
    cmux.timer.every(15000, () => setNow(Date.now())),
    cmux.timer.every(15 * 60_000, loadWeather),
    cmux.timer.every(5 * 60_000, () => loadUsage())
  ]
}

function clearPolls() {
  for (const id of polls) cmux.timer.clear(id)
  polls = []
}

function start() {
  mounts += 1
  // Timers armed in a render end with that view, so a closing view hands them to the rest.
  onCleanup(() => {
    mounts -= 1
    clearPolls()
    if (mounts > 0) cmux.timer.after(50, () => mounts > 0 && !polls.length && armPolls())
    else {
      epoch += 1
      if (untrack(reel).spinning) setReel((r) => ({ ...r, spinning: false }))
    }
  })
  if (!polls.length) armPolls()
  if (loaded) return
  loaded = true
  loadUsage()
  cmux.storage.get("place").then((saved) => {
    // A city typed in before the read came back wins over the saved one.
    if (saved && typeof saved.latitude === "number" && !untrack(place)) {
      setPlace(saved)
      loadWeather()
    }
  }, () => undefined)
  cmux.storage.get("gacha").then((saved) => {
    if (saved && typeof saved === "object") {
      setOwned(saved.owned || {})
      setSincePity(saved.sincePity || 0)
    }
    setHydrated(true)
  }, () => setHydrated(true))
}

function renderSection() {
  start()
  return VStack({ spacing: 10 }, [today(), usageCard(), gacha()])
}

function renderPage() {
  start()
  return VStack({ spacing: 20 }, [
    HStack({ spacing: 12, alignment: "bottom" }, [
      VStack({ spacing: 4, alignment: "leading" }, [
        HStack({ spacing: 8 }, [
          Icon("agent.session").font("title").color(cmux.theme.accent),
          Text("The collection").font("largeTitle").weight("heavy")
        ]),
        Text("Three small things a view can do: the time and the sky, what your agents have left, and a chief to pull.")
          .font("title3")
          .color(cmux.theme.text.secondary)
      ]),
      Spacer()
    ]),
    // The page has no wrap and no pane width to read, so the cards go two a row: Today and the gacha
    // share one (each half of it whatever its content: a width of "infinity" in both makes their
    // flex bases equal), and Usage, the widest, takes the row below. It fits a pane from 450 pt up.
    HStack({ spacing: 14, alignment: "top" }, [today(true), gacha()].map((card) => card.frame({ width: "infinity" }))),
    usageCard(),
    HStack({ spacing: 6 }, [
      Icon("computeruse.click").font("caption").color(cmux.theme.text.tertiary),
      Text("Right-click a card for more: change the city, read usage now, show your chiefs.").font("caption").color(cmux.theme.text.tertiary),
      Spacer()
    ]),
    Spacer()
  ]).padding()
}

globalThis.__cmuxAppExports = { renderSection, renderPage }
