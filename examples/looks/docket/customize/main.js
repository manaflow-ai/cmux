// Docket's sidebar: a hover card laid out like an inbox notification, and rows that mark work in
// progress with the thin arc.
// An Inbox at the top of the sidebar and a Properties list in Session Info, the two places a
// tracker keeps what wants you and what an item is.
// Public surfaces only: cmux.hovercard/1, cmux.sidebar.rows/1, cmux.section/1 and
// cmux.session.info.section/1 (docs/cmux-next/sidebar-customization.md).

// The card reads as one inbox row: the title with the age at the right ("1h"), then one gray line
// with why it wants you (what it waits on, the unread notification, else its status), then the
// task, then the facts as quiet gray lines: identity, subject and reason on three lines, the way a
// tracker's inbox keeps an update from turning into a card of its own.
const REASON = ["needsInput", "notification", "unread"]
const FACTS = ["branch", "pullRequest", "folder", "agent"]

function renderCard(ctx) {
  const card = ctx.card
  const pick = (kinds) => kinds.flatMap((kind) => card.facts.filter((fact) => fact.kind === kind))
  const reason = pick(REASON)[0]
  const task = pick(["task"])[0]
  return VStack({ spacing: 2 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    reason ? Text(reason.text).secondary().lineLimit(2) : card.status ? Text(card.status).secondary().lineLimit(1) : null,
    task ? Text(task.text).lineLimit(3) : null,
    ...pick(FACTS).map((fact) => Text(fact.text).secondary().lineLimit(1)),
  ])
}

// Rows: regular weight (a dense list never bolds its rows) and the thin arc while work runs, the
// tracker's state ring that fills as work moves. Each decoration names its row by id (`row`); the
// title stays the row's own name, and the icon stays the one you chose.
function decorateRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => workspaces() ?? [], key: (w) => w.id }, (w) =>
      Group({ row: () => w().id, title: () => w().name, weight: () => "regular", indicator: () => "arc" }, []),
    ),
  ])
}

// The Inbox: only the chats that want you (a question, a failure, a finished turn nobody has
// read), newest first, one line each: the state glyph before the title, the age at the right, the
// way a tracker's inbox lists notifications. Everything else stays in the list below it. A click
// shows the chat's workspace once you turn on workspace:write in Settings > Apps.
const [inbox, setInbox] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [inboxError, setInboxError] = signal(null)
let reading = false
let again = false

async function readInbox() {
  if (reading) return void (again = true)
  reading = true
  try {
    const [list, workspaces] = await Promise.all([cmux.call("agent_chat.list", {}), cmux.workspace.list({})])
    const wants = (c) => c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread
    const last = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
    setInbox(list.chats.filter(wants).sort((a, b) => last(b) - last(a)))
    setOpenWorkspace((workspaces.find((w) => w.focused) || {}).id || null)
    setNow(Date.now())
    setInboxError(null)
  } catch (e) {
    setInboxError(e instanceof Error ? e.message : String(e))
  } finally {
    reading = false
    if (again) {
      again = false
      readInbox()
    }
  }
}

// "now", "7m", "2h", "3d": the tracker's short age.
function shortAge(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

// The state glyph: a question, something that broke, or done and unread, in the tone that says so.
function glyph(chat) {
  if (chat.state === "input") return { symbol: "questionmark.circle", tone: "warning" }
  if (chat.state === "failed" || chat.state === "lost") return { symbol: "exclamationmark.circle", tone: "danger" }
  return { symbol: "checkmark.circle", tone: "accent" }
}

async function showChat(chat) {
  try {
    if (chat.workspace) await cmux.workspace.focus({ workspace: chat.workspace })
    readInbox()
  } catch (e) {
    cmux.toast({ title: "Cannot show the chat", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

function inboxRow(chat) {
  const open = () => chat().workspace != null && chat().workspace === openWorkspace()
  return HStack({ spacing: 8 }, [
    Icon(() => glyph(chat()).symbol).size(12).color(() => glyph(chat()).tone),
    Text(() => chat().title).lineLimit(1).truncation("tail"),
    Spacer(),
    Text(() => shortAge(Math.max(chat().updated_ms || 0, chat().since_ms || 0)))
      .font("caption")
      .color("tertiary")
      .fixedSize("horizontal"),
  ])
    .paddingHorizontal(8)
    .paddingVertical(4)
    .cornerRadius(4)
    .background(() => (open() ? "selected" : null))
    .hoverBackground(() => (open() ? "selected" : "hover"))
    .help(() => [chat().title, chat().step || chat().error, chat().cwd].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => showChat(chat()))
}

function renderInbox() {
  readInbox()
  // The app says when a chat or the open workspace changes; read again then. Only the ages tick.
  cmux.events.on("agent_chat.changed", readInbox)
  cmux.events.on("workspace.changed", readInbox)
  cmux.timer.every(60000, () => setNow(Date.now()))
  return VStack({ spacing: 1 }, [
    ForEach({ items: inbox, key: (c) => c.id }, inboxRow),
    () =>
      inboxError()
        ? EmptyState({ title: "Cannot read your chats", message: inboxError(), symbol: "exclamationmark.triangle" })
        : inbox().length === 0
          ? Text("Nothing wants you").font("caption").color("tertiary").paddingHorizontal(8).paddingVertical(4)
          : null,
  ])
}

// Properties: the chat's folder, branch and agent as label and value pairs, the way a tracker's
// side panel lists an issue's properties: labels in gray, values in the text color, one line each.
function property(label, value, symbol) {
  return HStack({ spacing: 8 }, [
    Icon(symbol).size(12).color("tertiary"),
    Text(label).color("secondary").lineLimit(1).fixedSize("horizontal"),
    Spacer(),
    Text(value).lineLimit(1).truncation("middle"),
  ])
}

function renderProperties(context) {
  const cwd = String((context && context.cwd) || "")
  const folder = cwd.split("/").filter(Boolean).slice(-2).join("/")
  const branch = String((context && context.branch) || "").trim()
  const agent = String((context && context.harness) || "").trim()
  return VStack({ spacing: 6 }, [
    folder ? property("Folder", folder, "folder").help(cwd) : null,
    branch ? property("Branch", branch, "arrow.triangle.branch") : null,
    agent ? property("Agent", agent, "sparkles") : null,
    !folder && !branch && !agent ? Text("No properties yet").font("caption").color("tertiary") : null,
  ])
}

globalThis.__cmuxAppExports = { renderCard, decorateRows, renderInbox, renderProperties }
