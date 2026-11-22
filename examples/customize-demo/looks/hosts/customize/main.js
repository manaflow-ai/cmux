// Hosts: a hosts list (This Mac and every machine your sessions run on, each with a leading
// identity icon and its sessions under it, every session with its program status and what it is
// doing now, plus Add Host), a session picker on every New Tab, a block card in Session Info,
// and a status-line hover card.
// One chat read per change (agent_chat.changed); nothing polls.

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [query, setQuery] = signal("")
const [folded, setFolded] = signal({}) // host -> true when its sessions are folded
// Bound both dimensions: a busy fleet otherwise builds thousands of reactive nodes and
// exhausts the app host's per-entry budget. Paging keeps every host and session reachable.
const HOSTS_PER_PAGE = 6
const SESSIONS_PER_PAGE = 6
const [hostPage, setHostPage] = signal(0)
const [pickerPage, setPickerPage] = signal(0)
const [sessionPages, setSessionPages] = signal({})
const pageIndex = (page, count, size) => Math.min(page, Math.max(0, Math.ceil(count / size) - 1))
const pageItems = (items, page, size) => {
  const start = pageIndex(page, items.length, size) * size
  return items.slice(start, start + size)
}

function pager(items, page, setPage, size, label, compact = false) {
  const current = () => pageIndex(page(), items().length, size)
  return () => items().length > size ? HStack({ spacing: 6 }, [
    (compact
      ? Button(Icon("chevron.left"), () => setPage(current() - 1)).help(`Previous ${label}`)
      : Button(`Previous ${label}`, () => setPage(current() - 1))
    ).disabled(() => current() === 0),
    Text(() => `${current() + 1} / ${Math.ceil(items().length / size)}`).font("caption").monospaced().fixedSize("horizontal"),
    (compact
      ? Button(Icon("chevron.right"), () => setPage(current() + 1)).help(`Next ${label}`)
      : Button(`Next ${label}`, () => setPage(current() + 1))
    ).disabled(() => (current() + 1) * size >= items().length)
  ]) : null
}

