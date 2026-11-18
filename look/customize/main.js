// Agent sessions as the Claude Code desktop app lists them: one row each (title, project, age),
// filterable by status, project or environment, and grouped by project when asked. The filters sit
// in one row of menus over the list; each says what it shows now ("All statuses", "acme-web",
// "Local"). Built from the threads template (skills/cmux-customization/templates/threads).
//
// Reads with agent_chat:read and workspace:read. Clicking needs workspace:write (and actions:run
// for a session with no workspace).

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [status, setStatus] = signal("all")
const [project, setProject] = signal(null)
const [environment, setEnvironment] = signal(null)
const [grouped, setGrouped] = signal(true)
const [error, setError] = signal(null)

let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    const [list, workspaces] = await Promise.all([cmux.call("agent_chat.list", {}), cmux.workspace.list({})])
    setChats(list.chats)
    setOpenWorkspace((workspaces.find((w) => w.focused) || {}).id || null)
    setNow(Date.now())
    setError(null)
  } catch (e) {
    setError(e instanceof Error ? e.message : String(e))
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

const STATUSES = [
  ["all", "All statuses"],
  ["needs", "Needs you"],
  ["working", "Working"],
  ["done", "Done"],
]
function statusKey(c) {
  if (c.state === "working") return "working"
  if (c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread) return "needs"
  return "done"
}
const envOf = (c) => c.machine || "Local"
const projectOf = (c) => c.project || "No project"
const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()

function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const unique = (values) => [...new Set(values)].sort((a, b) => a.localeCompare(b))

function shown() {
  return chats()
    .filter((c) => status() === "all" || statusKey(c) === status())
    .filter((c) => !project() || projectOf(c) === project())
    .filter((c) => !environment() || envOf(c) === environment())
    .sort((a, b) => lastActivity(b) - lastActivity(a))
}

/// [{ key, title, chats }]: one group per project when grouped, else one untitled group.
function groups() {
  const list = shown()
  if (!grouped()) return [{ key: "all", title: null, chats: list }]
  const by = new Map()
  for (const c of list) {
    const key = projectOf(c)
    if (!by.has(key)) by.set(key, [])
    by.get(key).push(c)
  }
  return [...by.entries()].map(([key, items]) => ({ key, title: key, chats: items }))
}

async function show(chat) {
  try {
    if (chat.workspace) await cmux.workspace.focus({ workspace: chat.workspace })
    else await cmux.actions.run("agent.openSessionTab", { session: chat.id })
    load()
  } catch (e) {
    cmux.toast({ title: "Cannot open the session", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

function glyph(chat) {
  const key = statusKey(chat)
  if (key === "working") return Icon("asterisk").size(11).color("accent")
  if (key === "needs") return Icon("circle.fill").size(6).color("accent")
  return Icon("circle").size(6).color("tertiary")
}

function row(chat) {
  return HStack({ spacing: 8 }, [
    () => glyph(chat()),
    Text(() => chat().title)
      .font(13)
      .color(() => (statusKey(chat()) === "done" && !isOpen(chat()) ? "secondary" : "primary"))
      .lineLimit(1),
    Spacer(),
    Text(() => age(lastActivity(chat()))).font("caption").color("tertiary").fixedSize("horizontal"),
  ])
    .paddingHorizontal(10)
    .frame({ height: 28 })
    .cornerRadius(6)
    .background(() => (isOpen(chat()) ? "selected" : null))
    .hoverBackground(() => (isOpen(chat()) ? "selected" : "hover"))
    .help(() => [chat().title, chat().cwd, envOf(chat()), chat().harness].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(chat()))
    .contextMenu([
      Button("Show Session", () => show(chat())),
      Button("Open Session in New Tab", () => cmux.actions.run("agent.openSessionTab", { session: chat().id })),
    ])
}

function filters() {
  const statusName = () => (STATUSES.find(([key]) => key === status()) || STATUSES[0])[1]
  return HStack({ spacing: 4 }, [
    () =>
      Menu(statusName(), STATUSES.map(([key, name]) => Button(name, () => setStatus(key)))),
    () =>
      Menu(project() || "All projects", [
        Button("All projects", () => setProject(null)),
        Divider(),
        ...unique(chats().map(projectOf)).map((name) => Button(name, () => setProject(name))),
      ]),
    () =>
      Menu(environment() || "All environments", [
        Button("All environments", () => setEnvironment(null)),
        Divider(),
        ...unique(chats().map(envOf)).map((name) => Button(name, () => setEnvironment(name))),
      ]),
    Spacer(),
    Menu("View", [
      Button("Group by project", () => setGrouped(true)),
      Button("No grouping", () => setGrouped(false)),
    ]),
  ]).paddingHorizontal(6)
}

function group(entry) {
  return VStack({ spacing: 1 }, [
    () =>
      entry().title
        ? HStack({ spacing: 6 }, [
            Icon("folder").size(11).color("tertiary"),
            Text(() => entry().title).font("caption").weight("medium").color("secondary").lineLimit(1),
            Spacer(),
            Text(() => String(entry().chats.length)).font("caption").color("tertiary"),
          ])
            .paddingHorizontal(10)
            .frame({ height: 24 })
        : null,
    ForEach({ items: () => entry().chats, key: (c) => c.id }, row),
  ])
}

function renderSessions() {
  load()
  // Read again when the app says a chat changed, and when the open workspace changes; only the
  // ages tick on a timer, without a read.
  cmux.events.on("agent_chat.changed", load)
  cmux.events.on("workspace.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  const all = computed(groups)
  return VStack({ spacing: 2 }, [
    filters(),
    ForEach({ items: all, key: (g) => g.key }, group),
    () =>
      error()
        ? EmptyState({ title: "Cannot read your sessions", message: error(), symbol: "exclamationmark.triangle" })
        : chats().length === 0
          ? EmptyState({ title: "No sessions yet", message: "Start an agent chat and it shows here.", symbol: "bubble.left" })
          : shown().length === 0
            ? EmptyState({ title: "No sessions match", message: "Change the filters to see more.", symbol: "line.3.horizontal.decrease" })
            : null,
  ])
}

globalThis.__cmuxAppExports = { renderSessions }
