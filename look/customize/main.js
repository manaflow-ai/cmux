// The Codex app's sidebar as a section: New thread, Automations and Skills rows on top, a quiet
// "Threads" header, then each project folder with its threads under it, newest first, the time
// since a thread last moved on the right ("2h", "18h", "1d"). The open thread is the selected row.
// Reads with agent_chat:read and workspace:read; clicks need workspace:write and actions:run (turn
// them on in Settings > Apps > My views).

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
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

// "now", "7m", "2h", "3d", "2w".
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  if (s < 14 * 86400) return `${Math.floor(s / 86400)}d`
  return `${Math.floor(s / (7 * 86400))}w`
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()
const folderOf = (c) => {
  const path = c.cwd || c.project || ""
  return c.project || path.split("/").filter(Boolean).pop() || "No folder"
}

// Projects ordered by their newest thread; threads in a project newest first.
function folders() {
  const byFolder = new Map()
  for (const chat of [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    const name = folderOf(chat)
    if (!byFolder.has(name)) byFolder.set(name, [])
    byFolder.get(name).push(chat)
  }
  return [...byFolder].map(([name, threads]) => ({ name, threads }))
}

async function run(action, args) {
  try {
    await cmux.actions.run(action, args || {})
  } catch (e) {
    cmux.toast({ title: "Cannot open it", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

async function show(chat) {
  if (chat.workspace) {
    try {
      await cmux.workspace.focus({ workspace: chat.workspace })
    } catch (e) {
      cmux.toast({ title: "Cannot open the thread", message: e instanceof Error ? e.message : String(e), tone: "warning" })
    }
  } else await run("agent.openSessionTab", { session: chat.id })
  load()
}

// The Codex app's rows are the sidebar's own rows (Row): an outline glyph and a label on top, a
// folder glyph for a project, and a thread with its age on the right.
const topRow = (title, symbol, action) => Row({ title, symbol }).onTap(() => run(action))

function threadRow(chat) {
  return Row({
    title: () => chat().title,
    accessory: Text(() => age(lastActivity(chat()))).font("caption").color("tertiary"),
    selected: () => isOpen(chat())
  })
    .help(() => [chat().title, chat().cwd].filter(Boolean).join("\n"))
    .onTap(() => show(chat()))
}

function folderBlock(folder) {
  return VStack({ spacing: 1 }, [
    Row({ title: () => folder().name, symbol: "folder" }),
    ForEach({ items: () => folder().threads, key: (c) => c.id }, threadRow)
  ])
}

function renderThreads() {
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.events.on("workspace.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  const all = computed(folders)
  return VStack({ spacing: 1 }, [
    topRow("New thread", "square.and.pencil", "new.agentChat"),
    topRow("Automations", "clock", "automations.show"),
    topRow("Skills", "cube", "appStore.show"),
    Text("Threads").font("caption").color("tertiary"),
    ForEach({ items: all, key: (f) => f.name }, folderBlock),
    () =>
      error()
        ? EmptyState({ title: "Cannot read your threads", message: error(), symbol: "exclamationmark.triangle" })
        : chats().length === 0
          ? EmptyState({ title: "No threads yet", message: "Start a thread and it shows here.", symbol: "bubble.left" })
          : null
  ])
}

globalThis.__cmuxAppExports = { renderThreads }
