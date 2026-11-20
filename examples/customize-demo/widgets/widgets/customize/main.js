// Widgets: small glanceable cards, all on screen at once. One customize app draws them in three
// places from the same functions:
//
// - the sidebar (cmux.section/1): Today, Agents, Usage and Pull requests, stacked as cards;
// - each chat's Session Info (cmux.session.info.section/1): this chat's agent and state, the
//   usage left on its provider, and its branch's pull request with the checks;
// - every New Tab (cmux.newtab/1): the same cards two a row, plus a world clock and
//   today's chats by project.
//
// The code is taken from the examples, so each card is the one already tested there:
// Today and Usage from examples/customize-showcase/collection, the agent mood from
// examples/extensions/agent-pet, the day's summary from examples/extensions/agent-standup and
// the zones from examples/extensions/world-clock. Pull requests read github.changes, the
// runtime's shared GitHub read with checks and reviews. Every color is a theme tone and every
// size a font name, so the cards follow any theme.

const message = (e) => (e instanceof Error ? e.message : String(e))
const two = (n) => String(n).padStart(2, "0")
const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`
const MINUTE = 60_000
const HOUR = 60 * MINUTE

// Icons: the sidebar draws SF Symbols, but the New Tab page and Session Info are web pages that
// draw only cmux's icon pack (an SF name they do not know is the missing-icon box). So every icon
// here is a pack name (`notification`, `history`), which the sidebar draws too; only the weather
// and Byte keep their SF symbols in the sidebar (`page` false), where they draw best.

// ---- Shared clock and polls (collection: one set of timers for every open view) -----------------

const [now, setNow] = signal(Date.now())
let mounts = 0
let polls = []
let loaded = false

function armPolls() {
  polls = [
    cmux.timer.every(15_000, () => setNow(Date.now())),
    cmux.timer.every(15 * MINUTE, () => loadWeather()),
    cmux.timer.every(5 * MINUTE, () => loadUsage())
  ]
}

function clearPolls() {
  for (const id of polls) cmux.timer.clear(id)
  polls = []
}

// Timers armed in a render end with that view, so a closing view hands them to the views left.
function start() {
  mounts += 1
  onCleanup(() => {
    mounts -= 1
    clearPolls()
    if (mounts > 0) cmux.timer.after(50, () => mounts > 0 && !polls.length && armPolls())
  })
  if (!polls.length) armPolls()
  if (loaded) return
  loaded = true
  loadUsage()
  cmux.storage.get("place").then((saved) => {
    if (saved && typeof saved.latitude === "number" && !untrack(place)) {
      setPlace(saved)
      loadWeather()
    }
  }, () => undefined)
}

// ---- Today: the time and the weather (collection) -----------------------------------------------

const [place, setPlace] = signal(null) // { name, latitude, longitude }
const [weather, setWeather] = signal(null) // { temperature, code, high, low }
const [weatherError, setWeatherError] = signal(null)
const [draft, setDraft] = signal("")

function sky(code) {
  if (code === 0) return { text: "Clear", symbol: "sun.max.fill", pack: "appearance.light" }
  if (code <= 3) return { text: "Partly cloudy", symbol: "cloud.sun.fill", pack: "cloud" }
  if (code <= 48) return { text: "Fog", symbol: "cloud.fog.fill", pack: "cloud" }
  if (code <= 67) return { text: "Rain", symbol: "cloud.rain.fill", pack: "cloud" }
  if (code <= 77) return { text: "Snow", symbol: "cloud.snow.fill", pack: "cloud" }
  if (code <= 82) return { text: "Showers", symbol: "cloud.heavyrain.fill", pack: "cloud" }
  if (code <= 86) return { text: "Snow showers", symbol: "cloud.snow.fill", pack: "cloud" }
  return { text: "Thunderstorm", symbol: "cloud.bolt.rain.fill", pack: "cloud" }
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
  if (e && e.code === "scope.missing") return "The weather needs the network: turn off Run sandboxed for Widgets in Settings > Apps, and allow its two weather hosts."
  if (e && String(e.message || "").startsWith("No place called")) return e.message
  return "The weather did not answer. Right-click the card to try again."
}

function changeCity() {
  setPlace(null)
  setWeather(null)
  cmux.storage.delete("place").catch(() => undefined)
}

function todayCard(page = false) {
  return Panel({ title: "Today" }, [
    HStack({ spacing: 8 }, [
      Text(clock).font("largeTitle").weight("semibold").monospaced().contentTransition("numericText"),
      Spacer(),
      () => {
        const w = weather()
        if (!w) return null
        return HStack({ spacing: 4 }, [
          page ? Icon(sky(w.code).pack).font("title2").color(cmux.theme.warning) : Icon(sky(w.code).symbol).font("title2").symbolRendering("multicolor"),
          Text(`${w.temperature}°`).font("title2").contentTransition("numericText")
        ])
      }
    ]),
    Text(() => {
      const w = weather()
      const p = place()
      return w && p ? `${day()} · ${p.name}, ${sky(w.code).text}, ${w.low}° to ${w.high}°` : day()
    }).color(cmux.theme.text.secondary),
    () => (place() ? null : TextField(draft, { placeholder: "Your city, for the weather", onEdit: setDraft, onSubmit: chooseCity })),
    () => (weatherError() ? Text(weatherError()).font("caption").color(cmux.theme.warning) : null)
  ]).contextMenu([Button("Change city", changeCity), Button("Refresh weather", () => loadWeather())])
}

// ---- World clock (world-clock): New Tab only --------------------------------------------------

const ZONES = ["America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"]
const city = (zone) => (zone.split("/").at(-1) ?? zone).replace(/_/g, " ")

function zoneRow(zone, at) {
  try {
    const z = cmux.time.zone(zone, at)
    if (!z || typeof z.offsetMinutes !== "number") throw new Error("no time zones in this cmux")
    const wall = new Date(at + z.offsetMinutes * MINUTE)
    const localOffset = -new Date(at).getTimezoneOffset()
    const diff = z.offsetMinutes - localOffset
    const hours = diff / 60
    const away = diff === 0 ? "Same time as you" : `${hours > 0 ? "+" : "−"}${Math.abs(hours)} h · ${z.abbreviation}`
    const h = wall.getUTCHours()
    return { zone, city: city(zone), time: `${two(h)}:${two(wall.getUTCMinutes())}`, away, night: h < 7 || h >= 20 }
  } catch (e) {
    return { zone, city: city(zone), time: "", away: message(e), night: false }
  }
}

function worldClockCard() {
  const rows = computed(() => ZONES.map((zone) => zoneRow(zone, now())))
  return Panel({ title: "World clock" }, [
    ForEach({ items: rows, key: (r) => r.zone }, (r) =>
      Row({
        title: () => r().city,
        subtitle: () => r().away,
        symbol: () => (r().night ? "state.idle" : "appearance.light"),
        tint: () => (r().night ? cmux.theme.accent : cmux.theme.warning),
        // A Row's accessory is an icon name; the time is its badge.
        badge: () => r().time || null
      })
    )
  ])
}

// ---- Agents (agent-pet's mood, agent-standup's summary) ----------------------------------------

// The chats the sidebar lists, re-read when cmux sends agent_chat.changed (what the SDK's chats() does).
function chatList() {
  return cmux.live("agent_chat.list", {}, { events: ["agent_chat.changed"], select: (v) => (v && v.chats) || [] })
}

function feel(agentList, chats) {
  const waiting = chats.filter((c) => c.state === "input")
  const failed = chats.filter((c) => c.state === "failed" || c.state === "lost")
  const working = agentList.filter((a) => a.state === "working").length + chats.filter((c) => c.state === "working").length
  if (waiting.length) {
    const first = waiting[0]
    const line = waiting.length === 1 ? `${first.title || "A chat"} is waiting for you` : `${plural(waiting.length, "chat")} are waiting for you`
    return { line, symbol: "notification", tone: cmux.theme.warning, chat: first }
  }
  if (failed.length) return { line: `${failed[0].title || "A chat"} stopped`, symbol: "status.error", tone: cmux.theme.danger, chat: failed[0] }
  if (working) return { line: `Watching ${plural(working, "agent")} work`, symbol: "action.watching", tone: cmux.theme.success, chat: null }
  if (agentList.length + chats.length) return { line: "Napping: every agent is idle", symbol: "action.snooze", tone: cmux.theme.text.secondary, chat: null }
  return { line: "No agents yet. Start one and I'll keep an eye on it.", symbol: "agent.session", tone: cmux.theme.text.secondary, chat: null }
}

const changedAt = (c) => Number(c.updated_ms) || 0
function ago(ms, at) {
  const minutes = Math.max(0, Math.round((at - ms) / MINUTE))
  if (minutes < 1) return "just now"
  if (minutes < 60) return `${minutes} min ago`
  return `${Math.round(minutes / 60)} h ago`
}

const STATE = {
  idle: { label: "Finished", symbol: "status.complete", tone: cmux.theme.text.secondary },
  working: { label: "Working", symbol: "automation", tone: cmux.theme.success },
  input: { label: "Waiting for you", symbol: "status.needsinput", tone: cmux.theme.warning },
  failed: { label: "Failed", symbol: "status.error", tone: cmux.theme.danger },
  lost: { label: "Lost", symbol: "status.error", tone: cmux.theme.danger }
}
const stateOf = (c) => STATE[c.state] ?? { label: String(c.state || "Unknown"), symbol: "state.off", tone: cmux.theme.text.secondary }

function openChat(chat) {
  cmux.actions
    .run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
    .catch((e) => cmux.toast({ title: "Turn on Run actions for Widgets to open chats", message: message(e), tone: "warning" }))
}

// A big number over its label, one third of a card's width. The label keeps its width (a short
// word), so a narrow card never breaks it into a letter a line.
function tile(value, label, symbol, tone, help) {
  return VStack({ spacing: 2, alignment: "leading" }, [
    HStack({ spacing: 4 }, [Icon(symbol).font("caption").color(tone), Text(label).font("caption").color(cmux.theme.text.secondary).fixedSize("horizontal")]),
    Text(value).font("title").weight("semibold").monospaced().contentTransition("numericText").color(tone).fixedSize("horizontal")
  ]).help(help)
}

function agentsCard(options = {}) {
  const agents = cmux.watch("agent.list")
  const chats = chatList()
  const all = computed(() => chats() || [])
  const feeling = computed(() => feel(agents.value() || [], all()))
  const today = computed(() => all().filter((c) => changedAt(c) >= now() - 24 * HOUR))
  const count = (state) => computed(() => String(all().filter((c) => c.state === state).length))
  const done = computed(() => String(today().filter((c) => c.state === "idle").length))
  const recent = computed(() => [...today()].sort((a, b) => changedAt(b) - changedAt(a)).slice(0, options.rows ?? 3))
  return Panel({ title: "Agents" }, [
    HStack({ spacing: 8 }, [
      Icon(options.page ? "agent.bot" : "cat.fill").font("largeTitle").color(() => feeling().tone).animation("smooth"),
      VStack({ spacing: 2, alignment: "leading" }, [
        HStack({ spacing: 4 }, [Text("Byte").font("headline").fixedSize("horizontal"), Icon(() => feeling().symbol).font("caption").color(() => feeling().tone)]),
        Text(() => feeling().line).font("caption").color(cmux.theme.text.secondary).lineLimit(2)
      ]),
      Spacer()
    ])
      .help(() => (feeling().chat ? "Click to open the chat" : "Byte keeps an eye on your agents"))
      .onTap(() => feeling().chat && openChat(feeling().chat)),
    HStack({ spacing: 8, alignment: "top" }, [
      tile(count("working"), "Working", "automation", cmux.theme.success, "Chats working now"),
      tile(count("input"), "Waiting", "notification", cmux.theme.warning, "Chats waiting for you"),
      tile(done, "Done", "status.complete", cmux.theme.accent, "Chats that finished today")
    ]),
    ForEach({ items: recent, key: (c) => c.id }, (c) =>
      Row({
        title: () => c().title || "Untitled chat",
        subtitle: () => `${stateOf(c()).label} · ${c().project || "No project"} · ${ago(changedAt(c()), now())}`,
        symbol: () => stateOf(c()).symbol,
        tint: () => stateOf(c()).tone
      }).onTap(() => openChat(c()))
    ),
    () =>
      chats.error && chats.error()
        ? Text(chats.error().code === "scope.missing" ? "Turn on Agent chats for Widgets in Settings > Apps." : "Your chats did not load; they try again on the next change.")
            .font("caption")
            .color(cmux.theme.warning)
        : null
  ])
}

// ---- Usage left on every Claude and Codex account (collection) ---------------------------------

const [usage, setUsage] = signal(null)
const [usageError, setUsageError] = signal(null)
// False on a cmux whose views cannot reach the Usage app (usage_app.status answers
// operation.unsupported there): the Usage cards are left out instead of drawing an error.
const [usageReachable, setUsageReachable] = signal(true)
const [shown, setShown] = signal({}) // provider id -> the weekly percent drawn now, for the count-up
const NAMES = { claude: "Claude", codex: "Codex" }
const PACE = { under: "under pace", onPace: "on pace", over: "over pace" }

// Moves a number from `from` to `to` over 12 frames of 50 ms, easing out; a newer tween of the
// same key ends the one before it.
const tweens = {}
function tween(key, set, from, to, frames = 12) {
  const gen = (tweens[key] = (tweens[key] ?? 0) + 1)
  let i = 0
  const step = () => {
    if (tweens[key] !== gen || mounts === 0) return set(to)
    i += 1
    set(from + (to - from) * (1 - Math.pow(1 - i / frames, 3)))
    if (i < frames) cmux.timer.after(50, step)
  }
  step()
}

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
    if (e && e.code === "operation.unsupported") return setUsageReachable(false)
    setUsageError(e && e.code === "scope.missing" ? "Turn on Usage for Widgets in Settings > Apps." : "The Usage app did not answer. Right-click to read it again.")
  }
}

const usageTone = (v) => (v === null ? cmux.theme.text.secondary : v < 15 ? cmux.theme.danger : v < 40 ? cmux.theme.warning : cmux.theme.success)

function meter(row) {
  const left = () => (row().weeklyLeft === null ? null : shown()[row().id] ?? 0)
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      Text(() => NAMES[row().id] ?? row().id).weight("semibold").fixedSize("horizontal"),
      Badge(() => `${row().usable}/${row().accounts}`, cmux.theme.accent).help("Accounts that can take work now, of all you have"),
      Spacer(),
      Text(() => (left() === null ? "–" : `${Math.round(left())}%`)).font("title3").monospaced().color(() => usageTone(row().weeklyLeft))
    ]),
    ProgressView(() => (left() === null ? null : left() / 100)),
    Text(() => {
      const r = row()
      const parts = ["left this week"]
      if (r.sessionLeft !== null) parts.push(`session ${Math.round(r.sessionLeft)}%`)
      if (r.verdict && PACE[r.verdict]) parts.push(PACE[r.verdict])
      if (r.extraUsd > 0) parts.push(`$${r.extraUsd.toFixed(2)} extra`)
      return parts.join(" · ")
    }).font("caption").color(cmux.theme.text.secondary)
  ])
}

// `only`: one provider id (a chat's harness), else every provider.
function usageCard(only) {
  const rows = computed(() => (usage() || []).filter((r) => !only || r.id === only))
  return () =>
    usageReachable()
      ? Panel({ title: only ? `${NAMES[only] ?? only} usage` : "Usage" }, [
          () => {
            if (usageError() && !usage()) return EmptyState({ title: "No usage here yet", message: usageError(), symbol: "context.usage" })
            if (!usage()) return ProgressView()
            if (!rows().length) return EmptyState({ title: "No accounts", message: "Add a Claude or Codex account in the Usage pane.", symbol: "account" })
            return VStack({ spacing: 8 }, [ForEach({ items: rows, key: (r) => r.id }, meter)])
          }
        ]).contextMenu([Button("Read usage now", () => loadUsage(true))])
      : null
}

// ---- Pull requests with their checks (github.changes) -------------------------------------------

const CHECKS = {
  failing: { symbol: "xmark.circle.fill", tone: cmux.theme.danger, label: "Checks failing" },
  pending: { symbol: "history", tone: cmux.theme.warning, label: "Checks running" },
  passing: { symbol: "checkmark.circle.fill", tone: cmux.theme.success, label: "Checks passed" },
  none: { symbol: "icon.clear", tone: cmux.theme.text.secondary, label: "No checks" }
}
const REVIEW = {
  approved: { text: "Approved", tone: cmux.theme.success },
  "changes-requested": { text: "Changes", tone: cmux.theme.danger },
  "review-required": { text: "Review", tone: cmux.theme.warning }
}
const checksOf = (p) => CHECKS[p.checks?.state] ?? CHECKS.none

function openPR(pr) {
  cmux.actions.run("openBrowser", { url: pr.url }).catch((e) =>
    cmux.toast({ title: "Turn on Run actions for Widgets to open pull requests", message: message(e), tone: "warning" })
  )
}

function prRow(p) {
  return Row({
    title: () => p().title,
    subtitle: () => {
      const c = p().checks || {}
      const checks = c.state === "none" ? "no checks" : `${c.passing}/${c.passing + c.failing + c.pending} checks`
      return `${p().repo.split("/").at(-1)} #${p().number} · +${p().additions} −${p().deletions} · ${checks}`
    },
    symbol: () => checksOf(p()).symbol,
    tint: () => checksOf(p()).tone,
    badge: () => (p().draft ? "Draft" : REVIEW[p().review]?.text)
  })
    .help(() => `${checksOf(p()).label} · ${p().url}`)
    .onTap(() => openPR(p()))
}

