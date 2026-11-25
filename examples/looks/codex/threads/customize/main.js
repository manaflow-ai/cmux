// Activity and Archive views of your agent chats, after a desktop coding agent app's. One sidebar
// section (cmux.section/1) with two views you flip between: Activity (Priority first, then Today,
// Yesterday and older days; Mark all as read; Clear read chats) and Archive (search, Unarchive).
// Chats come from the live chat.list signal, with archived ones. Mark as read is the host's
// chat.mark_read, and Archive and Unarchive are its chat.archive. The host has no op to hide a read
// chat or to mark one unread, so "Clear read chats" is an app-local mark in this app's storage,
// keyed to a chat's last change: a chat that moves again comes back. There is no Mark as unread.

const ROW_HEIGHT = 36
const ROW_RADIUS = 10
const TEXT = 14

const [source, setSource] = signal(null)
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [view, setView] = signal("activity") // "activity" | "archive"
const [query, setQuery] = signal("")
// Chat key -> the chat's last change when you cleared it from Activity.
const [cleared, setCleared] = signal({})

// The live chat.list read, once per section render.
const chats = computed(() => (source() && source()()) || [])
const loaded = () => Boolean(source()) && !source().loading()

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

// A machine and its peer can each list a chat with the same id.
const chatKey = (c) => JSON.stringify([c.machine || "", c.id])
const num = (v) => Number(v) || 0
const failed = (what) => (e) => cmux.toast({ title: `Could not ${what}`, message: message(e), tone: "warning" })

function clear(items) {
  const at = Object.fromEntries(items.map((c) => [chatKey(c), changed(c)]))
  const next = { ...cleared(), ...at }
  setCleared(next)
  cmux.storage.set("threads.marks", { cleared: next }).catch(() => {})
}

// Mark chats read in the host. One refused chat does not stop the rest.
async function markRead(items) {
  const results = await Promise.allSettled(
    items.map((c) => cmux.call("chat.mark_read", { chat: c.id, ...(c.machine ? { machine: c.machine } : {}) }))
  )
  const bad = results.find((r) => r.status === "rejected")
  if (bad) failed(items.length > 1 ? "mark all as read" : "mark the chat as read")(bad.reason)
}

async function setArchived(items, value) {
  if (!items.length) return
  try {
    const results = await cmux.call("chat.archive", {
      targets: items.map((c) => ({ chat: c.id, peer: c.machine || null })),
      archived: value
    })
    const bad = (results || []).find((r) => r.error != null)
    if (bad) failed(value ? "archive the chat" : "unarchive the chat")(bad.error)
    else if (value) cmux.toast({ title: `Archived ${items.length} chat${items.length === 1 ? "" : "s"}`, message: title(items[0]) })
  } catch (e) {
    failed(value ? "archive the chat" : "unarchive the chat")(e)
  }
}

let reading = false
let again = false
async function loadWorkspace() {
  if (reading) return void (again = true)
  reading = true
  try {
    const workspaces = await cmux.workspace.list({}).catch(() => [])
    setOpenWorkspace((workspaces.find((w) => w.focused) || {}).id || null)
    setNow(Date.now())
  } finally {
    reading = false
    if (again) {
      again = false
      loadWorkspace()
    }
  }
}

// Every mount subscribes for itself: cmux.live, events.on and timer.every end with the mount that
// made them, so a section that remounts (a second window, a re-render) keeps updating. The newest
// mounted live feeds the view; stored choices load once.
const lives = []
let stored = false
function follow() {
  const live = cmux.live("chat.list", { include_archived: true })
  lives.push(live)
  setSource(() => live) // a function: passing the live itself would run it as an updater
  onCleanup(() => {
    lives.splice(lives.indexOf(live), 1)
    if (source.peek() === live) setSource(() => lives[lives.length - 1] || null)
  })
  if (!stored) {
    stored = true
    cmux.storage.get("threads.marks").then((saved) => saved && saved.cleared && setCleared(saved.cleared)).catch(() => {})
  }
  loadWorkspace()
  cmux.events.on("workspace.changed", loadWorkspace)
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const changed = (c) => Math.max(num(c.updated_ms), num(c.since_ms), num(c.created_ms))
// A cleared mark holds only while the chat has not moved since.
const isCleared = (c) => cleared()[chatKey(c)] !== undefined && cleared()[chatKey(c)] >= changed(c)
const isArchived = (c) => Boolean(c.archived)
const needsYou = (c) => c.state === "input"
const hasFailed = (c) => c.state === "failed" || c.state === "lost"
const isUnread = (c) => Boolean(c.unread)
const isRead = (c) => !needsYou(c) && c.state !== "working" && !isUnread(c)
const title = (c) => (c.title && c.title.trim()) || "Untitled chat"
const isOpen = (c) => !c.machine && c.workspace != null && c.workspace === openWorkspace()

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
    .filter((c) => !priority().includes(c) && !isCleared(c))
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
const unread = computed(() => live().filter(isUnread))

const session = (c) => ({ session: c.id, ...(c.machine ? { host: c.machine } : {}) })

function show(chat) {
  if (isUnread(chat)) markRead([chat])
  // A peer chat's workspace id is that machine's, not ours: open it as a tab instead.
  if (chat.workspace && !chat.machine) cmux.workspace.focus({ workspace: chat.workspace }).then(loadWorkspace, refused("Change workspaces"))
  else run("agent.openSessionTab", session(chat))
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
          : hasFailed(c())
            ? Icon("exclamationmark.triangle").size(13).color(cmux.theme.warning)
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
    .help(() => [title(c()), c().cwd, c().step, hasFailed(c()) ? c().error : null].filter(Boolean).join("\n"))
    .cursor("pointer")
}

const activityRow = (c) =>
  row(c, (item) => Text(() => age(changed(item()))).font(TEXT).color(cmux.theme.text.tertiary).monospaced().fixedSize("horizontal"))
    .onTap(() => show(c()))
    .contextMenu(() => [
      Button("Open in New Tab", () => run("agent.openSessionTab", session(c()))),
      ...(isUnread(c()) ? [Button("Mark as read", () => markRead([c()]))] : []),
      Divider(),
      Button("Archive chat", () => setArchived([c()], true))
    ])

// An archived row: the title, and Unarchive at the right.
const archivedRow = (c) =>
  row(c, (item) =>
    Button(Icon("arrow.uturn.backward"), () => setArchived([item()], false)).help(`Unarchive ${title(item())}`)
  ).contextMenu(() => [Button(`Unarchive ${title(c())}`, () => setArchived([c()], false))])

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
        Button("Mark all as read", () => markRead(unread())),
        Button("Clear read chats", () => clear(live().filter(isRead))),
        Divider(),
        Button("Archive", () => setView("archive"))
      ])
    ])
      .paddingHorizontal(10)
      .frame({ height: ROW_HEIGHT }),
    () =>
      priority().length
        ? VStack({ spacing: 0 }, [
            heading("Priority", [link("Mark all as read", () => markRead(unread()))]),
            ForEach({ items: priority, key: chatKey }, activityRow)
          ])
        : null,
    ForEach({ items: days, key: (g) => g.name }, (g) =>
      VStack({ spacing: 0 }, [
        heading(g().name, [
          () => (g().name === "Today" && recent().some(isRead) ? link("Clear read chats", () => clear(live().filter(isRead))) : null)
        ]),
        ForEach({ items: () => g().threads, key: chatKey }, activityRow)
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
    ForEach({ items: archived, key: chatKey }, archivedRow),
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
