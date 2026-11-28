// Activity and Archive views of your agent chats, after a desktop coding agent app's. One sidebar
// section (cmux.section/1) with two views you flip between: Activity (Priority first, then Today,
// Yesterday and older days; Mark all as read; Clear read chats) and Archive (search, Unarchive).
// The host has no archive or mark-read op for chats yet, so read, cleared and archived marks live in
// this app's own storage, keyed to a chat's last change: a chat that moves again comes back.

const ROW_HEIGHT = 36
const ROW_RADIUS = 10
const TEXT = 14

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [view, setView] = signal("activity") // "activity" | "archive"
const [query, setQuery] = signal("")
const [loaded, setLoaded] = signal(false)
// id -> the chat's last change when you marked it. read: seen; cleared: hidden from Activity;
// archived: in the Archive view.
const [marks, setMarks] = signal({ read: {}, cleared: {}, archived: {} })

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

function mark(kind, ids) {
  const at = Object.fromEntries(ids.map((id) => [id, changed(chats().find((c) => c.id === id) || {})]))
  const next = { ...marks(), [kind]: { ...marks()[kind], ...at } }
  setMarks(next)
  cmux.storage.set("threads.marks", next).catch(() => {})
}

function unmark(kind, id) {
  const { [id]: _gone, ...rest } = marks()[kind]
  const next = { ...marks(), [kind]: rest }
  setMarks(next)
  cmux.storage.set("threads.marks", next).catch(() => {})
}

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
    setLoaded(true)
  } catch (e) {
    setChats([])
    setLoaded(true)
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
  cmux.storage.get("threads.marks").then((saved) => saved && setMarks({ read: {}, cleared: {}, archived: {}, ...saved })).catch(() => {})
  loadChats()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("workspace.changed", loadChats)
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const changed = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
// A mark holds only while the chat has not moved since.
const held = (kind, c) => marks()[kind][c.id] !== undefined && marks()[kind][c.id] >= changed(c)
const isArchived = (c) => held("archived", c)
const needsYou = (c) => c.state === "input" || c.state === "approval"
const isUnread = (c) => c.unread && !held("read", c)
const isRead = (c) => !needsYou(c) && c.state !== "working" && !isUnread(c)
const title = (c) => (c.title && c.title.trim()) || "Untitled chat"
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()

function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const startOfDay = (ms) => {
  const d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}
function dayHeading(ms) {
  const days = Math.round((startOfDay(now()) - startOfDay(ms)) / 86_400_000)
  if (days <= 0) return "Today"
  if (days === 1) return "Yesterday"
  return new Date(ms).toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" })
}

const live = computed(() => chats().filter((c) => !isArchived(c)))
// Priority: waiting on you, or unread. Cleared chats leave the list until their next turn.
const priority = computed(() => live().filter((c) => needsYou(c) || isUnread(c)).sort((a, b) => changed(b) - changed(a)))
const recent = computed(() =>
  live()
    .filter((c) => !priority().includes(c) && !held("cleared", c))
    .sort((a, b) => changed(b) - changed(a))
)
const days = computed(() => {
  const groups = []
  for (const c of recent()) {
    const name = dayHeading(changed(c))
    const last = groups[groups.length - 1]
    if (last && last.name === name) last.threads.push(c)
    else groups.push({ name, threads: [c] })
  }
  return groups
})
const archived = computed(() => {
  const q = query().trim().toLowerCase()
  return chats()
    .filter(isArchived)
    .filter((c) => !q || `${title(c)} ${c.project || ""}`.toLowerCase().includes(q))
    .sort((a, b) => changed(b) - changed(a))
})
const archivedCount = computed(() => chats().filter(isArchived).length)

function show(chat) {
  mark("read", [chat.id])
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

// "Chat · web": the kind of chat, then its project.
const detail = (c) => [c.harness ? c.harness[0].toUpperCase() + c.harness.slice(1) : "Chat", c.project].filter(Boolean).join(" · ")

function status(c) {
  return HStack({ spacing: 0 }, [
    () =>
      c().state === "working"
        ? ProgressView().frame({ width: 12, height: 12 })
        : needsYou(c())
          ? Icon("questionmark.circle").size(13).color(cmux.theme.warning)
          : isUnread(c())
            ? Icon("circle.fill").size(8).color(cmux.theme.accent)
            : null
  ]).frame({ width: 16, height: 16 })
}

function row(c, trailing) {
  return HStack({ spacing: 8 }, [
    status(c),
    VStack({ spacing: 0, alignment: "leading" }, [
      Text(() => title(c())).font(TEXT).weight(() => (isUnread(c()) ? "medium" : "regular")).lineLimit(1),
      Text(() => detail(c())).font("caption").color(cmux.theme.text.tertiary).lineLimit(1)
    ]),
    Spacer(),
    trailing(c)
  ])
    .paddingHorizontal(10)
    .frame({ height: 44 })
    .cornerRadius(ROW_RADIUS)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground(() => (isOpen(c()) ? "selected" : "hover"))
    .help(() => [title(c()), c().cwd, c().step].filter(Boolean).join("\n"))
    .cursor("pointer")
}

const activityRow = (c) =>
  row(c, (item) => Text(() => age(changed(item()))).font(TEXT).color(cmux.theme.text.tertiary).monospaced().fixedSize("horizontal"))
    .onTap(() => show(c()))
    .contextMenu(() => [
      Button("Open in New Tab", () => run("agent.openSessionTab", { session: c().id })),
      Button(isUnread(c()) ? "Mark as read" : "Mark as unread", () => (isUnread(c()) ? mark("read", [c().id]) : unmark("read", c().id))),
      Divider(),
      Button("Archive chat", () => {
        mark("archived", [c().id])
        cmux.toast({ title: "Archived 1 chat", message: title(c()) })
      })
    ])

// An archived row: the title, and Unarchive at the right.
const archivedRow = (c) =>
  row(c, (item) =>
    Button(Icon("arrow.uturn.backward"), () => unmark("archived", item().id)).help(`Unarchive ${title(item())}`)
  ).contextMenu(() => [Button(`Unarchive ${title(c())}`, () => unmark("archived", c().id))])

function heading(text, trailing) {
  return HStack({ spacing: 6 }, [Text(text).font(TEXT).weight("medium").color(cmux.theme.text.secondary), Spacer(), ...(trailing || [])])
    .paddingHorizontal(10)
    .frame({ height: ROW_HEIGHT })
}

const link = (text, onTap) => Text(text).font("caption").color(cmux.theme.text.secondary).cursor("pointer").onTap(onTap)

function activity() {
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 8 }, [
      Icon("bell").size(TEXT),
      Text("Activity").font(TEXT).weight("medium"),
      Spacer(),
      Menu("Options", () => [
        Button("Mark all as read", () => mark("read", chats().filter(isUnread).map((c) => c.id))),
        Button("Clear read chats", () => mark("cleared", live().filter(isRead).map((c) => c.id))),
        Divider(),
        Button("Archive", () => setView("archive"))
      ])
    ])
      .paddingHorizontal(10)
      .frame({ height: ROW_HEIGHT }),
    () =>
      priority().length
        ? VStack({ spacing: 0 }, [
            heading("Priority", [link("Mark all as read", () => mark("read", chats().filter(isUnread).map((c) => c.id)))]),
            ForEach({ items: priority, key: (c) => c.id }, activityRow)
          ])
        : null,
    ForEach({ items: days, key: (g) => g.name }, (g) =>
      VStack({ spacing: 0 }, [
        heading(g().name, [
          g().name === "Today" && recent().some(isRead) ? link("Clear read chats", () => mark("cleared", live().filter(isRead).map((c) => c.id))) : null
        ]),
        ForEach({ items: () => g().threads, key: (c) => c.id }, activityRow)
      ])
    ),
    () => {
      if (!loaded()) return Text("Checking unread chats…").font(TEXT).color(cmux.theme.text.secondary).paddingHorizontal(10)
      if (!priority().length && !days().length)
        return EmptyState({ title: "Nothing needs attention", message: "Chats that need input, or that you have not read, show up here.", symbol: "bell" })
      return null
    }
  ])
}

function archive() {
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 8 }, [
      Button(HStack({ spacing: 4 }, [Icon("chevron.left"), Text("Back to sidebar")]), () => setView("activity")),
      Spacer(),
      Text("Archive").font(TEXT).weight("medium")
    ])
      .paddingHorizontal(10)
      .frame({ height: ROW_HEIGHT }),
    TextField(query, { placeholder: "Search archived chats", onEdit: setQuery }).font(TEXT).paddingHorizontal(10),
    ForEach({ items: archived, key: (c) => c.id }, archivedRow),
    () => {
      if (!loaded()) return Text("Loading archived chats…").font(TEXT).color(cmux.theme.text.secondary).paddingHorizontal(10)
      if (archivedCount() === 0) return EmptyState({ title: "No archived chats", symbol: "archivebox" })
      if (archived().length === 0) return EmptyState({ title: "No matching archived chats", symbol: "magnifyingglass" })
      return null
    }
  ])
}

function renderThreads() {
  follow()
  return VStack({ spacing: 0 }, [() => (view() === "archive" ? archive() : activity())])
}

globalThis.__cmuxAppExports = { renderThreads }
