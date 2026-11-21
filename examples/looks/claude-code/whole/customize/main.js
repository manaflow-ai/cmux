// Claude: the Claude app's home on every New Tab, Claude's usage left in the sidebar, and a
// Claude Code status line in each chat's Session Info. One chat read per change
// (agent_chat.changed) and one usage read every five minutes; nothing polls.

const [chats, setChats] = signal([])
const [usage, setUsage] = signal(null) // { session, weekly, accounts, usable, verdict } for Claude
const [usageError, setUsageError] = signal(null)
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Claude`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

let reading = false
let again = false
async function loadChats() {
  if (reading) return void (again = true)
  reading = true
  try {
    setChats((await cmux.call("agent_chat.list", {})).chats)
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

// What a failed usage read says, in words: a cmux whose views cannot reach the Usage app yet answers
// operation.unsupported (or provider.unavailable while it starts); never the raw reason.
function usageProblem(e) {
  const code = e && e.code
  if (code === "operation.unsupported" || code === "provider.unavailable") return "This cmux does not share the Usage app with views yet."
  if (code === "scope.missing") return "Turn on Usage for Claude in Settings > Apps."
  return "The Usage app did not answer. It tries again in a few minutes."
}

async function loadUsage(refresh = false) {
  try {
    const status = await cmux.call("usage_app.status", { accounts: true, refresh })
    const claude = (status.providers || []).find((p) => p.id === "claude")
    if (!claude) {
      setUsageError(status.problem?.message ?? "Add a Claude account in the Usage pane.")
      return
    }
    const accounts = claude.accounts || []
    const nums = (key) => accounts.map((a) => a[key]).filter((n) => typeof n === "number")
    const weekly = nums("weekly_left_pct")
    const session = nums("session_left_pct")
    setUsage({
      accounts: accounts.length,
      usable: claude.summary?.usable ?? 0,
      weekly: weekly.length ? weekly.reduce((a, b) => a + b, 0) / weekly.length : null,
      session: session.length ? Math.min(...session) : null,
      verdict: claude.pace?.verdict ?? null
    })
    setUsageError(null)
  } catch (e) {
    setUsageError(usageProblem(e))
  }
}

let following = false
function follow() {
  if (following) return
  following = true
  loadChats()
  loadUsage()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.timer.every(5 * 60_000, () => loadUsage())
  cmux.timer.every(60_000, () => setNow(Date.now()))
}

const isClaude = (c) => String(c.harness || "").toLowerCase().startsWith("claude")
const recents = computed(() =>
  chats()
    .filter(isClaude)
    .sort((a, b) => (b.updated_ms || b.created_ms || 0) - (a.updated_ms || a.created_ms || 0))
    .slice(0, 8)
)

function ago(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "just now"
  if (s < 3600) return `${Math.floor(s / 60)} min ago`
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`
  return `${Math.floor(s / 86400)} d ago`
}

function greeting() {
  const h = new Date(now()).getHours()
  return h < 5 ? "Burning the midnight oil" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
}

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function start() {
  const text = draft().trim()
  run("palette.newAgentChat", text ? { harness: "claude", draft: text } : { harness: "claude" })
  setDraft("")
}

const pct = (n) => (n === null || n === undefined ? "–" : `${Math.round(n)}%`)
const toneOf = (n) => (n === null ? cmux.theme.text.secondary : n < 15 ? cmux.theme.danger : n < 40 ? cmux.theme.warning : cmux.theme.accent)

// ---- New Tab: Claude's home ---------------------------------------------------------------------

