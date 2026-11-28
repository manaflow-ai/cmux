// Codex: the Codex app's New Tab (what should we build next, in the project you pick), its thread
// list by project in the sidebar, and its rate limits in each chat's Session Info, the way Codex's
// /status prints them. One chat read per change (agent_chat.changed), one usage read every five
// minutes; nothing polls.

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [limits, setLimits] = signal(null) // { session, weekly, accounts, usable, verdict } for Codex
const [limitsError, setLimitsError] = signal(null)
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")
const [project, setProject] = signal(null) // { name, cwd } the New Tab starts in

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Codex`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

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

async function loadLimits(refresh = false) {
  try {
    const status = await cmux.call("usage_app.status", { accounts: true, refresh })
    const codex = (status.providers || []).find((p) => p.id === "codex")
    if (!codex) {
      setLimitsError(status.problem?.message ?? "Add a Codex account in the Usage pane.")
      return
    }
    const accounts = codex.accounts || []
    const nums = (key) => accounts.map((a) => a[key]).filter((n) => typeof n === "number")
    const weekly = nums("weekly_left_pct")
    const session = nums("session_left_pct")
    setLimits({
      accounts: accounts.length,
      usable: codex.summary?.usable ?? 0,
      weekly: weekly.length ? weekly.reduce((a, b) => a + b, 0) / weekly.length : null,
      session: session.length ? Math.min(...session) : null,
      verdict: codex.pace?.verdict ?? null
    })
    setLimitsError(null)
  } catch (e) {
    setLimitsError(limitsProblem(e))
  }
}

// What a failed limits read says, in words: a cmux whose views cannot reach the Usage app yet answers
// operation.unsupported (or provider.unavailable while it starts); never the raw reason.
function limitsProblem(e) {
  const code = e && e.code
  if (code === "operation.unsupported" || code === "provider.unavailable") return "Rate limits show here once this cmux shares the Usage app with views."
  if (code === "scope.missing") return "Turn on Usage for Codex in Settings > Apps to see your rate limits."
  return "The Usage app did not answer. Right-click to read the limits again."
}

let following = false
function follow() {
  if (following) return
  following = true
  loadChats()
  loadLimits()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("workspace.changed", loadChats)
  cmux.timer.every(5 * 60_000, () => loadLimits())
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()

// "now", "7m", "2h", "3d": Codex's compact times at the end of a thread.
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

// Projects, newest thread first, each with its threads newest first.
const projects = computed(() => {
  const groups = new Map()
  for (const c of [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    const name = c.project || "No project"
    if (!groups.has(name)) groups.set(name, { name, cwd: c.cwd || null, threads: [] })
    groups.get(name).threads.push(c)
  }
  return [...groups.values()]
})

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

const picked = () => project() || projects()[0] || null

function start() {
  const text = draft().trim()
  const args = { harness: "codex" }
  if (text) args.draft = text
  if (picked()?.cwd) args.cwd = picked().cwd
  run("palette.newAgentChat", args)
  setDraft("")
}

const pct = (n) => (n === null || n === undefined ? "–" : `${Math.round(n)}%`)

// ---- New Tab: what should we build -------------------------------------------------------------

function renderHome() {
  follow()
  return VStack({ spacing: 16 }, [
    Spacer(),
    Text("What should we build?").font("largeTitle").weight("semibold"),
    Text(() => (picked() ? `in ${picked().name}` : "in a new project")).font("title3").color(cmux.theme.text.secondary),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask Codex anything", onEdit: setDraft, onSubmit: start }).font("title3"),
      HStack({ spacing: 8 }, [
        // The menu reads the projects when it opens (a Menu takes a function of its items).
        Menu(() => (picked() ? picked().name : "Project"), () => [
          ...projects().slice(0, 12).map((p) => Button(p.name, () => setProject({ name: p.name, cwd: p.cwd }))),
          Divider(),
          Button("No project", () => setProject({ name: "No project", cwd: null }))
        ]),
        Button(HStack({ spacing: 4 }, [Icon("diff.file"), Text("Review")]), () => run("openDiffViewer")),
        Spacer(),
        Text(() => (limits() ? `${pct(limits().session)} left` : "")).font("caption").color(cmux.theme.text.secondary),
        Button(HStack({ spacing: 4 }, [Icon("composer.send"), Text("Send")]), start)
      ])
    ]),
    Panel({ title: "Recent threads", style: "card" }, [
      ForEach({ items: () => chats().slice().sort((a, b) => lastActivity(b) - lastActivity(a)).slice(0, 6), key: (c) => c.id }, (c) =>
        Row({
          title: () => c().title,
          symbol: () => (c().state === "working" ? "status.inprogress" : "agent.chat"),
          // A Row's accessory is an icon name; the age goes in the subtitle.
          subtitle: () => `${c().project || "No project"} · ${age(lastActivity(c()))}`
        }).onTap(() => show(c()))
      ),
      () => (chats().length ? null : EmptyState({ title: "No threads yet", message: "Send something above to start one.", symbol: "agent.chat" }))
    ]),
    Spacer()
  ])
}

// ---- Session Info: rate limits, like /status ---------------------------------------------------

function bar(label, value) {
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [Text(label).font("caption").color(cmux.theme.text.secondary), Spacer(), Text(() => `${pct(value())} left`).monospaced()]),
    ProgressView(() => (value() === null ? null : value() / 100))
  ])
}

function renderLimits(context) {
  follow()
  const id = context && context.session_id
  const chat = computed(() => chats().find((c) => c.id === id) || null)
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Text(() => String((context && context.harness) || (chat() && chat().harness) || "codex")).weight("semibold"),
      Text(() => (context && context.branch ? `· ${context.branch}` : "")).color(cmux.theme.text.secondary).lineLimit(1),
      Spacer()
    ]),
    () => {
      if (limitsError() && !limits()) return Text(limitsError).font("caption").color(cmux.theme.text.secondary)
      if (!limits()) return ProgressView()
      return VStack({ spacing: 6 }, [
        bar("5h limit", () => limits().session),
        bar("Weekly limit", () => limits().weekly),
        Text(() => `${limits().usable} of ${limits().accounts} Codex account${limits().accounts === 1 ? "" : "s"} can take work`).font("caption").color(cmux.theme.text.tertiary)
      ])
    }
  ]).contextMenu([Button("Read limits now", () => loadLimits(true))])
}

// Session Info supplies the thread ID. chat.list supplies its machine, working folder and workspace.
function renderOpenIn(context) {
  const chats = cmux.watch("chat.list")
  const launch = (chat, app) => cmux.call("tab.create_terminal", {
    workspace: chat.workspace,
    cwd: chat.cwd,
    name: "Open in " + app,
    argv: ["/usr/bin/open", "-a", app, chat.cwd]
  }).catch(error => cmux.toast({ title: "Open in " + app, message: String(error), tone: "warning" }))

  return VStack({ spacing: 4 }, [
    () => {
      if (chats.error()) return Text(String(chats.error())).font("caption")
      if (!chats.value()) return ProgressView()
      const matches = chats.value().filter(chat => chat.id === context.session_id)
      const chat = matches.length === 1 ? matches[0] : null
      if (!chat || chat.machine || !chat.workspace || !chat.cwd || !chat.cwd.startsWith("/"))
        return Text("Open a local thread with a project folder to choose an editor.").font("caption")
      return Menu("Open folder in…", [
        Button("Cursor", () => launch(chat, "Cursor")),
        Button("VS Code", () => launch(chat, "Visual Studio Code")),
        Button("Finder", () => launch(chat, "Finder"))
      ]).help(chat.cwd)
    }
  ])
}

function renderSettings() {
  const open = (action, args = {}) => cmux.actions.run(action, args).catch(error => cmux.toast({ title: "Settings", message: String(error), tone: "warning" }))
  return VStack({ spacing: 4 }, [
    Button("Settings…", () => open("openSettings")),
    Button("Appearance", () => open("openSettings", { setting: "appearance.themeFile" })),
    Button("Chat font", () => open("openSettings", { setting: "agentPane.display.font.size" })),
    Button("Keyboard shortcuts", () => open("keybindings.open"))
  ])
}
function renderSessionInfo(context) {
  return VStack({ spacing: 8 }, [renderLimits(context), renderOpenIn(context), renderSettings()])
}
globalThis.__cmuxAppExports = { renderHome, renderSessionInfo }
