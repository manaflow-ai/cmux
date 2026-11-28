// A chat sidebar after a desktop coding agent app. Public surfaces only: cmux.section/1 (the list),
// cmux.hovercard/1 (the thread card) and cmux.sidebar.rows/1 (row decorations).
// Numbers are the reference's: rows 36 high, 10 round, inset 6, 10 inside, 14 pt text, a 16 wide
// status slot at the left, the age at the right. One chat read per change; nothing polls.

const ROW_HEIGHT = 36
const ROW_RADIUS = 10
const ROW_INSET = 6
const ROW_PAD = 10
const TEXT = 14
const SHOW_FIRST = 10 // chats shown before "Show more"

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [prefs, setPrefs] = signal({ sort: "updated", organize: "project", pinned: [], archived: [], collapsed: {}, expanded: {} })

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

function savePrefs(patch) {
  const next = { ...prefs(), ...patch }
  setPrefs(next)
  cmux.storage.set("sidebar.prefs", next).catch(() => {})
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
  cmux.storage.get("sidebar.prefs").then((saved) => saved && setPrefs({ ...prefs(), ...saved })).catch(() => {})
  loadChats()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("workspace.changed", loadChats)
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const updatedAt = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const stamp = (c) => (prefs().sort === "created" ? c.created_ms || 0 : updatedAt(c))
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()
const isPinned = (c) => prefs().pinned.includes(c.id)
const isArchived = (c) => prefs().archived.includes(c.id)

// "now", "7m", "2h", "3d": the compact age at the right of a row.
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const visible = computed(() => chats().filter((c) => !isArchived(c)).sort((a, b) => stamp(b) - stamp(a)))
const pinned = computed(() => visible().filter(isPinned))
const unpinned = computed(() => visible().filter((c) => !isPinned(c)))
const projects = computed(() => {
  const groups = new Map()
  for (const c of unpinned()) {
    const name = c.project || "No project"
    if (!groups.has(name)) groups.set(name, { name, threads: [] })
    groups.get(name).threads.push(c)
  }
  return [...groups.values()]
})

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function togglePin(chat) {
  const list = prefs().pinned
  savePrefs({ pinned: list.includes(chat.id) ? list.filter((id) => id !== chat.id) : [...list, chat.id] })
}

function archive(chat) {
  savePrefs({ archived: [...prefs().archived, chat.id], pinned: prefs().pinned.filter((id) => id !== chat.id) })
  cmux.toast({ title: "Archived 1 chat", message: chat.title })
}

// The status slot: a spinner while it works, a question mark when it waits on you, a dot when its
// answer is unread; otherwise empty, 16 wide so titles line up.
function mark(c) {
  return HStack({ spacing: 0 }, [
    () =>
      c().state === "working"
        ? ProgressView().frame({ width: 12, height: 12 })
        : c().state === "input"
          ? Icon("questionmark.circle").size(13).color(cmux.theme.warning)
          : c().unread
            ? Icon("circle.fill").size(8).color(cmux.theme.accent)
            : null
  ]).frame({ width: 16, height: 16 })
}

function thread(c) {
  return HStack({ spacing: 8 }, [
    mark(c),
    Text(() => c().title).font(TEXT).weight(() => (c().unread && c().state !== "working" ? "medium" : "regular")).lineLimit(1),
    Spacer(),
    Text(() => age(stamp(c()))).font(TEXT).color(cmux.theme.text.tertiary).monospaced().fixedSize("horizontal")
  ])
    .paddingHorizontal(ROW_PAD)
    .frame({ height: ROW_HEIGHT })
    .cornerRadius(ROW_RADIUS)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground(() => (isOpen(c()) ? "selected" : "hover"))
    .help(() => [c().title, c().cwd, c().step].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(() => [
      Button(isPinned(c()) ? "Unpin chat" : "Pin chat", () => togglePin(c())),
      Button("Open in New Tab", () => run("agent.openSessionTab", { session: c().id })),
      Divider(),
      Button("Archive chat", () => archive(c()))
    ])
}

function heading(title, trailing) {
  return HStack({ spacing: 6 }, [Text(title).font(TEXT).weight("medium").color(cmux.theme.text.secondary), Spacer(), ...(trailing || [])])
    .paddingHorizontal(ROW_PAD)
    .frame({ height: ROW_HEIGHT })
}

// A list cut to its first SHOW_FIRST chats with "Show more" and "Show less" at its tail.
function limited(key, items) {
  const open = () => !!prefs().expanded[key]
  return VStack({ spacing: 0 }, [
    ForEach({ items: () => (open() ? items() : items().slice(0, SHOW_FIRST)), key: (c) => c.id }, thread),
    () =>
      items().length > SHOW_FIRST
        ? Text(open() ? "Show less" : "Show more")
            .font(TEXT)
            .color(cmux.theme.text.secondary)
            .paddingHorizontal(ROW_PAD)
            .frame({ height: ROW_HEIGHT })
            .cursor("pointer")
            .onTap(() => savePrefs({ expanded: { ...prefs().expanded, [key]: !open() } }))
        : null
  ])
}

const organizeMenu = () =>
  Menu("Organize", () => [
    Button("By project", () => savePrefs({ organize: "project" })).withProps({ symbol: prefs().organize === "project" ? "checkmark" : null }),
    Button("In one list", () => savePrefs({ organize: "list" })).withProps({ symbol: prefs().organize === "list" ? "checkmark" : null }),
    Divider(),
    Button("Created", () => savePrefs({ sort: "created" })).withProps({ symbol: prefs().sort === "created" ? "checkmark" : null }),
    Button("Last updated", () => savePrefs({ sort: "updated" })).withProps({ symbol: prefs().sort === "updated" ? "checkmark" : null })
  ])

function renderChats() {
  follow()
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 8 }, [
      Icon("square.and.pencil").size(TEXT),
      Text("New chat").font(TEXT),
      Spacer(),
      Button(Icon("magnifyingglass"), () => run("agentPane.searchChats")),
      organizeMenu()
    ])
      .paddingHorizontal(ROW_PAD)
      .frame({ height: ROW_HEIGHT })
      .cornerRadius(ROW_RADIUS)
      .hoverBackground("hover")
      .cursor("pointer")
      .onTap(() => run("palette.newAgentChat", {})),
    () =>
      pinned().length
        ? VStack({ spacing: 0 }, [heading("Pinned"), ForEach({ items: pinned, key: (c) => c.id }, thread)])
        : null,
    () =>
      prefs().organize === "list"
        ? VStack({ spacing: 0 }, [heading("Chats"), limited("list", unpinned)])
        : VStack({ spacing: 0 }, [
            heading("Projects"),
            ForEach({ items: projects, key: (p) => p.name }, (p) =>
              VStack({ spacing: 0 }, [
                HStack({ spacing: 8 }, [
                  Icon("folder").size(TEXT).color(cmux.theme.text.secondary),
                  Text(() => p().name).font(TEXT).lineLimit(1),
                  Spacer()
                ])
                  .paddingHorizontal(ROW_PAD)
                  .frame({ height: ROW_HEIGHT })
                  .cornerRadius(ROW_RADIUS)
                  .hoverBackground("hover")
                  .cursor("pointer")
                  .onTap(() => savePrefs({ collapsed: { ...prefs().collapsed, [p().name]: !prefs().collapsed[p().name] } })),
                () => (prefs().collapsed[p().name] ? null : limited(`project:${p().name}`, () => p().threads))
              ])
            )
          ]),
    () => (visible().length ? null : Text("No chats").font(TEXT).color(cmux.theme.text.secondary).paddingHorizontal(ROW_PAD).frame({ height: ROW_HEIGHT }))
  ]).paddingHorizontal(ROW_INSET)
}

