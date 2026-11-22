// Studio: its thread list (threads under each project with a count, a status chip per row, a
// Settled shelf for finished work), its start page (a prompt, one button per agent, and every
// account's usage on one page), a thread details card in Session Info, and a work-log hover card.
// One chat read per change (agent_chat.changed), one usage read every five minutes; nothing polls.

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [usage, setUsage] = signal(null)
const [usageError, setUsageError] = signal(null)
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")
const [settled, setSettled] = signal({}) // chat id -> settled at (ms)
const [settledOpen, setSettledOpen] = signal(false)
const [closed, setClosed] = signal({}) // project -> true when its group is closed

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Studio`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

// Settled threads are remembered with storage:local; without it they settle until a reload.
cmux.storage
  .get("settled")
  .then((saved) => saved && setSettled(saved))
  .catch(() => undefined)
const saveSettled = () => cmux.storage.set("settled", settled()).catch(() => undefined)

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

const NAMES = { claude: "Claude Code", codex: "Codex" }
// What a failed usage read says, in words: a cmux whose views cannot reach the Usage app yet answers
// operation.unsupported (or provider.unavailable while it starts); never the raw reason.
function usageProblem(e) {
  const code = e && e.code
  if (code === "operation.unsupported" || code === "provider.unavailable") return "This cmux does not share the Usage app with views yet."
  if (code === "scope.missing") return "Turn on Usage for Studio in Settings > Apps."
  return "The Usage app did not answer. Right-click to read it again."
}
async function loadUsage(refresh = false) {
  try {
    const status = await cmux.call("usage_app.status", { accounts: true, refresh })
    if (!(status.providers || []).length && (status.problem || (status.state && status.state !== "ready"))) {
      setUsageError(status.problem?.message ?? `The Usage app is ${status.state}`)
      return
    }
    setUsage(
      (status.providers || []).map((p) => {
        const accounts = p.accounts || []
        const nums = (key) => accounts.map((a) => a[key]).filter((n) => typeof n === "number")
        const weekly = nums("weekly_left_pct")
        const session = nums("session_left_pct")
        return {
          id: p.id,
          accounts: accounts.length,
          weekly: weekly.length ? weekly.reduce((a, b) => a + b, 0) / weekly.length : null,
          session: session.length ? Math.min(...session) : null,
          extra: accounts.reduce((sum, a) => sum + (typeof a.extra_usage_usd === "number" ? a.extra_usage_usd : 0), 0)
        }
      })
    )
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
  cmux.events.on("workspace.changed", loadChats)
  cmux.timer.every(5 * 60_000, () => loadUsage())
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()
// A thread you settled stays settled until it changes again (a new turn brings it back).
const isSettled = (c) => settled()[c.id] != null && settled()[c.id] >= lastActivity(c)

function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

// The status chip: what the thread is doing, in its tone. Null: a quiet, read thread.
function chipOf(c) {
  if (c.state === "working") return { label: `Working ${age(c.since_ms)}`, symbol: "status.inprogress", tone: cmux.theme.accent }
  if (c.state === "input") return { label: "Input", symbol: "status.needsinput", tone: cmux.theme.warning }
  if (c.state === "failed" || c.state === "lost") return { label: "Failed", symbol: "status.error", tone: cmux.theme.danger }
  if (c.unread) return { label: "Done", symbol: "status.success", tone: cmux.theme.success }
  return null
}

const live = computed(() => chats().filter((c) => !isSettled(c)))
const settledThreads = computed(() => chats().filter(isSettled).sort((a, b) => lastActivity(b) - lastActivity(a)))
// The list draws a bounded number of rows whatever the number of chats: the newest projects, the
// newest threads in each (the open one always), and a count of the rest. A row per chat made the
// app's VM run past its 250 ms step with about a thousand chats, and the host stopped it.
const MAX_PROJECTS = 10
const MAX_THREADS = 8
const MAX_SETTLED = 20
const projects = computed(() => {
  const groups = new Map()
  for (const c of [...live()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    const name = c.project || "No project"
    if (!groups.has(name)) groups.set(name, { name, threads: [] })
    groups.get(name).threads.push(c)
  }
  return [...groups.values()].slice(0, MAX_PROJECTS).map((g) => {
    const shown = g.threads.slice(0, MAX_THREADS)
    const open = g.threads.slice(MAX_THREADS).find(isOpen)
    if (open) shown.push(open)
    return { ...g, shown }
  })
})
const hiddenThreads = computed(() => live().length - projects().reduce((n, p) => n + p.shown.length, 0))

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function settle(chat, on) {
  setSettled((s) => {
    const next = { ...s }
    if (on) next[chat.id] = Date.now()
    else delete next[chat.id]
    return next
  })
  saveSettled()
  if (on) cmux.toast({ title: "Settled", message: chat.title })
}

// ---- Sidebar: threads by project ---------------------------------------------------------------

function thread(c) {
  const chip = () => chipOf(c())
  return HStack({ spacing: 6 }, [
    Text(() => c().title)
      .font(12)
      .weight(() => (chip() || isOpen(c()) ? "medium" : "regular"))
      .color(() => (chip() || isOpen(c()) ? "primary" : "secondary"))
      .lineLimit(1),
    Spacer(),
    () => {
      const s = chip()
      return s
        ? HStack({ spacing: 3 }, [Icon(s.symbol).size(9).color(s.tone), Text(s.label).font("caption").weight("medium").color(s.tone).fixedSize("horizontal")])
            .paddingHorizontal(5)
            .paddingVertical(1)
            .cornerRadius(4)
            .background("hover")
        : Text(age(lastActivity(c()))).font("caption").monospaced().color(cmux.theme.text.tertiary).fixedSize("horizontal")
    }
  ])
    .paddingHorizontal(8)
    .frame({ height: 24 })
    .cornerRadius(5)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground(() => (isOpen(c()) ? "selected" : "hover"))
    .help(() => [c().title, c().cwd, c().harness, c().step].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(() => [
      Button("Open in New Tab", () => run("agent.openSessionTab", { session: c().id })),
      Divider(),
      isSettled(c()) ? Button("Unsettle", () => settle(c(), false)) : Button("Settle", () => settle(c(), true))
    ])
}

function header(title, count, open, onTap) {
  return HStack({ spacing: 6 }, [
    Icon("chevron.right").size(8).color(cmux.theme.text.tertiary).rotation(() => (open() ? 90 : 0)),
    Text(title).font("caption").weight("semibold").color(cmux.theme.text.secondary).lineLimit(1),
    Spacer(),
    Text(() => String(count())).font("caption").monospaced().color(cmux.theme.text.tertiary)
  ])
    .paddingHorizontal(8)
    .frame({ height: 22 })
    .cornerRadius(5)
    .hoverBackground("hover")
    .cursor("pointer")
    .onTap(onTap)
}

function renderThreads() {
  follow()
  return VStack({ spacing: 1 }, [
    HStack({ spacing: 6 }, [
      Button(HStack({ spacing: 4 }, [Icon("square.and.pencil"), Text("New thread")]), () => run("palette.newAgentChat")),
      Spacer(),
      Button(Icon("magnifyingglass"), () => run("agentPane.searchChats")).help("Search threads (Command-K)")
    ]),
    ForEach({ items: projects, key: (p) => p.name }, (p) =>
      VStack({ spacing: 0 }, [
        header(
          () => p().name,
          () => p().threads.length,
          () => !closed()[p().name],
          () => setClosed((s) => ({ ...s, [p().name]: !s[p().name] }))
        ),
        ForEach({ items: () => (closed()[p().name] ? p().shown.filter(isOpen) : p().shown), key: (c) => c.id }, thread)
      ])
    ),
    () =>
      hiddenThreads() > 0
        ? Text(() => `${hiddenThreads()} more · Command-K searches every thread`).font("caption").color(cmux.theme.text.tertiary).paddingHorizontal(8)
        : null,
    () => (chats().length ? null : EmptyState({ title: "No threads yet", message: "Shift-Command-O starts one.", symbol: "list.bullet.rectangle" })),
    () =>
      settledThreads().length
        ? VStack({ spacing: 0 }, [
            Divider(),
            header("Settled", () => settledThreads().length, settledOpen, () => setSettledOpen(!settledOpen())),
            ForEach({ items: () => (settledOpen() ? settledThreads().slice(0, MAX_SETTLED) : []), key: (c) => c.id }, thread)
          ])
        : null
  ])
}

// ---- New Tab: the studio's start page ---------------------------------------------------------

const AGENTS = [
  { harness: "claude", label: "Claude Code", symbol: "task.ai" },
  { harness: "codex", label: "Codex", symbol: "code" }
]

function start(harness) {
  const text = draft().trim()
  const args = { harness }
  if (text) args.draft = text
  run("palette.newAgentChat", args)
  setDraft("")
}

const pct = (n) => (n === null || n === undefined ? "–" : `${Math.round(n)}%`)

function usageRow(u) {
  return VStack({ spacing: 3 }, [
    HStack({ spacing: 6 }, [
      Text(() => NAMES[u().id] ?? u().id).weight("semibold").fixedSize("horizontal"),
      Badge(() => String(u().accounts), cmux.theme.accent).help("Accounts"),
      Spacer()
    ]),
    ProgressView(() => (u().weekly === null ? null : u().weekly / 100)),
    // The numbers on a line of their own, so a narrow card wraps them and never the name.
    Text(() => `session ${pct(u().session)} · week ${pct(u().weekly)}${u().extra > 0 ? ` · $${u().extra.toFixed(2)} extra` : ""}`)
      .font("caption")
      .monospaced()
      .color(cmux.theme.text.secondary)
  ])
}

function renderStart() {
  follow()
  const counts = computed(() => ({
    working: live().filter((c) => c.state === "working").length,
    input: live().filter((c) => c.state === "input" || c.state === "failed" || c.state === "lost").length,
    done: live().filter((c) => c.unread && c.state !== "working").length
  }))
  return VStack({ spacing: 14 }, [
    Spacer(),
    HStack({ spacing: 8 }, [
      Text("Studio").font("title").weight("semibold").fixedSize("horizontal"),
      Menu("Create", [
        Button("New Tab in Session", () => run("newSurface")),
        Button("New Local Session", () => run("workspace.newOnMachine", { machine: "local" })),
        Button("New Session on Host…", () => run("palette.open", { query: "New Workspace on Machine" })),
        Button("Add Remote Host…", () => run("remote.connect"))
      ]),
      Spacer(),
      Text(() => `${counts().working} working · ${counts().input} need you · ${counts().done} done`).font("caption").monospaced().color(cmux.theme.text.secondary)
    ]),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask anything, @ to add files", onEdit: setDraft, onSubmit: () => start("claude") }),
      HStack({ spacing: 6 }, [
        ...AGENTS.map((a) => Button(HStack({ spacing: 4 }, [Icon(a.symbol), Text(a.label)]), () => start(a.harness))),
        Spacer(),
        Menu("Model", [Button("Choose the model", () => run("agentPane.switchModel")), Button("Set the effort", () => run("agentPane.setEffort"))])
      ])
    ]),
    HStack({ spacing: 12, alignment: "top" }, [
      Panel({ title: "Recent", style: "card" }, [
        ForEach({ items: () => [...live()].sort((a, b) => lastActivity(b) - lastActivity(a)).slice(0, 7), key: (c) => c.id }, (c) =>
          Row({
            title: () => c().title,
            subtitle: () => `${c().project || "No project"} · ${c().harness || "agent"} · ${age(lastActivity(c()))}`,
            symbol: () => (chipOf(c()) ? chipOf(c()).symbol : "agent.chat"),
            tint: () => (chipOf(c()) ? chipOf(c()).tone : cmux.theme.text.secondary)
          }).onTap(() => show(c()))
        ),
        () => (live().length ? null : EmptyState({ title: "No threads yet", symbol: "view.list" }))
      ]).frame({ width: "infinity" }),
      Panel({ title: "Usage", style: "card" }, [
        () => {
          if (usageError() && !usage()) return EmptyState({ title: "No usage here yet", message: usageError(), symbol: "context.usage" })
          if (!usage()) return ProgressView()
          if (!usage().length) return EmptyState({ title: "No accounts", message: "Add a Claude or Codex account in the Usage pane.", symbol: "account" })
          return VStack({ spacing: 8 }, [ForEach({ items: usage, key: (u) => u.id }, usageRow)])
        }
      ])
        .frame({ width: "infinity" })
        .contextMenu([Button("Read usage now", () => loadUsage(true))])
    ]),
    Spacer()
  ])
}

// ---- Session Info: thread details --------------------------------------------------------------

function fact(label, value) {
  return () =>
    value()
      ? HStack({ spacing: 6 }, [
          Text(label).font("caption").color(cmux.theme.text.tertiary).frame({ width: 64 }),
          Text(value).font("caption").monospaced().lineLimit(1).truncation("middle"),
          Spacer()
        ])
      : null
}

function renderDetails(context) {
  follow()
  const id = context && context.session_id
  const chat = computed(() => chats().find((c) => c.id === id) || null)
  return VStack({ spacing: 3 }, [
    () => {
      const s = chat() && chipOf(chat())
      return HStack({ spacing: 6 }, [
        Text(() => (chat() ? chat().title : "This thread")).weight("semibold").lineLimit(1),
        Spacer(),
        s ? HStack({ spacing: 3 }, [Icon(s.symbol).size(9).color(s.tone), Text(s.label).font("caption").color(s.tone)]) : null
      ])
    },
    fact("Agent", () => String((context && context.harness) || (chat() && chat().harness) || "")),
    fact("Branch", () => String((context && context.branch) || "")),
    fact("Folder", () => String((context && context.cwd) || (chat() && chat().cwd) || "")),
    fact("Now", () => (chat() ? chat().error || chat().step || "" : "")),
    fact("PRs", () => (chat() && chat().pull_requests.length ? String(chat().pull_requests.length) : "")),
    fact("Started", () => (chat() && chat().created_ms ? `${age(chat().created_ms)} ago` : "")),
    () =>
      chat()
        ? HStack({ spacing: 6 }, [
            Button("Diff", () => run("openDiffViewer")),
            isSettled(chat()) ? Button("Unsettle", () => settle(chat(), false)) : Button("Settle", () => settle(chat(), true)),
            Spacer()
          ])
        : null
  ])
}

// ---- Hover card: a work log --------------------------------------------------------------------

const ORDER = ["needsInput", "task", "command", "presence", "branch", "pullRequest", "folder"]

function renderCard(ctx) {
  const card = ctx.card
  const since = (ms) => (ms ? age(ms) : "")
  const facts = ORDER.flatMap((kind) => card.facts.filter((f) => f.kind === kind))
  return VStack({ spacing: 3 }, [
    HStack([Text(card.title).bold().lineLimit(1), Spacer(), Text(card.age ?? "").secondary()]),
    card.status ? Text(`${card.status} ${since(card.statusSinceMs)}`.trim()).secondary() : null,
    ...facts.map((f) =>
      HStack([Text(f.text).monospaced().lineLimit(f.kind === "task" ? 3 : 1), Spacer(), f.sinceMs ? Text(since(f.sinceMs)).secondary() : null])
    )
  ])
}

globalThis.__cmuxAppExports = { renderThreads, renderStart, renderDetails, renderCard }
