// Public app SDK only. Invalidation events refresh the cached chat index; no polling.
const [chats, setChats] = signal([])
const [error, setError] = signal(null)
const [loaded, setLoaded] = signal(false)
const [query, setQuery] = signal("")
const message = e => e instanceof Error ? e.message : String(e)
const run = (id, args) => cmux.actions.run(id, args).catch(e =>
  cmux.toast({ title: "Could not open", message: message(e), tone: "warning" }))
const hostKey = c => c.machine || ""
const hostName = c => c.machine || "This Mac"
// Identical session ids on different peers must remain separate rows.
const chatKey = c => JSON.stringify([hostKey(c), c.id])
const latest = c => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const sorted = computed(() => [...chats()].sort((a, b) => latest(b) - latest(a)))
const matches = c => [c.title, c.id, hostName(c), c.cwd, c.project, c.harness]
  .some(value => String(value || "").toLowerCase().includes(query().trim().toLowerCase()))
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
    setError(null)
    setLoaded(true)
  } catch (e) {
    setError(message(e))
  } finally {
    reading = false
    if (again) { again = false; load() }
  }
}
let following = false
function follow() {
  if (following) return
  following = true
  cmux.events.on("agent_chat.changed", load)
  load()
}
function readState() {
  if (error()) return VStack([
    EmptyState({ title: "Sessions unavailable", message: error(), symbol: "status.critical" }),
    Button("Retry", load)
  ])
  if (!loaded()) return Text("Loading sessions…").color(cmux.theme.text.secondary)
  return null
}

const [selected, setSelected] = signal("")
const hosts = computed(() => {
  const found = new Map([["", { id: "", name: "This Mac" }]])
  for (const c of sorted()) if (c.machine) found.set(c.machine, { id: c.machine, name: c.machine })
  return [...found.values()]
})
const sessions = computed(() => sorted().filter(c => hostKey(c) === selected() && matches(c)))
function renderHosts() {
  follow()
  return VStack([
    Text("Choose a host, then open one of its chats.").font("caption").color(cmux.theme.text.secondary),
    readState,
    ForEach({ items: hosts, key: h => h.id }, h => Row({
      title: () => h().name,
      symbol: "terminal.fill",
      selected: () => selected() === h().id,
      badge: () => error() ? null : String(chats().filter(c => hostKey(c) === h().id).length)
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
globalThis.__cmuxAppExports = { renderHosts }