// The thread hover card: the title, then what kind of chat it is and where it works.
const PLACES = ["machine", "folder", "branch"]
const ICONS = { machine: "laptopcomputer", folder: "folder", branch: "arrow.triangle.branch" }

function renderCard(ctx) {
  const card = ctx.card
  const needs = card.facts.find((fact) => fact.kind === "needsInput")
  const places = PLACES.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  return VStack({ spacing: 6, alignment: "leading" }, [
    HStack({ spacing: 8 }, [
      Text(card.title).weight("medium").lineLimit(1),
      Spacer(),
      Text(card.age ?? "").font("caption").color(cmux.theme.text.secondary)
    ]),
    needs ? Text(needs.text).color(cmux.theme.warning).lineLimit(2) : null,
    ...places.map((fact) =>
      HStack({ spacing: 8 }, [Icon(ICONS[fact.kind] ?? "circle").color(cmux.theme.text.secondary), Text(fact.text).lineLimit(1)])
    ),
    card.status ? Text(card.status).font("caption").color(cmux.theme.text.secondary) : null
  ])
}

// Native rows (workspaces): regular weight and the spinner as a plain dot-free mark.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "arc" }, [])
    )
  ])
}

globalThis.__cmuxAppExports = { renderChats, renderCard, decorateRows }
