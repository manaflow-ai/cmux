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

globalThis.__cmuxAppExports = { renderPicker }
