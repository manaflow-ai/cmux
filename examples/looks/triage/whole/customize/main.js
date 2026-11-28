// Triage: an agent workbench's pieces as cmux views. One file serves every folder of this look
// (sidebar, archive-settled, open-in-editor, project-picker, composer, model-picker, whole); each
// folder's cmux-app.json names only the exports it uses. build.py copies it from whole/.
//
//   renderInbox     cmux.section/1               the thread inbox: Pinned, Active, Snoozed, Settled
//   renderStart     cmux.newtab/1                "What should we build in <project>?" + the composer
//   renderThread    cmux.session.info.section/1  the thread's header actions: Open in editor, Settle,
//                                                Snooze, Archive, model / effort / mode
//   projectCorpus   palette scope "projects"     the project picker
//
// One chat read per change (agent_chat.changed); nothing polls. Settle, snooze and pin are kept
// with storage:local under the same keys in every folder, so the pieces agree with each other.

const [chats, setChats] = signal([])
const [openWorkspace, setOpenWorkspace] = signal(null)
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")
const [store, setStore] = signal({ settled: {}, snoozed: {}, pinned: {}, editor: null, project: null })
const [shelfOpen, setShelfOpen] = signal({ snoozed: false, settled: false })
const [settledShown, setSettledShown] = signal(10)
const [scope, setScope] = signal(null) // project filter (cwd) or null for all

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Triage`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args || {}).catch(refused("Run actions"))

cmux.storage
  .get("triage")
  .then((saved) => saved && setStore((s) => ({ ...s, ...saved })))
  .catch(() => undefined)
const save = () => cmux.storage.set("triage", store()).catch(() => undefined)
const update = (fn) => {
  setStore((s) => fn({ ...s, settled: { ...s.settled }, snoozed: { ...s.snoozed }, pinned: { ...s.pinned } }))
  save()
}

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

let following = false
function follow() {
  if (following) return
  following = true
  loadChats()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.events.on("workspace.changed", loadChats)
  // Relative times and snooze wakes: the reference ticks at the next wake; a 30 s tick is enough here.
  cmux.timer.every(30_000, () => setNow(Date.now()))
}

// ---- The thread model: the reference's four places ---------------------------------------------
// Snoozed outranks settled, settled outranks pinned, the rest is the active inbox. A new turn
// (activity after the settle or snooze) brings a thread back, as the reference's activity unsettle.

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const isOpen = (c) => c.workspace != null && c.workspace === openWorkspace()
const snoozedUntil = (c) => {
  const s = store().snoozed[c.id]
  return s && s.until > now() && s.at >= lastActivity(c) ? s.until : null
}
const isSettled = (c) => store().settled[c.id] != null && store().settled[c.id] >= lastActivity(c)
const isPinned = (c) => store().pinned[c.id] != null
const placeOf = (c) => (snoozedUntil(c) ? "snoozed" : isSettled(c) ? "settled" : isPinned(c) ? "pinned" : "active")
const projectName = (c) => c.project || (c.cwd ? c.cwd.split("/").filter(Boolean).pop() : "No project")
const inScope = (c) => !scope() || c.cwd === scope()

// "now", Nm, Nh, Nd: the reference's compact relative time with " ago" removed.
function age(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "now"
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return `${Math.floor(s / 86400)}d`
}

// The status label on a card row: the reference's Working / Input / Failed / Done, with its icons.
function statusOf(c) {
  if (c.state === "working") return { label: `Working ${age(c.since_ms) === "now" ? "" : age(c.since_ms)}`.trim(), symbol: "circle.dashed", tone: cmux.theme.accent }
  if (c.state === "input") return { label: "Input", symbol: "questionmark.bubble", tone: cmux.theme.warning }
  if (c.state === "failed" || c.state === "lost") return { label: "Failed", symbol: "exclamationmark.circle", tone: cmux.theme.danger }
  if (c.unread) return { label: "Done", symbol: "checkmark.circle", tone: cmux.theme.success }
  return null
}

const byPlace = (place) => computed(() => chats().filter((c) => inScope(c) && placeOf(c) === place))
const pinned = byPlace("pinned")
const active = computed(() => byPlace("active")().sort((a, b) => lastActivity(b) - lastActivity(a)).slice(0, 40))
const snoozed = computed(() => byPlace("snoozed")().sort((a, b) => snoozedUntil(a) - snoozedUntil(b)))
const settled = computed(() => byPlace("settled")().sort((a, b) => store().settled[b.id] - store().settled[a.id]))
const projects = computed(() => {
  const seen = new Map()
  for (const c of [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    if (!c.cwd || seen.has(c.cwd)) continue
    seen.set(c.cwd, { cwd: c.cwd, name: projectName(c), last: lastActivity(c), count: 0 })
  }
  for (const c of chats()) if (c.cwd && seen.has(c.cwd)) seen.get(c.cwd).count++
  return [...seen.values()]
})

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).then(loadChats, refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

// Settling or snoozing the open thread moves to the next card in list order (wrapping), as the
// reference's row button and menu do; with none left it starts a new thread in that project.
function advanceFrom(chat) {
  if (!isOpen(chat)) return
  const cards = [...pinned(), ...active()].filter((c) => c.id !== chat.id)
  if (!cards.length) return run("palette.newAgentChat", chat.cwd ? { cwd: chat.cwd } : {})
  const order = [...pinned(), ...active()]
  const i = order.findIndex((c) => c.id === chat.id)
  show(order.slice(i + 1).find((c) => c.id !== chat.id) || cards[0])
}

function settle(chat, on) {
  if (on && chat.state === "working") return cmux.toast({ title: "Still working", message: "A running thread settles when its turn ends.", tone: "warning" })
  update((s) => {
    if (on) {
      s.settled[chat.id] = Date.now()
      delete s.pinned[chat.id] // settling unpins and wakes, as in the reference
      delete s.snoozed[chat.id]
    } else delete s.settled[chat.id]
    return s
  })
  if (on) {
    cmux.toast({ title: "Settled 1 thread", message: chat.title })
    advanceFrom(chat)
  }
}

// The reference's presets: In 1 hour, In 3 hours, This evening (18:00, if more than an hour
// away), Tomorrow (09:00), Next week (Monday 09:00, unless that is tomorrow).
function snoozePresets() {
  const d = new Date(now())
  const at = (days, hour) => {
    const t = new Date(d)
    t.setDate(t.getDate() + days)
    t.setHours(hour, 0, 0, 0)
    return t.getTime()
  }
  const presets = [
    { label: "In 1 hour", until: now() + 3600_000 },
    { label: "In 3 hours", until: now() + 3 * 3600_000 }
  ]
  if (at(0, 18) - now() > 3600_000) presets.push({ label: "This evening", until: at(0, 18) })
  presets.push({ label: "Tomorrow", until: at(1, 9) })
  const toMonday = ((8 - d.getDay()) % 7) || 7
  if (toMonday !== 1) presets.push({ label: "Next week", until: at(toMonday, 9) })
  return presets
}

function snooze(chat, until) {
  update((s) => {
    if (until) s.snoozed[chat.id] = { until, at: Date.now() }
    else delete s.snoozed[chat.id]
    return s
  })
  if (until) {
    cmux.toast({ title: "Snoozed 1 thread", message: chat.title })
    advanceFrom(chat)
  }
}

function pin(chat, on) {
  update((s) => {
    if (on) s.pinned[chat.id] = Date.now()
    else delete s.pinned[chat.id]
    return s
  })
}

// ---- Open in editor ------------------------------------------------------------------------------
// The reference's split button: "Open" opens the preferred editor (the last one used), the chevron
// lists the rest. agentPane.openCwdInEditor opens the chat's folder in an app; until a cmux has it,
// the setup's cmuxConfig actions do (`open -a <App> .`).

const EDITORS = [
  { id: "vscode", label: "VS Code", app: "Visual Studio Code", symbol: "chevron.left.forwardslash.chevron.right", fallback: "cmuxConfig.triage-open-vscode" },
  { id: "cursor", label: "Cursor", app: "Cursor", symbol: "cursorarrow.rays", fallback: "cmuxConfig.triage-open-cursor" },
  { id: "zed", label: "Zed", app: "Zed", symbol: "bolt", fallback: "cmuxConfig.triage-open-zed" },
  { id: "finder", label: "Finder", app: null, symbol: "folder", fallback: null }
]
const preferredEditor = () => EDITORS.find((e) => e.id === store().editor) || EDITORS[0]

function openIn(editor, chat) {
  update((s) => ((s.editor = editor.id), s))
  if (!editor.app) return run("agentPane.revealCwdInFinder")
  const args = { editor: editor.app }
  if (chat && chat.cwd) args.cwd = chat.cwd
  cmux.actions.run("agentPane.openCwdInEditor", args).catch(() => (editor.fallback ? run(editor.fallback) : undefined))
}

function openInButton(chat) {
  return HStack({ spacing: 0 }, [
    Button(HStack({ spacing: 4 }, [Icon(() => preferredEditor().symbol).size(12), Text("Open")]), () => openIn(preferredEditor(), chat && chat()))
      .help(() => `Open in ${preferredEditor().label} (Command-O)`),
    Menu("Open in…", EDITORS.map((e) => Button(HStack({ spacing: 6 }, [Icon(e.symbol), Text(`Open in ${e.label}`)]), () => openIn(e, chat && chat()))))
      .help("Choose editor")
  ])
}

// ---- Sidebar: the inbox --------------------------------------------------------------------------

function threadMenu(c) {
  return () => {
    const chat = c()
    const place = placeOf(chat)
    return [
      Button("New thread in this project", () => run("palette.newAgentChat", chat.cwd ? { cwd: chat.cwd } : {})),
      isPinned(chat) ? Button("Unpin thread", () => pin(chat, false)) : Button("Pin thread", () => pin(chat, true)),
      place === "settled" ? Button("Un-settle thread", () => settle(chat, false)) : Button("Settle thread", () => settle(chat, true)),
      place === "snoozed"
        ? Button("Wake thread", () => snooze(chat, null))
        : Menu("Snooze", snoozePresets().map((p) => Button(p.label, () => snooze(chat, p.until)))),
      Divider(),
      Button(`Open in ${preferredEditor().label}`, () => openIn(preferredEditor(), chat)),
      Button("Reveal in Finder", () => run("agentPane.revealCwdInFinder")),
      Button(scope() ? "Show all projects" : `Filter by ${projectName(chat)}`, () => setScope(scope() ? null : chat.cwd)),
      Divider(),
      Button("Open in New Tab", () => run("agent.openSessionTab", { session: chat.id })),
      Button("Archive", () => (show(chat), run("agentPane.archiveChat")))
    ]
  }
}

// A card: three lines in 78 pt (the reference's h-[4.875rem], 10 pt sides, 8 pt top and bottom):
// project and status, the title at 14 pt, then branch, agent and pull requests at 12 pt. On hover the
// status gives way to Settle and Snooze.
function card(c) {
  const status = () => statusOf(c())
  return VStack({ spacing: 2, alignment: "leading" }, [
    HStack({ spacing: 6 }, [
      Icon(() => (isPinned(c()) ? "pin.fill" : "folder")).size(12).color(cmux.theme.text.tertiary),
      Text(() => projectName(c())).font(12).weight("medium").color(cmux.theme.text.secondary).lineLimit(1),
      Spacer(),
      () => {
        const s = status()
        return s
          ? HStack({ spacing: 3 }, [Icon(s.symbol).size(12).color(s.tone), Text(s.label).font(12).weight("medium").color(s.tone).fixedSize("horizontal")])
          : Text(age(lastActivity(c()))).font(12).monospaced().color(cmux.theme.text.tertiary).fixedSize("horizontal")
      }
    ]).frame({ height: 20 }),
    Text(() => c().title)
      .font(14)
      .weight("medium")
      .color(() => (status() || isOpen(c()) ? "primary" : "secondary"))
      .lineLimit(1),
    HStack({ spacing: 6 }, [
      () => (c().branch ? HStack({ spacing: 3 }, [Icon("arrow.triangle.branch").size(10), Text(c().branch).font(12).lineLimit(1).truncation("middle")]) : null),
      () => ((c().pull_requests || []).length ? Badge(`PR ${c().pull_requests.length}`, cmux.theme.accent) : null),
      Spacer(),
      Text(() => c().harness || "").font(12).color(cmux.theme.text.tertiary)
    ]).color(cmux.theme.text.secondary)
  ])
    .paddingHorizontal(10)
    .paddingVertical(8)
    .frame({ height: 78 })
    .cornerRadius(8)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground(() => (isOpen(c()) ? "selected" : "hover"))
    .help(() => [c().title, c().cwd, c().step].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(threadMenu(c))
}

// A slim row: one line in 36 pt (h-9, 10 pt sides, 10 pt gap) for settled and snoozed threads, the
// title at 14 pt in the secondary color, the time since settled or the wake time at the right.
function slim(c) {
  const right = () => (placeOf(c()) === "snoozed" ? age(2 * now() - snoozedUntil(c())) : age(store().settled[c().id]))
  return HStack({ spacing: 10 }, [
    Icon("folder").size(14).color(cmux.theme.text.tertiary),
    Text(() => c().title).font(14).color(cmux.theme.text.secondary).lineLimit(1),
    Spacer(),
    Text(right).font(12).monospaced().color(cmux.theme.text.tertiary).fixedSize("horizontal")
  ])
    .paddingHorizontal(10)
    .frame({ height: 36 })
    .cornerRadius(8)
    .background(() => (isOpen(c()) ? "selected" : null))
    .hoverBackground("hover")
    .cursor("pointer")
    .onTap(() => show(c()))
    .contextMenu(threadMenu(c))
}

// A shelf header: 32 pt, 12 pt medium at 60%, a hairline, a chevron; "Settled (N)" when closed.
function shelf(title, key, items) {
  return HStack({ spacing: 8 }, [
    Text(() => (shelfOpen()[key] ? title : `${title} (${items().length})`)).font(12).weight("medium").color(cmux.theme.text.tertiary).fixedSize("horizontal"),
    Divider(),
    Icon("chevron.down").size(9).color(cmux.theme.text.tertiary).rotation(() => (shelfOpen()[key] ? 180 : 0))
  ])
    .paddingHorizontal(8)
    .frame({ height: 32 })
    .cursor("pointer")
    .onTap(() => setShelfOpen((s) => ({ ...s, [key]: !s[key] })))
}

function renderInbox() {
  follow()
  return VStack({ spacing: 1 }, [
    // The header row: Search (32 pt), then the project scope, Add project and New thread (28 pt each).
    HStack({ spacing: 4 }, [
      Button(HStack({ spacing: 8 }, [Icon("magnifyingglass"), Text("Search")]), () => run("agentPane.searchChats")).help("Search threads (Command-K)"),
      Spacer(),
      () =>
        Menu(scope() ? projects().find((p) => p.cwd === scope())?.name ?? "Project" : "All", [
          Button("All projects", () => setScope(null)),
          Divider(),
          ...projects().slice(0, 20).map((p) => Button(p.name, () => setScope(p.cwd)))
        ]).help("Project"),
      Button(Icon("folder.badge.plus"), () => run("openFolder")).help("Add project"),
      Button(Icon("square.and.pencil"), () => run("palette.newAgentChat", scope() ? { cwd: scope() } : {})).help("New thread (Command-N)")
    ]).frame({ height: 32 }),
    ForEach({ items: pinned, key: (c) => c.id }, card),
    ForEach({ items: active, key: (c) => c.id }, card),
    () => (chats().length ? null : EmptyState({ title: "No threads yet", message: "Command-N starts one.", symbol: "square.and.pencil" })),
    Spacer(),
    () =>
      snoozed().length
        ? VStack({ spacing: 1 }, [shelf("Snoozed", "snoozed", snoozed), ForEach({ items: () => (shelfOpen().snoozed ? snoozed() : []), key: (c) => c.id }, slim)])
        : null,
    () =>
      settled().length
        ? VStack({ spacing: 1 }, [
            shelf("Settled", "settled", settled),
            ForEach({ items: () => (shelfOpen().settled ? settled().slice(0, settledShown()) : []), key: (c) => c.id }, slim),
            () =>
              shelfOpen().settled && settled().length > settledShown()
                ? Button(`Show ${Math.min(25, settled().length - settledShown())} more`, () => setSettledShown(settledShown() + 25))
                : null
          ])
        : null
  ])
}

// ---- Session Info: the thread's header actions --------------------------------------------------

function renderThread(context) {
  follow()
  const id = context && context.session_id
  const chat = computed(() => chats().find((c) => c.id === id) || null)
  return VStack({ spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Text(() => (chat() ? projectName(chat()) : "")).font("caption").color(cmux.theme.text.secondary).lineLimit(1),
      Spacer(),
      openInButton(chat)
    ]),
    () =>
      chat()
        ? HStack({ spacing: 6 }, [
            placeOf(chat()) === "settled" ? Button("Un-settle", () => settle(chat(), false)) : Button(HStack({ spacing: 4 }, [Icon("checkmark"), Text("Settle")]), () => settle(chat(), true)),
            placeOf(chat()) === "snoozed"
              ? Button("Wake", () => snooze(chat(), null))
              : Menu("Snooze", snoozePresets().map((p) => Button(p.label, () => snooze(chat(), p.until)))),
            Spacer(),
            Button(Icon("archivebox"), () => run("agentPane.archiveChat")).help("Archive")
          ])
        : null,
    // The composer's footer controls, left to right as the reference orders them: model, effort,
    // access mode, Build/Plan. cmux's own pickers open from here until the composer takes buttons.
    HStack({ spacing: 6 }, [
      Button(HStack({ spacing: 4 }, [Icon("cpu"), Text("Model")]), () => run("agentPane.switchModel")).help("Model (Shift-Command-M)"),
      Button(HStack({ spacing: 4 }, [Icon("brain"), Text("Effort")]), () => run("agentPane.setEffort")).help("Effort (Shift-Command-E)"),
      Button(HStack({ spacing: 4 }, [Icon("lock"), Text("Mode")]), () => run("agentPane.composer.switchMode")).help("Access mode (Shift-Command-A)"),
      Button(Icon("pencil.and.ruler"), () => run("agentPane.composer.togglePlan")).help("Build / Plan (Shift-Tab)"),
      Spacer()
    ])
  ])
}

// ---- New Tab: the draft hero and composer ---------------------------------------------------------
// "What should we build in <Project>?" with the project as a menu (No project, each project, Add
// project), a prompt, and the footer's model, effort and mode controls with a round Send.

const chosenProject = () => projects().find((p) => p.cwd === store().project) || projects()[0] || null

function start() {
  const p = chosenProject()
  const text = draft().trim()
  const args = {}
  if (p && store().project !== "") args.cwd = p.cwd
  if (text) args.draft = text
  run("palette.newAgentChat", args)
  setDraft("")
}

function renderStart() {
  follow()
  return VStack({ spacing: 14 }, [
    Spacer(),
    HStack({ spacing: 6 }, [
      Text("What should we build in").font("title").weight("semibold").fixedSize("horizontal"),
      () =>
        Menu(store().project === "" || !chosenProject() ? "no project" : chosenProject().name, [
          Button("No project", () => update((s) => ((s.project = ""), s))),
          Divider(),
          ...projects().slice(0, 30).map((p) => Button(p.name, () => update((s) => ((s.project = p.cwd), s)))),
          Divider(),
          Button("Add project", () => run("openFolder"))
        ]),
      Text("?").font("title").weight("semibold").fixedSize("horizontal")
    ]),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask anything, @tag files/folders, $use skills, or / for commands", onEdit: setDraft, onSubmit: start }),
      HStack({ spacing: 6 }, [
        Button(HStack({ spacing: 4 }, [Icon("cpu"), Text("Model")]), () => run("agentPane.switchModel")),
        Button(HStack({ spacing: 4 }, [Icon("brain"), Text("Effort")]), () => run("agentPane.setEffort")),
        Button(HStack({ spacing: 4 }, [Icon("lock"), Text("Mode")]), () => run("agentPane.composer.switchMode")),
        Spacer(),
        Button(Icon("paperclip"), () => run("agentPane.addProjectFiles")).help("Attach files"),
        Button(Icon("arrow.up"), start).help("Send message")
      ])
    ]),
    Spacer()
  ])
}

// ---- Palette: the project picker ------------------------------------------------------------------

const projectCorpus = palette.snapshot(async () => {
  const list = (await cmux.call("agent_chat.list", {})).chats || []
  const seen = new Map()
  for (const c of [...list].sort((a, b) => lastActivity(b) - lastActivity(a))) {
    if (!c.cwd || seen.has(c.cwd)) continue
    seen.set(c.cwd, c)
  }
  return [...seen.values()].slice(0, 1000).map((c) => ({
    id: c.cwd,
    title: projectName(c),
    subtitle: c.cwd,
    symbol: "folder",
    keywords: [projectName(c)],
    actions: [
      act("palette.newAgentChat", { cwd: c.cwd }, { title: "New thread", symbol: "square.and.pencil" }),
      act("agentPane.openCwdInEditor", { cwd: c.cwd }, { title: "Open in editor", symbol: "chevron.left.forwardslash.chevron.right" })
    ]
  }))
})

globalThis.__cmuxAppExports = { renderInbox, renderStart, renderThread, projectCorpus }
