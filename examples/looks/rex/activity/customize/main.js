// Public app SDK only. Invalidation events refresh the cached chat index; no polling.
// Activity: every chat that needs attention, grouped by priority (needs input, failed or lost,
// unread, working) or by project. Idle chats are hidden until "Include idle" is on.
const [chats, setChats] = signal([])
const [error, setError] = signal(null)
const [loaded, setLoaded] = signal(false)
const [readAt, setReadAt] = signal(Date.now())
const [mode, setMode] = signal("priority") // "priority" | "project"
const [idle, setIdle] = signal(false)
const message = e => e instanceof Error ? e.message : String(e)
const run = (id, args) => cmux.actions.run(id, args).catch(e =>
  cmux.toast({ title: "Could not open", message: message(e), tone: "warning" }))
const hostName = c => c.machine || "This Mac"
// Identical session ids on different peers must remain separate rows.
const chatKey = c => JSON.stringify([c.machine || "", c.id])
const latest = c => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
cmux.storage.get("mode").then(saved => (saved === "priority" || saved === "project") && setMode(saved)).catch(() => undefined)
function choose(next) {
  setMode(next)
  cmux.storage.set("mode", next).catch(() => undefined)
}
// Unread is not proof that a program completed successfully, so it is not called Done.
const LEVELS = [
  { id: "input", title: "Needs input", symbol: "status.needsinput", tone: () => cmux.theme.warning },
  { id: "failed", title: "Failed or lost", symbol: "status.critical", tone: () => cmux.theme.danger },
  { id: "unread", title: "Unread", symbol: "notification", tone: () => cmux.theme.accent },
  { id: "working", title: "Working", symbol: "agent.session", tone: () => cmux.theme.accent },
  { id: "idle", title: "Idle", symbol: "agent.chat", tone: () => cmux.theme.text.secondary }
]
function levelOf(c) {
  if (c.state === "input") return "input"
  if (c.state === "failed" || c.state === "lost") return "failed"
  if (c.unread) return "unread"
  if (c.state === "working") return "working"
  return "idle"
}
const level = c => LEVELS.find(l => l.id === levelOf(c))
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((readAt() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}
const visible = computed(() => [...chats()]
  .filter(c => idle() || levelOf(c) !== "idle")
  .sort((a, b) => latest(b) - latest(a)))
const groups = computed(() => {
  if (mode() === "priority") {
    return LEVELS.map(l => ({ id: l.id, title: l.title, symbol: l.symbol, tone: l.tone(),
      chats: visible().filter(c => levelOf(c) === l.id) })).filter(g => g.chats.length)
  }
  const by = new Map()
  for (const c of visible()) {
    const title = c.project || hostName(c)
    const id = JSON.stringify([c.machine || "", title])
    if (!by.has(id)) by.set(id, { id, title, symbol: "folder", tone: cmux.theme.text.secondary, chats: [] })
    by.get(id).chats.push(c)
  }
  return [...by.values()]
})
function show(c) {
  // Focus the actual chat, not merely a workspace that may contain other tabs.
  return run("agent.openSessionTab", c.machine ? { session: c.id, host: c.machine } : { session: c.id })
}
function chatRow(c) {
  return Row({
    title: () => c().title || c().id,
    subtitle: () => [mode() === "priority" ? c().project : level(c()).title, c().machine,
      c().error || c().step].filter(Boolean).join(" · "),
    symbol: () => level(c()).symbol,
    tint: () => level(c()).tone(),
    unread: () => Boolean(c().unread),
    badge: () => age(latest(c())) || null
  }).help(() => [c().id, hostName(c()), c().cwd].filter(Boolean).join("\n")).onTap(() => show(c()))
}
function groupHeader(g) {
  return HStack({ spacing: 6 }, [
    Icon(() => g().symbol).size(10).color(() => g().tone),
    Text(() => g().title).font("caption").weight("semibold").color(cmux.theme.text.secondary).lineLimit(1),
    Spacer(),
    Text(() => String(g().chats.length)).font("caption").monospaced().color(cmux.theme.text.secondary)
  ])
}
let reading = false
let again = false
async function load() {
  if (reading) { again = true; return }
  reading = true
  try {
    const list = await cmux.call("agent_chat.list", {})
    setChats(list.chats)
    setReadAt(Date.now())
    setError(null)
    setLoaded(true)
  } catch (e) {
    setError(message(e))
  } finally {
    reading = false
    if (again) { again = false; load() }
  }
}
// Subscribe for the lifetime of all visible mounts. The SDK disposes a
// subscription made inside a render when that particular view closes.
const [readers, setReaders] = signal(0)
let unsubscribe
effect(() => {
  if (readers() && !unsubscribe) {
    unsubscribe = cmux.events.on("agent_chat.changed", load)
    load()
  } else if (!readers() && unsubscribe) {
    unsubscribe()
    unsubscribe = null
  }
})
function follow() {
  setReaders(n => n + 1)
  onCleanup(() => setReaders(n => n - 1))
}

function renderActivity() {
  follow()
  return VStack([
    HStack([
      Button(() => mode() === "priority" ? "By priority" : "By project",
        () => choose(mode() === "priority" ? "project" : "priority")),
      Spacer(),
      Toggle(idle, { label: "Include idle", onChange: setIdle })
    ]),
    () => error() ? VStack([
      EmptyState({ title: "Activity unavailable", message: error(), symbol: "status.critical" }),
      Button("Retry", load)
    ]) : null,
    () => !loaded() && !error() ? Text("Loading activity…").color(cmux.theme.text.secondary) : null,
    ForEach({ items: () => error() ? [] : groups(), key: g => g.id }, g => VStack([
      groupHeader(g),
      ForEach({ items: () => g().chats, key: chatKey }, chatRow)
    ])),
    () => loaded() && !error() && !visible().length
      ? EmptyState({ title: "Nothing needs you", message: "Chats that work, wait for input, fail or finish unread show up here.", symbol: "agent.chat" }) : null
  ])
}

globalThis.__cmuxAppExports = { renderActivity }