// Why the pull requests did not load, in words. A customize app installs sandboxed (no network)
// until you turn that off; the shared read then says it is sandboxed.
function prProblem(e) {
  const sandboxed = (e && e.details && e.details.sandboxed) || /sandboxed/i.test(String((e && e.message) || ""))
  if (sandboxed) return { title: "Pull requests need the network", message: "Widgets runs sandboxed. Turn off Run sandboxed for Widgets in Settings > Apps." }
  if (e && e.code === "scope.missing") return { title: "Pull requests are off", message: "Turn on pull requests for Widgets in Settings > Apps." }
  if (e && e.code === "integration.unavailable") return { title: "Not signed in", message: "Sign in with gh auth login to see your pull requests." }
  return { title: "Pull requests did not load", message: "They try again on their own." }
}

function prList(watch, empty) {
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => watch.value() || [], key: (p) => p.id }, prRow),
    () => (watch.error() && !watch.value() ? EmptyState({ ...prProblem(watch.error()), symbol: "git.pullrequest" }) : null),
    () => (!watch.value() && !watch.error() ? ProgressView() : null),
    () => (watch.value() && watch.value().length === 0 ? EmptyState({ title: empty, symbol: "status.success" }) : null)
  ])
}

function prCard(limit = 4) {
  const mine = cmux.watch("github.changes", { show: "mine", limit })
  const failing = computed(() => (mine.value() || []).filter((p) => p.checks?.state === "failing").length)
  return Panel({ title: "Pull requests" }, [
    () => (failing() ? Text(`${plural(failing(), "pull request")} with failing checks`).font("caption").color(cmux.theme.danger) : null),
    prList(mine, "No open pull requests")
  ])
}

