// The studio look's sidebar, after the reference app. A search row with filter, new-folder and
// new-chat buttons; then every chat on three lines: its project chip and its age (or status), the
// chat's title, and its branch with the agent's glyph. Chats that need you or ran in the last day
// stay in the list; running chats wait in a Working shelf and the rest in Settled, both at the
// bottom and closed, each keeping the open chat visible. A click shows the chat.
//
// Built from the threads template (skills/cmux-customization/templates/threads). Reads with
// agent_chat:read and workspace:read (granted at install); clicking needs workspace:write and
// actions:run, turned on in Settings > Apps.

const DAY = 24 * 60 * 60 * 1000

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [query, setQuery] = signal("")
const [onlyNeedsYou, setOnlyNeedsYou] = signal(false)
const [workingOpen, setWorkingOpen] = signal(false)
const [settledOpen, setSettledOpen] = signal(false)
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

function statusOf(chat) {
  if (chat.state === "input") return { label: "Input", symbol: "questionmark.bubble", tone: "warning" }
  if (chat.state === "failed" || chat.state === "lost") return { label: "Failed", symbol: "exclamationmark.circle", tone: "danger" }
  if (chat.state === "working") return { label: `Working ${age(chat.since_ms)}`, symbol: "circle.dashed", tone: "secondary" }
  if (chat.unread) return { label: "Done", symbol: "checkmark.circle", tone: "success" }
  return null
}

function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const needsYou = (c) => c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()

// The project chip: two letters of the project's name on a tint picked from the name.
const TINTS = ["danger", "accent", "warning", "success"]
function initials(name) {
  const words = (name || "?").split(/[^A-Za-z0-9]+/).filter(Boolean)
  return (words.length > 1 ? words[0][0] + words[1][0] : (words[0] || "?").slice(0, 2)).toUpperCase()
}
function tintOf(name) {
  let h = 0
  for (const ch of name || "") h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return TINTS[h % TINTS.length]
}

// The agent's glyph at the end of the third line.
function glyphOf(harness) {
  const h = (harness || "").toLowerCase()
  if (h.includes("claude")) return { symbol: "asterisk", tone: "warning" }
  if (h.includes("codex")) return { symbol: "hexagon", tone: "secondary" }
  if (h.includes("gemini")) return { symbol: "sparkle", tone: "accent" }
  return { symbol: "circle.fill", tone: "tertiary" }
}

// The third line: the chat's branch when the app reports one, else what it does now.
const thirdLine = (c) => c.branch || c.step || c.error || ""

function sections() {
  const q = query().trim().toLowerCase()
  const all = chats()
    .filter((c) => !q || `${c.title} ${c.project || ""} ${c.branch || ""}`.toLowerCase().includes(q))
    .filter((c) => !onlyNeedsYou() || needsYou(c) || c.state === "working")
    .sort((a, b) => lastActivity(b) - lastActivity(a))
  const working = all.filter((c) => c.state === "working")
  const settled = all.filter((c) => c.state !== "working" && !needsYou(c) && now() - lastActivity(c) > DAY)
  const recent = all.filter((c) => !working.includes(c) && !settled.includes(c))
  return { recent, working, settled }
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

async function run(action, title) {
  try {
    await cmux.actions.run(action, {})
  } catch (e) {
    cmux.toast({ title, message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

function card(chat) {
  const status = () => statusOf(chat())
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      ZStack([
        RoundedRectangle({ cornerRadius: 3 }).fill(() => tintOf(chat().project)).opacity(0.2).frame({ width: 16, height: 14 }),
        Text(() => initials(chat().project)).font(7).weight("bold").monospaced().color(() => tintOf(chat().project))
      ]),
      Text(() => chat().project || "No project").font("caption").color("secondary").lineLimit(1),
      Spacer(),
      () => {
        const s = status()
        return s
          ? HStack({ spacing: 4 }, [Icon(s.symbol).size(11).color(s.tone), Text(s.label).font("caption").color(s.tone)])
          : Text(age(lastActivity(chat()))).font("caption").color("secondary")
      }
    ]),
    Text(() => chat().title).font(14).weight("medium").color("primary").lineLimit(1).truncation("tail"),
    HStack({ spacing: 6 }, [
      Text(() => thirdLine(chat())).font("caption").color("secondary").lineLimit(1).truncation("middle"),
      Spacer(),
      () => {
        const glyph = glyphOf(chat().harness)
        return Icon(glyph.symbol).size(11).color(glyph.tone)
      }
    ])
  ])
    .paddingHorizontal(10)
    .paddingVertical(8)
    .cornerRadius(8)
    .background(() => (isOpen(chat()) ? "selected" : null))
    .hoverBackground(() => (isOpen(chat()) ? "selected" : "hover"))
    .help(() => [chat().title, chat().cwd, chat().harness].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(chat()))
    .contextMenu([
      Button("Show Chat", () => show(chat())),
      Button("Open Chat in New Tab", () => cmux.actions.run("agent.openSessionTab", { session: chat().id }))
    ])
}

// A shelf at the bottom: its name, its count and a chevron; closed, it still shows the open chat.
function shelf(title, items, open, setOpen) {
  const shown = computed(() => (open() ? items() : items().filter(isOpen)))
  return () =>
    items().length
      ? VStack({ spacing: 1 }, [
          HStack({ spacing: 6 }, [
            Text(title).font("caption").color("secondary"),
            Spacer(),
            Text(() => String(items().length)).font("caption").color("secondary"),
            Icon("chevron.right").size(9).color("tertiary").rotation(() => (open() ? 90 : 0))
          ])
            .paddingHorizontal(10)
            .frame({ height: 30 })
            .cornerRadius(8)
            .hoverBackground("hover")
            .cursor("pointer")
            .onTap(() => setOpen(!open())),
          ForEach({ items: shown, key: (c) => c.id }, card)
        ])
      : null
}

function iconButton(symbol, help, onTap, active) {
  return Icon(symbol)
    .size(13)
    .color(() => (active && active() ? "accent" : "secondary"))
    .frame({ width: 22, height: 22 })
    .cornerRadius(6)
    .hoverBackground("hover")
    .help(help)
    .cursor("pointer")
    .onTap(onTap)
}

function renderChats() {
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.events.on("workspace.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  const all = computed(sections)
  return VStack({ spacing: 1 }, [
    HStack({ spacing: 6 }, [
      Icon("magnifyingglass").size(12).color("secondary"),
      TextField(query, { placeholder: "Search", onEdit: setQuery, onCancel: () => setQuery("") }).font(14),
      iconButton("line.3.horizontal.decrease", "Only chats that need you or are working", () => setOnlyNeedsYou(!onlyNeedsYou()), onlyNeedsYou),
      iconButton("folder.badge.plus", "Open a folder", () => run("openFolder", "Cannot open a folder")),
      iconButton("square.and.pencil", "New chat", () => run("new.agentChat", "Cannot start a chat"))
    ])
      .paddingHorizontal(10)
      .frame({ height: 34 }),
    ForEach({ items: () => all().recent, key: (c) => c.id }, card),
    () =>
      error()
        ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
        : chats().length === 0
          ? EmptyState({ title: "No chats yet", message: "Start an agent chat and it shows here.", symbol: "bubble.left" })
          : null,
    Spacer(),
    shelf("Working", () => all().working, workingOpen, setWorkingOpen),
    shelf("Settled", () => all().settled, settledOpen, setSettledOpen)
  ])
}

globalThis.__cmuxAppExports = { renderChats }
