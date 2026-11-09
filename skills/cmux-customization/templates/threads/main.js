// Agent chats as a thread list. Every chat is a card: its folder and status or age on the first
// line, the title on the second, what it does now on the third. Chats that need you (a question,
// a failure, a finished turn nobody has seen) stay bright; running and read chats recede. Running
// chats wait in a Working shelf at the bottom, chats idle for over a day in Earlier; both shelves
// start closed and keep the open chat visible. A click shows the chat.
//
// Reads with agent_chat:read and workspace:read (granted at install). Clicking needs
// workspace:write (and actions:run for a chat with no workspace): turn them on in
// Settings > Apps > My views.

const DAY = 24 * 60 * 60 * 1000

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [query, setQuery] = signal("")
const [workingOpen, setWorkingOpen] = signal(false)
const [earlierOpen, setEarlierOpen] = signal(false)
const [error, setError] = signal(null)

// One read at a time; a change during a read reads once more after it.
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

// What a card says in its status slot, and in which tone. Null: it shows its age instead.
function statusOf(chat) {
  if (chat.state === "input") return { label: "Input", symbol: "questionmark.bubble", tone: "warning" }
  if (chat.state === "failed" || chat.state === "lost") return { label: "Failed", symbol: "exclamationmark.circle", tone: "danger" }
  if (chat.state === "working") return { label: `Working ${age(chat.since_ms)}`, symbol: "circle.dashed", tone: "secondary" }
  if (chat.unread) return { label: "Done", symbol: "checkmark.circle", tone: "success" }
  return null
}

// "now", "40s", "7m", "2h", "3d".
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 5) return "now"
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const needsYou = (c) => c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread
const recedes = (c) => !needsYou(c)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()

// The folder tile: one or two letters of the folder's name on a tint picked from the name.
const TINTS = ["accent", "success", "warning", "danger"]
function initials(name) {
  const words = (name || "?").split(/[^A-Za-z0-9]+/).filter(Boolean)
  return (words.length > 1 ? words[0][0] + words[1][0] : (words[0] || "?").slice(0, 2)).toUpperCase()
}
function tintOf(name) {
  let h = 0
  for (const ch of name || "") h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return TINTS[h % TINTS.length]
}

function sections() {
  const q = query().trim().toLowerCase()
  const all = chats()
    .filter((c) => !q || `${c.title} ${c.project || ""}`.toLowerCase().includes(q))
    .sort((a, b) => lastActivity(b) - lastActivity(a))
  const working = all.filter((c) => c.state === "working")
  const earlier = all.filter((c) => c.state !== "working" && !needsYou(c) && now() - lastActivity(c) > DAY)
  const active = all.filter((c) => !working.includes(c) && !earlier.includes(c))
  return { active, working, earlier }
}

async function show(chat) {
  try {
    if (chat.workspace) await cmux.workspace.focus({ workspace: chat.workspace })
    else await cmux.actions.run("agent.openSessionTab", { session: chat.id })
    load()
  } catch (e) {
    cmux.toast({ title: "Cannot open the chat", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

function card(chat) {
  const status = () => statusOf(chat())
  const dim = () => recedes(chat()) && !isOpen(chat())
  const meta = () => chat().step || chat().error || ""
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      ZStack([
        RoundedRectangle({ cornerRadius: 4 }).fill(() => tintOf(chat().project)).opacity(0.18).frame({ width: 16, height: 16 }),
        Text(() => initials(chat().project)).font(8).weight("bold").monospaced().color(() => tintOf(chat().project))
      ]),
      Text(() => chat().project || "No folder").font("caption").color("secondary").lineLimit(1),
      Spacer(),
      () => {
        const s = status()
        return s
          ? HStack({ spacing: 4 }, [Icon(s.symbol).size(11).color(s.tone), Text(s.label).font("caption").weight("medium").color(s.tone)])
          : Text(age(lastActivity(chat()))).font("caption").color("tertiary")
      }
    ]),
    Text(() => chat().title)
      .font(13)
      .weight(() => (dim() ? "regular" : "medium"))
      .color(() => (dim() ? "secondary" : "primary"))
      .lineLimit(1),
    () =>
      meta() || chat().pull_requests.length
        ? HStack({ spacing: 6 }, [
            () => (meta() ? Text(meta).font("caption").color("tertiary").lineLimit(1).truncation("tail") : null),
            Spacer(),
            () =>
              chat().pull_requests.length
                ? HStack({ spacing: 3 }, [
                    Icon("arrow.triangle.pull").size(10).color("tertiary"),
                    Text(String(chat().pull_requests.length)).font("caption").color("tertiary").fixedSize("horizontal")
                  ])
                : null,
            Text(() => chat().harness || "").font("caption").color("tertiary").fixedSize("horizontal")
          ])
        : null
  ])
    .paddingHorizontal(10)
    .paddingVertical(8)
    .cornerRadius(6)
    .background(() => (isOpen(chat()) ? "selected" : null))
    .hoverBackground(() => (isOpen(chat()) ? "selected" : "hover"))
    .opacity(() => (chat().state === "working" && !isOpen(chat()) ? 0.75 : 1))
    .help(() => [chat().title, chat().cwd, chat().harness].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(chat()))
    .contextMenu([
      Button("Show Chat", () => show(chat())),
      Button("Open Chat in New Tab", () => cmux.actions.run("agent.openSessionTab", { session: chat().id }))
    ])
}

// A shelf: a quiet header with its count and a chevron; closed, it still shows the open chat.
function shelf(title, items, open, setOpen) {
  const shown = computed(() => (open() ? items() : items().filter(isOpen)))
  return () =>
    items().length
      ? VStack({ spacing: 1 }, [
          HStack({ spacing: 6 }, [
            Text(title).font("caption").weight("medium").color("secondary"),
            Text(() => String(items().length)).font("caption").color("tertiary"),
            Spacer(),
            Icon("chevron.right").size(9).color("tertiary").rotation(() => (open() ? 90 : 0))
          ])
            .paddingHorizontal(10)
            .frame({ height: 28 })
            .cornerRadius(6)
            .hoverBackground("hover")
            .cursor("pointer")
            .onTap(() => setOpen(!open())),
          ForEach({ items: shown, key: (c) => c.id }, card)
        ])
      : null
}

function renderThreads() {
  load()
  // Chat state lives in the app: read it again every two seconds, and at once when the open
  // workspace changes.
  cmux.timer.every(2000, load)
  cmux.events.on("workspace.changed", load)
  const all = computed(sections)
  return VStack({ spacing: 1 }, [
    HStack({ spacing: 6 }, [
      Icon("magnifyingglass").size(12).color("tertiary"),
      TextField(query, { placeholder: "Search", onEdit: setQuery, onCancel: () => setQuery("") }).font(13)
    ])
      .paddingHorizontal(10)
      .frame({ height: 30 })
      .cornerRadius(6)
      .hoverBackground("hover"),
    ForEach({ items: () => all().active, key: (c) => c.id }, card),
    () =>
      error()
        ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
        : chats().length === 0
          ? EmptyState({ title: "No chats yet", message: "Start an agent chat and it shows here.", symbol: "bubble.left" })
          : null,
    shelf("Working", () => all().working, workingOpen, setWorkingOpen),
    shelf("Earlier", () => all().earlier, earlierOpen, setEarlierOpen)
  ])
}

globalThis.__cmuxAppExports = { renderThreads }
