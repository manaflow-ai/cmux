// The builder new-chat page, as a New Tab page you opt into (cmux.newtab/1, tabs.newTabApp).
// One quiet line centered in the page, "What should we build in {project}?", with the project's
// name a picker, and "What should we build?" with a folder picker under it when the tab has no
// folder. Under the line, only when there are any, the chats that wait on you. The field sits at
// the foot of the page: a prompt starts a chat in this tab's folder, `!cmd` a terminal, an address
// a browser (newTab.submit, as cmux's own field).
//
// Not the chat itself: cmux's new chat stays plain. This page is here because someone installed
// it (Leo, 2026-11-22: "if we want it as a proper option then we shouldnt have things be in
// disparate places").
//
// The project pick: newTab.submit takes no folder, and a page cannot move its own tab's folder, so
// a pick starts a new chat in the picked folder (palette.newAgentChat with cwd) instead of moving
// this page's prompt there. README.md lists what is missing.

const [source, setSource] = signal(null)
const [draft, setDraft] = signal("")
const [cwd, setCwd] = signal(null)

const chats = computed(() => (source() && source()()) || [])
const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Reference send`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

const trimmed = (path) => String(path || "").replace(/\/+$/, "")
const folderName = (path) => trimmed(path).split("/").pop() || path
const changed = (c) => Math.max(Number(c.updated_ms) || 0, Number(c.since_ms) || 0, Number(c.created_ms) || 0)
const chatKey = (c) => JSON.stringify([c.machine || "", c.id])

// The folders your chats ran in, newest first, one row each, at most eight; this tab's own first.
const projects = computed(() => {
  const seen = new Set()
  const here = trimmed(cwd())
  const out = []
  for (const c of [...chats()].sort((a, b) => changed(b) - changed(a))) {
    const path = trimmed(c.cwd)
    const key = JSON.stringify([c.machine || "", path])
    if (!path || path === here || seen.has(key)) continue
    seen.add(key)
    out.push({ path, machine: c.machine || null })
  }
  return out.slice(0, 8)
})

// HomeLists' inbox: the chats that ask something of you.
const waiting = computed(() =>
  chats()
    .filter((c) => !c.archived && (c.state === "input" || c.state === "failed" || c.state === "lost"))
    .sort((a, b) => changed(b) - changed(a))
    .slice(0, 5)
)

function pick(project) {
  run("palette.newAgentChat", { cwd: project.path, ...(project.machine ? { host: project.machine } : {}) })
}

const pickerItems = () => [
  ...projects().map((p) => Button(p.machine ? `${folderName(p.path)} (${p.machine})` : folderName(p.path), () => pick(p))),
  projects().length ? Divider() : null,
  Button("Open Folder…", () => run("openFolder"))
].filter(Boolean)

// Runs inside Return, so the action gets that gesture.
function send(text) {
  const prompt = String(text ?? draft()).trim()
  if (!prompt) return
  cmux.actions.run("newTab.submit", { text: prompt }).then(() => setDraft(""), refused("Run actions"))
}

function open(chat) {
  if (chat.workspace && !chat.machine) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id, ...(chat.machine ? { host: chat.machine } : {}) })
}

const TITLE = 20

function question() {
  const here = cwd()
  if (here)
    return HStack({ spacing: 0 }, [
      Text("What should we build in ").font(TITLE),
      Menu(folderName(here), pickerItems).font(TITLE).help(here),
      Text("?").font(TITLE)
    ])
  return VStack({ spacing: 14 }, [
    Text("What should we build?").font(TITLE),
    Menu("Choose a folder", pickerItems).secondary()
  ])
}

const waitingRow = (chat) =>
  Row({
    title: () => chat().title || "Untitled chat",
    subtitle: () => [chat().state === "input" ? "Waiting for you" : "Failed", chat().project].filter(Boolean).join(" · "),
    symbol: () => (chat().state === "input" ? "questionmark.bubble" : "exclamationmark.circle"),
    tint: () => (chat().state === "input" ? cmux.theme.warning : cmux.theme.danger)
  }).onTap(() => open(chat()))

function renderBuilder(context) {
  setCwd((context && context.cwd) || null)
  const live = cmux.live("chat.list", {})
  setSource(() => live) // a function: passing the live itself would run it as an updater
  return VStack({ spacing: 14 }, [
    Spacer(),
    question(),
    Spacer(),
    () =>
      waiting().length
        ? Panel({ title: "Needs you", style: "card" }, [ForEach({ items: waiting, key: chatKey }, waitingRow)]).frame({ maxWidth: 760 })
        : null,
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask anything", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") })
    ]).frame({ maxWidth: 760 })
  ]).padding(24)
}

globalThis.__cmuxAppExports = { renderBuilder }