const sessionPage = (name) => sessionPages()[name] || 0
const setSessionPage = (name, page) => setSessionPages((s) => ({ ...s, [name]: page }))

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Hosts`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

// Folded hosts are remembered with storage:local; without it they unfold on a reload.
cmux.storage
  .get("folded")
  .then((saved) => saved && setFolded((s) => ({ ...saved, ...s })))
  .catch(() => undefined)
const saveFolded = () => cmux.storage.set("folded", folded()).catch(() => undefined)

let reading = false
let again = false
async function loadChats() {
  if (reading) return void (again = true)
  reading = true
  try {
    const [list, workspaces] = await Promise.all([cmux.call("agent_chat.list", {}), cmux.workspace.list({}).catch(() => [])])
    setChats(list.chats)
    setOpenWorkspace((workspaces.find((w) => w.focused) || {}).id || null)
    setNow(Date.now())
  } catch (e) {
    setChats([])
  } finally {
    reading = false
    if (again) {
      again = false
      loadChats()
    }
  }
}

let following = false
function follow() {
  if (following) return
  following = true
  loadChats()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("workspace.changed", loadChats)
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const LOCAL = "This Mac"
const hostOf = (c) => c.machine || LOCAL
const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()
// A peer's session opens as this Mac mirrors it: agent.openSessionTab takes the peer as `host`.
const tabArgs = (c) => (c.machine ? { session: c.id, host: c.machine } : { session: c.id })

function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

// The program status (OSC 7501's idle, working, blocked, done, error), from the chat's state.
function statusOf(c) {
  if (c.state === "working") return { word: "working", symbol: "circle.dashed", tone: cmux.theme.accent }
  if (c.state === "input") return { word: "blocked", symbol: "hand.raised", tone: cmux.theme.warning }
  if (c.state === "failed" || c.state === "lost") return { word: "error", symbol: "xmark.octagon", tone: cmux.theme.danger }
  if (c.unread) return { word: "done", symbol: "checkmark.circle", tone: cmux.theme.success }
  return { word: "idle", symbol: "circle", tone: cmux.theme.text.tertiary }
}

// A host's identity icon: this Mac, a cloud machine, or a server.
function hostSymbol(name) {
  if (name === LOCAL) return "laptopcomputer"
  if (/cloud/i.test(name)) return "cloud"
  return "server.rack"
}

const hosts = computed(() => {
  const groups = new Map([[LOCAL, { name: LOCAL, sessions: [] }]])
  for (const c of [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    const name = hostOf(c)
    if (!groups.has(name)) groups.set(name, { name, sessions: [] })
    groups.get(name).sessions.push(c)
  }
  // Activity still sorts sessions within a host, but must not move hosts between pages.
  return [...groups.values()].sort((a, b) => a.name === b.name ? 0 : a.name === LOCAL ? -1 : b.name === LOCAL ? 1 : a.name < b.name ? -1 : 1)
})

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", tabArgs(chat))
}

function fold(name) {
  setFolded((s) => ({ ...s, [name]: !s[name] }))
  saveFolded()
}

// ---- Sidebar: hosts and their sessions ---------------------------------------------------------

function session(c) {
  const s = () => statusOf(c())
  return HStack({ spacing: 8 }, [
    Icon(() => s().symbol).size(11).color(() => s().tone),
    VStack({ spacing: 1, alignment: "leading" }, [
      Text(() => c().title)
        .font(12)
        .weight(() => (isOpen(c()) || s().word !== "idle" ? "medium" : "regular"))
        .color(() => (isOpen(c()) || s().word !== "idle" ? "primary" : "secondary"))
        .lineLimit(1),
      Text(() => [s().word, c().error || c().step].filter(Boolean).join(" · "))
        .font("caption")
        .color(cmux.theme.text.tertiary)
        .lineLimit(1)
    ]),
    Spacer(),
    Text(() => age(lastActivity(c()))).font("caption").monospaced().color(cmux.theme.text.tertiary).fixedSize("horizontal")
  ])
    .paddingHorizontal(10)
    .frame({ height: 38 })
    .cornerRadius(8)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground(() => (isOpen(c()) ? "selected" : "hover"))
    .help(() => [c().title, hostOf(c()), c().cwd, c().harness].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(() => [Button("Open in New Tab", () => run("agent.openSessionTab", tabArgs(c())))])
}

function hostHeader(h) {
  const busy = () => h().sessions.filter((c) => statusOf(c).word === "working").length
  const blocked = () => h().sessions.filter((c) => statusOf(c).word === "blocked").length
  return HStack({ spacing: 8 }, [
    Icon(() => hostSymbol(h().name)).size(12).color(cmux.theme.text.secondary),
    Text(() => h().name).font(12).weight("semibold").lineLimit(1),
    Spacer(),
    () => (blocked() ? Icon("hand.raised").size(9).color(cmux.theme.warning) : null),
    () => (busy() ? Icon("circle.dashed").size(9).color(cmux.theme.accent) : null),
    Text(() => String(h().sessions.length)).font("caption").monospaced().color(cmux.theme.text.tertiary),
    Icon("chevron.right").size(8).color(cmux.theme.text.tertiary).rotation(() => (folded()[h().name] ? 0 : 90))
  ])
    .paddingHorizontal(10)
    .frame({ height: 28 })
    .cornerRadius(8)
    .hoverBackground("hover")
    .cursor("pointer")
    .onTap(() => fold(h().name))
}

function renderHosts() {
  follow()
  return VStack({ spacing: 2 }, [
    ForEach({ items: () => pageItems(hosts(), hostPage(), HOSTS_PER_PAGE), key: (h) => h.name }, (h) =>
      VStack({ spacing: 1 }, [
        hostHeader(h),
        pager(() => folded()[h().name] ? [] : h().sessions, () => sessionPage(h().name), (page) => setSessionPage(h().name, page), SESSIONS_PER_PAGE, "sessions", true),
        ForEach({ items: () => pageItems(folded()[h().name] ? h().sessions.filter(isOpen) : h().sessions, sessionPage(h().name), SESSIONS_PER_PAGE), key: (c) => c.id }, session),
        () => (h().sessions.length || folded()[h().name] ? null : Text("No sessions").font("caption").color(cmux.theme.text.tertiary).paddingHorizontal(30))
      ])
    ),
    pager(hosts, hostPage, setHostPage, HOSTS_PER_PAGE, "hosts"),
    HStack({ spacing: 8 }, [Icon("plus").size(11).color(cmux.theme.text.secondary), Text("Add Host").font(12).color("secondary"), Spacer()])
      .paddingHorizontal(10)
      .frame({ height: 28 })
      .cornerRadius(8)
      .hoverBackground("hover")
      .cursor("pointer")
      .onTap(() => run("server.addServer"))
  ])
}

// ---- New Tab: the session picker -------------------------------------------------------------

const matches = (c) => {
  const q = query().trim().toLowerCase()
  if (!q) return true
  return [c.title, hostOf(c), c.project, c.cwd, c.harness].some((v) => v && String(v).toLowerCase().includes(q))
}

function renderPicker() {
  follow()
  const matchingHosts = computed(() => hosts().map((h) => ({ ...h, sessions: h.sessions.filter(matches) })).filter((h) => h.sessions.length))
  const counts = computed(() => {
    const words = chats().map((c) => statusOf(c).word)
    return { working: words.filter((w) => w === "working").length, blocked: words.filter((w) => w === "blocked").length, hosts: hosts().filter((h) => h.sessions.length).length }
  })
  return VStack({ spacing: 14 }, [
    Spacer(),
    HStack({ spacing: 8 }, [
      Text("Sessions").font("title").weight("semibold"),
      Spacer(),
      Text(() => `${counts().hosts} ${counts().hosts === 1 ? "host" : "hosts"} ·${counts().working} working · ${counts().blocked} blocked`).font("caption").monospaced().color(cmux.theme.text.secondary)
    ]),
    Panel({ style: "card" }, [
      TextField(query, { placeholder: "Find a session on any host", onEdit: (value) => {
        setPickerPage(0)
        setSessionPages({})
        setQuery(value)
      }, onSubmit: () => {
        const first = chats().filter(matches).sort((a, b) => lastActivity(b) - lastActivity(a))[0]
        if (first) show(first)
      } }),
      HStack({ spacing: 6 }, [
        Button(HStack({ spacing: 4 }, [Icon("terminal"), Text("New session")]), () => run("palette.newAgentChat")),
        Button(HStack({ spacing: 4 }, [Icon("plus"), Text("Add Host")]), () => run("server.addServer")),
        Spacer()
      ])
    ]),
    ForEach({ items: () => pageItems(matchingHosts(), pickerPage(), HOSTS_PER_PAGE), key: (h) => h.name }, (h) =>
      Panel({ title: () => h().name, style: "card" }, [
        ForEach({ items: () => pageItems(h().sessions, sessionPage(h().name), SESSIONS_PER_PAGE), key: (c) => c.id }, (c) =>
          Row({
            title: () => c().title,
            subtitle: () => [statusOf(c()).word, c().step || c().project].filter(Boolean).join(" · "),
            symbol: () => statusOf(c()).symbol,
            tint: () => statusOf(c()).tone,
            accessory: () => age(lastActivity(c()))
          }).onTap(() => show(c()))
        ),
        pager(() => h().sessions, () => sessionPage(h().name), (page) => setSessionPage(h().name, page), SESSIONS_PER_PAGE, "sessions", true)
      ])
    ),
    pager(matchingHosts, pickerPage, setPickerPage, HOSTS_PER_PAGE, "hosts"),
    () => (chats().length ? null : EmptyState({ title: "No sessions yet", message: "Shift-Command-O starts one.", symbol: "terminal" })),
    Spacer()
  ])
}

// ---- Session Info: the block card ---------------------------------------------------------------

function fact(label, value) {
  return () =>
    value()
      ? HStack({ spacing: 6 }, [
          Text(label).font("caption").color(cmux.theme.text.tertiary).frame({ width: 64 }),
          Text(value).font("caption").monospaced().lineLimit(1).truncation("middle"),
          Spacer()
        ])
      : null
}

function renderBlock(context) {
  follow()
  const id = context && context.session_id
  const chat = computed(() => chats().find((c) => c.id === id) || null)
  return VStack({ spacing: 3 }, [
    () => {
      const s = chat() && statusOf(chat())
      return HStack({ spacing: 6 }, [
        Text(() => (chat() ? chat().title : "This session")).weight("semibold").lineLimit(1),
        Spacer(),
        s ? HStack({ spacing: 3 }, [Icon(s.symbol).size(9).color(s.tone), Text(s.word).font("caption").color(s.tone)]) : null
      ])
    },
    fact("Host", () => (chat() ? hostOf(chat()) : "")),
    fact("Session", () => String(id || "")),
    fact("Agent", () => String((context && context.harness) || (chat() && chat().harness) || "")),
    fact("Folder", () => String((context && context.cwd) || (chat() && chat().cwd) || "")),
    fact("Now", () => (chat() ? chat().error || chat().step || "" : "")),
    fact("Since", () => (chat() && chat().since_ms ? `${age(chat().since_ms)} ago` : ""))
  ])
}

// ---- Hover card: a status line --------------------------------------------------------------

const ORDER = ["needsInput", "task", "command", "presence", "branch", "folder"]

function renderCard(ctx) {
  const card = ctx.card
  const since = (ms) => (ms ? age(ms) : "")
  const facts = ORDER.flatMap((kind) => card.facts.filter((f) => f.kind === kind))
  return VStack({ spacing: 3 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    card.status ? Text(`${card.status} ${since(card.statusSinceMs)}`.trim()).monospaced().secondary() : null,
    ...facts.map((f) => HStack([Text(f.text).monospaced().lineLimit(1), Spacer(), f.sinceMs ? Text(since(f.sinceMs)).secondary() : null]))
  ])
}

globalThis.__cmuxAppExports = { renderHosts, renderPicker, renderBlock, renderCard }
