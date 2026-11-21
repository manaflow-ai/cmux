// Console: a New Tab page with a monospace field behind a `>` on top, then Recently Closed, then every chat as a quiet
// list of lines (Chats or Projects, a filter and a search). Built only from public surfaces: the
// cmux.newtab/1 interface, the scene kit, agent_chat.list, closed.list and actions.
//
// Reads with agent_chat:read and closed:read (granted at install). Starting a chat, opening one and
// reopening a closed tab need actions:run and closed:write: turn them on in Settings > Apps.

// The threads look sets this to false: no `>`, and the system font. Here: a `>` before the field and monospaced type throughout.
const CONSOLE = true

const MINUTE = 60 * 1000
// Recently Closed shows the newest five, as cmux's own page does.
const CLOSED_SHOWN = 5
// The list draws in pages of this many rows; the next page draws when the person asks for it.
const PAGE = 60

const [chats, setChats] = signal([])
const [closed, setClosed] = signal([])
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")
const [query, setQuery] = signal("")
const [view, setView] = signal("chats")
const [filter, setFilter] = signal("all")
const [shown, setShown] = signal(PAGE)
const [folded, setFolded] = signal({})
const [error, setError] = signal(null)
const [ready, setReady] = signal(false)

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Console`, message: message(e), tone: "warning" })
const mono = (node) => (CONSOLE ? node.monospaced() : node)

// One read at a time; a change during a read reads once more after it.
function reader(read) {
  let reading = false
  let again = false
  const run = async () => {
    if (reading) return void (again = true)
    reading = true
    try {
      await read()
    } finally {
      reading = false
      if (again) {
        again = false
        run()
      }
    }
  }
  return run
}

const loadChats = reader(async () => {
  try {
    setChats((await cmux.call("agent_chat.list", {})).chats)
    setError(null)
  } catch (e) {
    setError(message(e))
  }
  setReady(true)
  setNow(Date.now())
})

const loadClosed = reader(async () => {
  try {
    setClosed(await cmux.call("closed.list", { limit: CLOSED_SHOWN }))
  } catch {
    setClosed([])
  }
})

// "now", "4m", "2h", "3d", "5w": the age column, right-aligned.
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  if (s < 86400 * 14) return `${Math.floor(s / 86400)}d`
  return `${Math.floor(s / (86400 * 7))}w`
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const needsInput = (c) => c.state === "input"
const failed = (c) => c.state === "failed" || c.state === "lost"
const working = (c) => c.state === "working"
const done = (c) => !working(c) && !needsInput(c) && !failed(c)
// Live: running, asking, failed or unread, as cmux's own list leads with them.
const live = (c) => !done(c) || Boolean(c.unread)
// Asking or failed first, then running, then unread, then the rest.
const rank = (c) => (needsInput(c) || failed(c) ? 0 : working(c) ? 1 : c.unread ? 2 : 3)
const folder = (path) => (path ? path.replace(/\/+$/, "").split("/").pop() : "")
const projectOf = (c) => c.project || folder(c.cwd) || "No folder"

const FILTERS = [
  { id: "all", title: "All", keep: () => true },
  { id: "working", title: "Working", keep: working },
  { id: "input", title: "Needs input", keep: needsInput },
  { id: "done", title: "Done", keep: done },
]

// The state word a row shows in place of its age, in its tone; null shows the age.
function stateOf(c) {
  if (needsInput(c)) return { text: "Needs input", tone: "warning" }
  if (failed(c)) return { text: "Failed", tone: "danger" }
  if (working(c)) return { text: "Running", tone: "secondary" }
  if (c.unread) return { text: "Unread", tone: "secondary" }
  return null
}

// Every chat that passes the filter and the search: the live ones (asking, failed, running, unread) lead,
// as on cmux's own page, then the rest, newest first. The read returns every chat in no order, so
// the page sorts them here (GAPS: a sorted, paged read in the daemon).
const listed = computed(() => {
  const keep = (FILTERS.find((f) => f.id === filter()) || FILTERS[0]).keep
  const q = query().trim().toLowerCase()
  return chats()
    .filter((c) => !c.parent && keep(c))
    .filter((c) => !q || `${c.title} ${projectOf(c)}`.toLowerCase().includes(q))
    .sort((a, b) => rank(a) - rank(b) || lastActivity(b) - lastActivity(a))
})

const projects = computed(() => {
  const groups = new Map()
  for (const c of listed()) {
    const name = projectOf(c)
    if (!groups.has(name)) groups.set(name, [])
    groups.get(name).push(c)
  }
  return [...groups].map(([name, rows]) => ({ id: name, name, rows }))
})

function openChat(c) {
  cmux.actions.run("agent.openSessionTab", { session: c.id }).catch(refused("Run actions"))
}

function reopen(item) {
  cmux.call("closed.reopen", { closed: item.id }).then(loadClosed, refused("Reopen closed tabs"))
}

// Return in the field: a prompt starts a chat, an address opens a browser, `!cmd` a terminal, as
// cmux's own field does (newTab.submit).
function submit(text) {
  const typed = (text ?? draft()).trim()
  if (!typed) return
  cmux.actions.run("newTab.submit", { text: typed }).then(() => setDraft(""), refused("Run actions"))
}

// The field: one rounded box, the folder the chat starts in over it, Send at its end.
function field(context) {
  const where = folder(context?.cwd)
  return VStack({ spacing: 6 }, [
    where
      ? HStack({ spacing: 4 }, [Icon("folder").size(11).color("tertiary"), mono(Text(where).font("caption").color("secondary"))]).paddingHorizontal(14)
      : null,
    HStack({ spacing: 8 }, [
      CONSOLE ? Text(">").monospaced().weight("medium").color("secondary") : null,
      mono(
        TextField(draft, {
          placeholder: CONSOLE ? "Ask, open an address, or !run a command" : "Ask anything, or type an address",
          autofocus: true,
          onEdit: setDraft,
          onSubmit: submit,
          onCancel: () => setDraft(""),
        }).font(14)
      )
        // The web scene gives a TextField no share of its row (GAPS), so a wide frame that the row
        // shrinks to fit stands in for a field that fills it.
        .frame({ width: 2000 })
        .layoutPriority(1),
      Button(Icon("composer.send").size(12).color(() => (draft().trim() ? "primary" : "tertiary")), () => submit())
        .help("Send")
        .disabled(() => !draft().trim()),
    ])
      .paddingHorizontal(18)
      .frame({ minHeight: CONSOLE ? 44 : 52 })
      .cornerRadius(CONSOLE ? 8 : 16)
      .background("hover")
      .borderColor("separator")
      .borderWidth(0.5),
  ])
}

const head = (title) => mono(Text(title).font("caption").weight("medium").color("secondary")).paddingHorizontal(10).frame({ height: 30 })

// cmux icon pack names (the scene passes them through); closed.list names a kind only, not what a tab showed.
const KIND_SYMBOL = { tab: "app.generic", screen: "app.generic", workspace: "workspace", window: "app.generic" }

function closedSection() {
  return () =>
    closed().length
      ? VStack({ spacing: 0 }, [
          head("Recently Closed"),
          ForEach({ items: closed, key: (item) => item.id }, (item) =>
            HStack({ spacing: 8 }, [
              Icon(() => KIND_SYMBOL[item().kind] || "app.generic").size(12).color("tertiary"),
              mono(Text(() => item().name || "Untitled").font(13).lineLimit(1)),
              Spacer(),
              mono(Text(() => age(Number(item().closed_at_ms))).font("caption").color("tertiary")).fixedSize("horizontal"),
            ])
              .paddingHorizontal(10)
              .frame({ height: 28 })
              .cornerRadius(6)
              .hoverBackground("hover")
              .cursor("pointer")
              .help("Reopen")
              .onTap(() => reopen(item()))
              .contextMenu([Button("Reopen", () => reopen(item()))])
          ),
        ])
      : null
}

// A chat as one line: a glyph, the title, its project, then its state or age.
function chatLine(c, withProject = true) {
  const state = () => stateOf(c())
  return HStack({ spacing: 8 }, [
    Icon(() => (working(c()) ? "status.running" : needsInput(c()) ? "status.needsinput" : failed(c()) ? "status.failure" : c().unread ? "unread.dot" : "agent.chat"))
      .size(12)
      .color(() => (state() ? state().tone : "tertiary")),
    // Live chats in full color; the rest quieter, as cmux's own list draws them.
    mono(
      Text(() => c().title || "Untitled chat")
        .font(13)
        .weight(() => (c().unread ? "medium" : "regular"))
        .color(() => (live(c()) ? "primary" : "secondary"))
        .lineLimit(1)
    ).layoutPriority(1),
    withProject ? mono(Text(() => projectOf(c())).font("caption").color("tertiary").lineLimit(1)) : null,
    Spacer(),
    () => {
      const s = state()
      return s
        ? mono(Text(s.text).font("caption").color(s.tone)).fixedSize("horizontal")
        : mono(Text(() => age(lastActivity(c()))).font("caption").color("tertiary")).fixedSize("horizontal")
    },
  ])
    .paddingHorizontal(10)
    .frame({ height: 30 })
    .cornerRadius(6)
    .hoverBackground("hover")
    .cursor("pointer")
    .help(() => [c().title, c().cwd, c().harness].filter(Boolean).join("\n"))
    .onTap(() => openChat(c()))
    .contextMenu([Button("Open Chat", () => openChat(c()))])
}

function tab(id, title) {
  return mono(Text(title).font(13).weight(() => (view() === id ? "semibold" : "medium")).color(() => (view() === id ? "primary" : "secondary")))
    .paddingHorizontal(6)
    .frame({ height: 24 })
    .cursor("pointer")
    .onTap(() => {
      setView(id)
      setShown(PAGE)
    })
}

function chatsHeader() {
  return HStack({ spacing: 4 }, [
    tab("chats", "Chats"),
    tab("projects", "Projects"),
    Menu(() => (filter() === "all" ? "All" : (FILTERS.find((f) => f.id === filter()) || FILTERS[0]).title), FILTERS.map((f) => Button(f.title, () => {
      setFilter(f.id)
      setShown(PAGE)
    }))),
    Spacer(),
    HStack({ spacing: 4 }, [
      Icon("search").size(11).color("tertiary"),
      mono(TextField(query, { placeholder: "Search", onEdit: (t) => (setQuery(t), setShown(PAGE)), onCancel: () => setQuery("") }).font(12)),
    ])
      .paddingHorizontal(8)
      .frame({ width: 180, height: 24 })
      .cornerRadius(6)
      .hoverBackground("hover"),
  ]).paddingHorizontal(4)
}

function more(total) {
  return () =>
    total() > shown()
      ? mono(Text(() => `Show ${Math.min(PAGE, total() - shown())} more`).font("caption").color("secondary"))
          .paddingHorizontal(10)
          .frame({ height: 28 })
          .cornerRadius(6)
          .hoverBackground("hover")
          .cursor("pointer")
          .onTap(() => setShown(shown() + PAGE))
      : null
}

function chatList() {
  // The live chats, a rule, then the rest by age, as cmux's own list draws them.
  const leading = computed(() => listed().filter(live))
  const rest = computed(() => listed().filter((c) => !live(c)))
  const page = computed(() => rest().slice(0, shown()))
  return VStack({ spacing: 0 }, [
    ForEach({ items: leading, key: (c) => c.id }, (c) => chatLine(c)),
    () => (leading().length && rest().length ? Divider().paddingVertical(6) : null),
    LazyVStack({ spacing: 0 }, [ForEach({ items: page, key: (c) => c.id }, (c) => chatLine(c))]),
    more(() => rest().length),
  ])
}

function projectList() {
  return VStack({ spacing: 0 }, [
    ForEach({ items: projects, key: (p) => p.id }, (p) => {
      const open = () => !folded()[p().id]
      return VStack({ spacing: 0 }, [
        HStack({ spacing: 6 }, [
          Icon(() => (open() ? "disclosure.expanded" : "disclosure.collapsed")).size(10).color("tertiary"),
          mono(Text(() => p().name).font("caption").weight("medium").color("secondary")),
          mono(Text(() => String(p().rows.length)).font("caption").color("tertiary")),
          Spacer(),
        ])
          .paddingHorizontal(10)
          .frame({ height: 28 })
          .cornerRadius(6)
          .hoverBackground("hover")
          .cursor("pointer")
          .onTap(() => setFolded({ ...folded(), [p().id]: open() })),
        () => (open() ? LazyVStack({ spacing: 0 }, [ForEach({ items: () => p().rows.slice(0, PAGE), key: (c) => c.id }, (c) => chatLine(c, false))]) : null),
      ])
    }),
  ])
}

function chatsSection() {
  return VStack({ spacing: 4 }, [
    chatsHeader(),
    () => {
      if (error()) return EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
      if (!ready()) return ProgressView()
      if (listed().length === 0)
        return mono(Text(query() || filter() !== "all" ? "No matches" : "No chats yet").font("caption").color("tertiary")).paddingHorizontal(10).frame({ height: 30 })
      return view() === "projects" ? projectList() : chatList()
    },
  ])
}

function renderNewTab(context) {
  loadChats()
  loadClosed()
  // Read again when a chat changes (pushed), and Recently Closed when tabs change; only the ages
  // tick, once a minute, without a read.
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("tab.changed", loadClosed)
  cmux.events.on("workspace.changed", loadClosed)
  cmux.timer.every(MINUTE, () => setNow(Date.now()))
  return VStack({ spacing: 20 }, [field(context), closedSection(), chatsSection()])
}

globalThis.__cmuxAppExports = { renderNewTab }