// This chat's branch: its pull request with a bar of the checks that passed.
function branchCard(branch) {
  const found = cmux.watch("github.changes", { show: "search", query: `head:${branch}`, limit: 2 })
  const top = computed(() => (found.value() || [])[0] ?? null)
  return Panel({ title: "Branch" }, [
    Row({ title: branch, symbol: "git.branch", tint: cmux.theme.accent }),
    () => {
      const p = top()
      if (!p) return prList(found, `No pull request for ${branch}`)
      const c = p.checks || { passing: 0, failing: 0, pending: 0 }
      const total = c.passing + c.failing + c.pending
      const parts = [prRow(() => p)]
      if (total) {
        parts.push(ProgressView(c.passing / total))
        parts.push(Text(`${c.passing} passed · ${c.pending} running · ${c.failing} failed`).font("caption").color(checksOf(p).tone))
      }
      return VStack({ spacing: 4 }, parts)
    }
  ])
}

// ---- This chat (Session Info) -------------------------------------------------------------------

const harnessProvider = (h) => {
  const s = String(h || "").toLowerCase()
  return s.includes("claude") ? "claude" : s.includes("codex") ? "codex" : null
}

function chatCard(context) {
  const chats = chatList()
  const mine = computed(() => (chats() || []).find((c) => c.id === context.session_id) ?? null)
  return Panel({ title: "Agent" }, [
    HStack({ spacing: 8 }, [
      Icon(() => (mine() ? stateOf(mine()).symbol : "agent.session"))
        .font("largeTitle")
        .color(() => (mine() ? stateOf(mine()).tone : cmux.theme.text.secondary))
        .animation("smooth"),
      VStack({ spacing: 2, alignment: "leading" }, [
        Text(() => (mine() ? stateOf(mine()).label : "This chat")).font("headline").lineLimit(1),
        Text(() => {
          const parts = [context.harness || mine()?.harness || "agent"]
          const folder = String(context.cwd || mine()?.cwd || "").split("/").filter(Boolean).at(-1)
          if (folder) parts.push(folder)
          if (mine()) parts.push(ago(changedAt(mine()), now()))
          return parts.join(" · ")
        })
          .font("caption")
          .color(cmux.theme.text.secondary)
      ]),
      Spacer()
    ])
  ])
}

