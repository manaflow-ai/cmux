// Public app SDK only. Invalidation events refresh the cached chat index; no polling.
const [chats, setChats] = signal([])
const [error, setError] = signal(null)
const [loaded, setLoaded] = signal(false)
const message = e => e instanceof Error ? e.message : String(e)
const run = (id, args) => cmux.actions.run(id, args).catch(e =>
  cmux.toast({ title: "Could not open", message: message(e), tone: "warning" }))
const hostKey = c => c.machine || ""
const hostName = c => c.machine || "This Mac"
// Identical session ids on different peers must remain separate rows.
const chatKey = c => JSON.stringify([hostKey(c), c.id])
const latest = c => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const sorted = computed(() => [...chats()].sort((a, b) => latest(b) - latest(a)))
const matches = (c, query) => [c.title, c.id, hostName(c), c.cwd, c.project, c.harness]
  .some(value => String(value || "").toLowerCase().includes(query.trim().toLowerCase()))
function status(c) {
  if (c.state === "working") return { label: "Working", symbol: "agent.session", tone: cmux.theme.accent }
  if (c.state === "input") return { label: "Needs input", symbol: "status.needsinput", tone: cmux.theme.warning }
  if (c.state === "failed") return { label: "Failed", symbol: "status.critical", tone: cmux.theme.danger }
  if (c.state === "lost") return { label: "Lost", symbol: "status.critical", tone: cmux.theme.danger }
  // Unread is not proof that a program completed successfully.
  if (c.unread) return { label: "Unread", symbol: "notification", tone: cmux.theme.accent }
  return { label: "Idle", symbol: "agent.chat", tone: cmux.theme.text.secondary }
}
function show(c) {
  // Focus the actual chat, not merely a workspace that may contain other tabs.
  return run("agent.openSessionTab", c.machine ? { session: c.id, host: c.machine } : { session: c.id })
}
function sessionRow(c) {
  return Row({
    title: () => c().title || c().id,
    subtitle: () => [hostName(c()), status(c()).label, c().error || c().step || c().project].filter(Boolean).join(" · "),
    symbol: () => status(c()).symbol,
    tint: () => status(c()).tone,
    unread: () => Boolean(c().unread),
    badge: () => c().harness || null
  }).help(() => [c().id, c().cwd].filter(Boolean).join("\n")).onTap(() => show(c()))
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
function readState() {
  if (error()) return VStack([
    EmptyState({ title: "Sessions unavailable", message: error(), symbol: "status.critical" }),
    Button("Retry", load)
  ])
  if (!loaded()) return Text("Loading sessions…").color(cmux.theme.text.secondary)
  return null
}


function renderHostList() {
  const [query, setQuery] = signal("")
  const [selected, setSelected] = signal("")
  const hosts = computed(() => {
    const counts = new Map([["", 0]])
    for (const c of sorted()) counts.set(hostKey(c), (counts.get(hostKey(c)) || 0) + 1)
    return [...counts].map(([id, count]) => ({ id, name: id || "This Mac", count }))
  })
  const sessions = computed(() => sorted().filter(c => hostKey(c) === selected() && matches(c, query())))
  return VStack([
    Text("Choose a host, then open one of its chats.").font("caption").color(cmux.theme.text.secondary),
    readState,
    ForEach({ items: hosts, key: h => h.id }, h => Row({
      title: () => h().name,
      symbol: "terminal.fill",
      selected: () => selected() === h().id,
      badge: () => error() ? null : String(h().count)
    }).onTap(() => setSelected(h().id))),
    Button("New chat on selected host", () => run("palette.newAgentChat", { host: selected() || "local" })),
    Button("Add Host…", () => run("server.addServer")),
    TextField(query, { placeholder: "Find a session on this host", onEdit: setQuery,
      onSubmit: () => { const first = sessions()[0]; if (first && !error()) show(first) } }),
    ForEach({ items: () => error() ? [] : sessions(), key: chatKey }, sessionRow),
    () => loaded() && !error() && !sessions().length
      ? EmptyState({ title: "No matching sessions on this host", message: "Start a chat or change the search.", symbol: "agent.chat" }) : null
  ])
}

// Activity, the sidebar's second mode (the source's Toggle Activity): the same chat index grouped
// by priority or project. The mode persists per app.
const [readAt, setReadAt] = signal(Date.now())
const [mode, setMode] = signal("priority") // "priority" | "project"
const [idle, setIdle] = signal(false)
const [sidebarMode, setSidebarMode] = signal("hosts") // "hosts" | "activity"
cmux.storage.get("mode").then(saved => (saved === "priority" || saved === "project") && setMode(saved)).catch(() => undefined)
cmux.storage.get("sidebar-mode").then(saved => (saved === "hosts" || saved === "activity") && setSidebarMode(saved)).catch(() => undefined)
function choose(next) {
  setMode(next)
  cmux.storage.set("mode", next).catch(() => undefined)
}
function chooseSidebar(next) {
  setSidebarMode(next)
  cmux.storage.set("sidebar-mode", next).catch(() => undefined)
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
function renderActivityList() {
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


function renderHosts() {
  follow()
  return VStack([
    Button(() => sidebarMode() === "hosts" ? "Show activity" : "Show hosts",
      () => chooseSidebar(sidebarMode() === "hosts" ? "activity" : "hosts")),
    () => sidebarMode() === "hosts" ? renderHostList() : renderActivityList()
  ])
}

function renderLauncher() {
  return VStack({ alignment: "leading", spacing: 4 }, [
    Text("New Tab").font("headline"),
    Row({ title: "New Tab in Session", symbol: "terminal" })
      .onTap(() => run("newSurface")),
    Row({ title: "New Local Session", symbol: "plus.rectangle.on.rectangle" })
      .onTap(() => run("workspace.newOnMachine", { machine: "local" })),
    Row({ title: "New Session on Host…", symbol: "desktopcomputer" })
      .onTap(() => run("palette.open", { query: "New Workspace on Machine" })),
    Row({ title: "Add Remote Host…", symbol: "plus" })
      .onTap(() => run("remote.connect"))
  ])
}

function renderPicker() {
  follow()
  const [query, setQuery] = signal("")
  const [activityOnly, setActivityOnly] = signal(false)
  const active = c => c.state !== "idle" || c.unread
  const visible = computed(() => sorted().filter(c => matches(c, query()) && (!activityOnly() || active(c))))
  return VStack([
    Text("Sessions").font("title").weight("semibold"),
    Text("Find a chat on this Mac or a connected host.").color(cmux.theme.text.secondary),
    TextField(query, { placeholder: "Search sessions, hosts or folders", onEdit: setQuery,
      onSubmit: () => { const first = visible()[0]; if (first && !error()) show(first) } }),
    HStack([
      Button(() => activityOnly() ? "Show all sessions" : "Show activity", () => setActivityOnly(!activityOnly())),
      Button("New local chat", () => run("palette.newAgentChat", { host: "local" }))
    ]),
    readState,
    ForEach({ items: () => error() ? [] : visible(), key: chatKey }, sessionRow),
    () => loaded() && !error() && !visible().length
      ? EmptyState({ title: chats().length ? "No matching sessions" : "No sessions yet",
          message: "Start a chat or change the search and activity filter.", symbol: "agent.chat" }) : null
  ])
}

function renderNewTab() {
  return VStack({ alignment: "leading", spacing: 12 }, [
    renderLauncher(),
    renderPicker()
  ]).padding(12)
}

globalThis.__cmuxAppExports = { renderHosts, renderNewTab }