function renderHome() {
  follow()
  return VStack({ spacing: 18 }, [
    Spacer(),
    HStack({ spacing: 10 }, [
      Spacer(),
      Icon("task.ai").size(28).color(cmux.theme.accent),
      Text(() => greeting()).font("largeTitle").weight("regular"),
      Spacer()
    ]),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "How can I help you today?", onEdit: setDraft, onSubmit: start }).font("title3"),
      HStack({ spacing: 8 }, [
        Menu("Mode", [
          Button("Ask before edits", () => run("agentPane.setMode")),
          Button("Choose the model", () => run("agentPane.switchModel")),
          Button("Set the effort", () => run("agentPane.setEffort"))
        ]),
        Spacer(),
        Text(() => (usage() ? `${pct(usage().session)} of this session left` : "")).font("caption").color(cmux.theme.text.secondary),
        Button(HStack({ spacing: 4 }, [Icon("composer.send"), Text("Start")]), start)
      ])
    ]),
    Panel({ title: "Recents", style: "card" }, [
      ForEach({ items: recents, key: (c) => c.id }, (c) =>
        Row({
          title: () => c().title,
          subtitle: () => `${c().project || "No project"} · ${ago(c().updated_ms || c().created_ms)}`,
          symbol: () => (c().state === "working" ? "status.inprogress" : c().state === "input" ? "status.needsinput" : "agent.chat"),
          tint: () => (c().state === "input" ? cmux.theme.warning : c().unread ? cmux.theme.accent : cmux.theme.text.secondary)
        }).onTap(() => show(c()))
      ),
      () => (recents().length ? null : EmptyState({ title: "No Claude chats yet", message: "Ask something above to start one.", symbol: "task.ai" }))
    ]),
    Spacer()
  ])
}

// ---- Sidebar: Claude's usage left ---------------------------------------------------------------

function meter(label, value) {
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [Text(label).font("caption").color(cmux.theme.text.secondary), Spacer(), Text(() => pct(value())).monospaced().color(() => toneOf(value()))]),
    ProgressView(() => (value() === null ? null : value() / 100))
  ])
}

function renderUsage() {
  follow()
  return VStack({ spacing: 8 }, [
    () => {
      if (usageError() && !usage()) return EmptyState({ title: "No Claude usage here yet", message: usageError(), symbol: "context.usage" })
      if (!usage()) return ProgressView()
      return VStack({ spacing: 8 }, [
        meter("Session left", () => usage().session),
        meter("This week left", () => usage().weekly),
        HStack({ spacing: 6 }, [
          Badge(() => `${usage().usable}/${usage().accounts}`, cmux.theme.accent).help("Claude accounts that can take work now, of all you have"),
          Text(() => ({ under: "under pace", onPace: "on pace", over: "over pace" })[usage().verdict] || "").font("caption").color(cmux.theme.text.secondary),
          Spacer(),
          Button("New chat", () => run("palette.newAgentChat", { harness: "claude" }))
        ])
      ])
    }
  ]).contextMenu([Button("Read usage now", () => loadUsage(true))])
}

// ---- Session Info: a Claude Code status line ----------------------------------------------------

// Claude Code's status line, as cmux knows it: the folder, the branch, the harness, what the chat
// does now, and the usage left. One line, then the details under it.
function renderStatusLine(context) {
  follow()
  const id = context && context.session_id
  const chat = computed(() => chats().find((c) => c.id === id) || null)
  const folder = () => {
    const cwd = String((context && context.cwd) || (chat() && chat().cwd) || "")
    return cwd.split("/").filter(Boolean).pop() || "~"
  }
  const branch = String((context && context.branch) || "").trim()
  const harness = () => String((context && context.harness) || (chat() && chat().harness) || "claude")
  const line = () =>
    [folder(), branch ? `⎇ ${branch}` : null, harness(), usage() ? `session ${pct(usage().session)} · week ${pct(usage().weekly)}` : null]
      .filter(Boolean)
      .join("  ·  ")
  return VStack({ spacing: 4 }, [
    HStack({ spacing: 6 }, [Icon("disclosure.collapsed").size(10).color(cmux.theme.accent), Text(line).monospaced().lineLimit(1).truncation("middle")]),
    () =>
      chat() && (chat().step || chat().error)
        ? Text(() => chat().error || chat().step).font("caption").color(() => (chat().error ? cmux.theme.danger : cmux.theme.text.secondary)).lineLimit(2)
        : null,
    () =>
      chat() && chat().pull_requests.length
        ? Row({ title: () => `${chat().pull_requests.length} pull request${chat().pull_requests.length > 1 ? "s" : ""}`, symbol: "arrow.triangle.pull", tint: cmux.theme.success })
        : null
  ])
}

globalThis.__cmuxAppExports = { renderHome, renderUsage, renderStatusLine }
