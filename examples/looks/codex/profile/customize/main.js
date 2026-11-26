// The whole codex-app profile's sidebar and New Tab page in one customize app: a look carries one
// customize app (local/customize), so this joins the two feature looks it is built from.
// - codex/sidebar: the Chats section, the thread hover card and the row decorations.
// - codex/send-parity: the builder New Tab page.
// Each part is that look's main.js, unchanged, in its own scope.
// codex/threads' Activity section is not here: an app implements cmux.section/1 once, so the profile
// keeps the Chats section and turns on cmux's own priority view for Activity (see README.md, Gaps).
const __sidebar = (() => {
// A chat sidebar after a desktop coding agent app. Public surfaces only: cmux.section/1 (the list),
// cmux.hovercard/1 (the thread card) and cmux.sidebar.rows/1 (row decorations).
// Numbers are the reference's: rows 36 high, 10 round, inset 6, 10 inside, 14 pt text, a 16 wide
// status slot at the left, the age at the right. Chats come from the live chat.list signal (with
// archived ones, so a chat you archive drops out at once); nothing polls. Pin and Archive are the
// host's chat.pin and chat.archive. Only the sort, organize, collapsed and expanded choices are
// kept in this app's storage.

const ROW_HEIGHT = 36
const ROW_RADIUS = 10
const ROW_INSET = 6
const ROW_PAD = 10
const TEXT = 14
const SHOW_FIRST = 10 // chats shown before "Show more"

const [source, setSource] = signal(null)
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [prefs, setPrefs] = signal({ sort: "updated", organize: "project", collapsed: {}, expanded: {} })

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for this view`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

// The live chat.list read, once per section render.
const chats = computed(() => (source() && source()()) || [])

function savePrefs(patch) {
  const next = { ...prefs(), ...patch }
  setPrefs(next)
  cmux.storage.set("sidebar.prefs", next).catch(() => {})
}

// Only the open workspace is read by hand; the chat list is live.
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
    cmux.storage.get("sidebar.prefs").then((saved) => saved && setPrefs({ ...prefs(), ...saved })).catch(() => {})
  }
  loadWorkspace()
  cmux.events.on("workspace.changed", loadWorkspace)
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

// A machine and its peer can each list a chat with the same id.
const chatKey = (c) => JSON.stringify([c.machine || "", c.id])
const num = (v) => Number(v) || 0

const updatedAt = (c) => Math.max(num(c.updated_ms), num(c.since_ms), num(c.created_ms))
const stamp = (c) => (prefs().sort === "created" ? num(c.created_ms) : updatedAt(c))
const isOpen = (c) => !c.machine && c.workspace != null && c.workspace === openWorkspace()
const isPinned = (c) => Boolean(c.pinned)
const isArchived = (c) => Boolean(c.archived)

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
  // A peer chat's workspace id is that machine's, not ours: open it as a tab instead.
  if (chat.workspace && !chat.machine) cmux.workspace.focus({ workspace: chat.workspace }).then(loadWorkspace, refused("Change workspaces"))
  else run("agent.openSessionTab", session(chat))
}

const session = (c) => ({ session: c.id, ...(c.machine ? { host: c.machine } : {}) })
const target = (c) => ({ chat: c.id, ...(c.machine ? { machine: c.machine } : {}) })
const failed = (what) => (e) => cmux.toast({ title: `Could not ${what}`, message: message(e), tone: "warning" })

function togglePin(chat) {
  cmux.call("chat.pin", { ...target(chat), pinned: !isPinned(chat) }).catch(failed(isPinned(chat) ? "unpin the chat" : "pin the chat"))
}

function archive(chat) {
  const call = { targets: [{ chat: chat.id, peer: chat.machine || null }], archived: true }
  cmux.call("chat.archive", call).then(
    (results) => {
      const bad = (results || []).find((r) => r.error != null)
      if (bad) failed("archive the chat")(bad.error)
      else cmux.toast({ title: "Archived 1 chat", message: chat.title })
    },
    failed("archive the chat")
  )
}

// The status slot: a spinner while it works, a question mark when it waits on you, a warning
// triangle when it failed or was lost, a dot when its answer is unread; otherwise empty, 16 wide so titles line up.
function mark(c) {
  return HStack({ spacing: 0 }, [
    () =>
      c().state === "working"
        ? ProgressView().frame({ width: 12, height: 12 })
        : c().state === "input"
          ? Icon("questionmark.circle").size(13).color(cmux.theme.warning)
          : c().state === "failed" || c().state === "lost"
            ? Icon("exclamationmark.triangle").size(13).color(cmux.theme.warning)
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
    .help(() => [c().title, c().cwd, c().step, c().state === "failed" || c().state === "lost" ? c().error : null].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(() => [
      Button(isPinned(c()) ? "Unpin chat" : "Pin chat", () => togglePin(c())),
      Button("Open in New Tab", () => run("agent.openSessionTab", session(c()))),
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
    ForEach({ items: () => (open() ? items() : items().slice(0, SHOW_FIRST)), key: chatKey }, thread),
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
        ? VStack({ spacing: 0 }, [heading("Pinned"), ForEach({ items: pinned, key: chatKey }, thread)])
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
    () => (source() && source().error() ? Text(source().error().message).font(TEXT).color(cmux.theme.warning).paddingHorizontal(ROW_PAD) : null),
    () => (visible().length || (source() && source().error()) ? null : Text("No chats").font(TEXT).color(cmux.theme.text.secondary).paddingHorizontal(ROW_PAD).frame({ height: ROW_HEIGHT }))
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

return { renderChats, renderCard, decorateRows }
})()

const __builder = (() => {
// The builder new-chat page, as a New Tab page you opt into (cmux.newtab/1, tabs.newTabApp).
// One quiet line centered in the page, "What should we build in {project}?", with the project's
// name a picker, and "What should we build?" with a folder picker under it when the tab has no
// folder. Under the line, only when there are any, the chats that wait on you. The field sits at
// the foot of the page: a prompt starts a chat in this tab's folder, `!cmd` a terminal, an address
// a browser (newTab.submit, as cmux's own field).
//
// Not the chat itself: cmux's new chat stays plain. This page is here because someone installed
// it (Leo, 2026-11-22: "if we want it as a proper option then we shouldnt have things be in
// disparate places").
//
// The project pick: newTab.submit takes no folder, and a page cannot move its own tab's folder, so
// a pick starts a new chat in the picked folder (palette.newAgentChat with cwd) instead of moving
// this page's prompt there. README.md lists what is missing.

const [source, setSource] = signal(null)
const [draft, setDraft] = signal("")
const [cwd, setCwd] = signal(null)

const chats = computed(() => (source() && source()()) || [])
const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Reference send`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

const trimmed = (path) => String(path || "").replace(/\/+$/, "")
const folderName = (path) => trimmed(path).split("/").pop() || path
const changed = (c) => Math.max(Number(c.updated_ms) || 0, Number(c.since_ms) || 0, Number(c.created_ms) || 0)
const chatKey = (c) => JSON.stringify([c.machine || "", c.id])

// The folders your chats ran in, newest first, one row each, at most eight; this tab's own first.
const projects = computed(() => {
  const seen = new Set()
  const here = trimmed(cwd())
  const out = []
  for (const c of [...chats()].sort((a, b) => changed(b) - changed(a))) {
    const path = trimmed(c.cwd)
    const key = JSON.stringify([c.machine || "", path])
    if (!path || path === here || seen.has(key)) continue
    seen.add(key)
    out.push({ path, machine: c.machine || null })
  }
  return out.slice(0, 8)
})

// HomeLists' inbox: the chats that ask something of you.
const waiting = computed(() =>
  chats()
    .filter((c) => !c.archived && (c.state === "input" || c.state === "failed" || c.state === "lost"))
    .sort((a, b) => changed(b) - changed(a))
    .slice(0, 5)
)

function pick(project) {
  run("palette.newAgentChat", { cwd: project.path, ...(project.machine ? { host: project.machine } : {}) })
}

const pickerItems = () => [
  ...projects().map((p) => Button(p.machine ? `${folderName(p.path)} (${p.machine})` : folderName(p.path), () => pick(p))),
  projects().length ? Divider() : null,
  Button("Open Folder…", () => run("openFolder"))
].filter(Boolean)

// Runs inside Return, so the action gets that gesture.
function send(text) {
  const prompt = String(text ?? draft()).trim()
  if (!prompt) return
  cmux.actions.run("newTab.submit", { text: prompt }).then(() => setDraft(""), refused("Run actions"))
}

function open(chat) {
  if (chat.workspace && !chat.machine) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
}

const TITLE = 20

function question() {
  const here = cwd()
  if (here)
    return HStack({ spacing: 0 }, [
      Text("What should we build in ").font(TITLE),
      Menu(folderName(here), pickerItems).font(TITLE).help(here),
      Text("?").font(TITLE)
    ])
  return VStack({ spacing: 14 }, [
    Text("What should we build?").font(TITLE),
    Menu("Choose a folder", pickerItems).secondary()
  ])
}

const waitingRow = (chat) =>
  Row({
    title: () => chat().title || "Untitled chat",
    subtitle: () => [chat().state === "input" ? "Waiting for you" : "Failed", chat().project].filter(Boolean).join(" · "),
    symbol: () => (chat().state === "input" ? "questionmark.bubble" : "exclamationmark.circle"),
    tint: () => (chat().state === "input" ? cmux.theme.warning : cmux.theme.danger)
  }).onTap(() => open(chat()))

function renderBuilder(context) {
  setCwd((context && context.cwd) || null)
  const live = cmux.live("chat.list", {})
  setSource(() => live) // a function: passing the live itself would run it as an updater
  return VStack({ spacing: 14 }, [
    Spacer(),
    question(),
    Spacer(),
    () =>
      waiting().length
        ? Panel({ title: "Needs you", style: "card" }, [ForEach({ items: waiting, key: chatKey }, waitingRow)]).frame({ maxWidth: 760 })
        : null,
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask anything", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") })
    ]).frame({ maxWidth: 760 })
  ]).padding(24)
}

return { renderBuilder }
})()

globalThis.__cmuxAppExports = { ...__sidebar, ...__builder }