// ---- The three places ---------------------------------------------------------------------------

function renderSidebar() {
  start()
  return VStack({ spacing: 8 }, [todayCard(), agentsCard({ rows: 2 }), usageCard(), prCard(4)])
}

function renderSessionInfo(context) {
  start()
  const ctx = context || {}
  const provider = harnessProvider(ctx.harness)
  const branch = String(ctx.branch || "").trim()
  const cards = [chatCard(ctx), usageCard(provider)]
  if (branch) cards.push(branchCard(branch))
  return VStack({ spacing: 8 }, cards)
}

function renderPage() {
  start()
  return VStack({ spacing: 12 }, [
    HStack({ spacing: 8 }, [
      Icon("view.grid").font("largeTitle").color(cmux.theme.accent),
      VStack({ spacing: 2, alignment: "leading" }, [
        Text("Widgets").font("largeTitle").weight("bold"),
        Text("Each card is one function in ~/.config/cmux/customize/main.js. Save it and this page draws it again.").color(cmux.theme.text.secondary)
      ]),
      Spacer()
    ]),
    // The page has no wrap and no pane width to read, so the cards go two a row, each half of the row
    // whatever its content (a width of "infinity" in both makes their flex bases equal): the time
    // beside your agents, then usage beside your pull requests. It fits a pane from 600 pt up.
    HStack({ spacing: 12, alignment: "top" }, [
      VStack({ spacing: 12 }, [todayCard(true), worldClockCard()]),
      agentsCard({ rows: 6, page: true })
    ].map((cell) => cell.frame({ width: "infinity" }))),
    // Where this cmux does not share the Usage app with views, the pull requests take the whole row.
    () =>
      usageReachable()
        ? HStack({ spacing: 12, alignment: "top" }, [VStack([usageCard()]), prCard(6)].map((cell) => cell.frame({ width: "infinity" })))
        : prCard(6),
    Spacer()
  ]).padding()
}

globalThis.__cmuxAppExports = { renderSidebar, renderSessionInfo, renderPage }
