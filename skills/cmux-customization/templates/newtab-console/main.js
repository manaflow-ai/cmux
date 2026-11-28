// Console: a whole New Tab page in monospace. A `>` prompt that starts an agent chat, then every
// chat as one line, newest first (its state, title, folder and age), then Recently Closed.
// A click on a line shows the chat; its menu opens it in a new tab.
//
// This was cmux's built-in "Console" New Tab template. It no longer ships in Settings: it is now
// yours to edit. Install: copy this folder to the views folder from `cmux customize paths` (cmux reloads it on each
// save), then run `cmux settings set tabs.newTabApp local/customize`. To get cmux's own page
// back: `cmux settings unset tabs.newTabApp`.
//
// Left out: the built-in listed your recently closed tabs on the page. No app API reads that
// list, so here a "recently closed…" line opens cmux's own list (the recentlyClosed action).
// The prompt reads like cmux's own field: a prompt starts a chat, `!cmd` opens a terminal with
// the command typed, an address opens a browser. agent_chat:read is granted at install; turn on
// actions:run and workspace:write in Settings > Apps > My views for the clicks.

const [chats, setChats] = signal([])
const [draft, setDraft] = signal("")
const [now, setNow] = signal(Date.now())
const [error, setError] = signal(null)

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for My views`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

// One read at a time; a change during a read reads once more after it.
let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    setChats((await cmux.call("agent_chat.list", {})).chats)
    setNow(Date.now())
    setError(null)
  } catch (e) {
    setError(message(e))
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

const lastActivity = (c) => Math.max(c.updated_ms || 0, c.since_ms || 0, c.created_ms || 0)
const all = computed(() => [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a)))

function age(ms) {
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  return s < 60 ? "now" : s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d`
}

// The state tag at the start of a line, and its tone.
function tag(c) {
  if (c.state === "input") return { text: "[input]", tone: "warning" }
  if (c.state === "failed" || c.state === "lost") return { text: "[fail] ", tone: "danger" }
  if (c.state === "working") return { text: "[run]  ", tone: "secondary" }
  if (c.unread) return { text: "[done] ", tone: "success" }
  return { text: "[idle] ", tone: "tertiary" }
}

// Runs inside Return, so the action gets that gesture.
function send(text) {
  const prompt = String(text ?? draft()).trim()
  if (!prompt) return
  cmux.actions.run("newTab.submit", { text: prompt }).then(() => setDraft(""), refused("Run actions"))
}

function open(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

const line = (chat) =>
  HStack({ spacing: 8 }, [
    Text(() => tag(chat()).text).monospaced().color(() => tag(chat()).tone),
    Text(() => chat().title).monospaced().lineLimit(1).truncation("tail"),
    Spacer(),
    Text(() => chat().project || "-").font("caption").monospaced().color("secondary").lineLimit(1),
    Text(() => age(lastActivity(chat()))).font("caption").monospaced().color("tertiary").fixedSize("horizontal")
  ])
    .hoverBackground("hover")
    .cursor("pointer")
    .help(() => [chat().step, chat().cwd, chat().harness].filter(Boolean).join("\n"))
    .onTap(() => open(chat()))
    .contextMenu([Button("Open Chat in New Tab", () => run("agent.openSessionTab", { session: chat().id }))])

function renderNewTab() {
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return VStack({ spacing: 12 }, [
    Panel({ style: "card" }, [
      HStack({ spacing: 8 }, [
        Text(">").font("headline").monospaced().color("accent"),
        TextField(draft, { placeholder: "ask an agent, !command, or an address", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") }).monospaced()
      ])
    ]),
    Panel({ title: () => `chats (${chats().length})`, style: "card" }, [
      ForEach({ items: all, key: (c) => c.id }, line),
      () =>
        error()
          ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
          : chats().length === 0
            ? EmptyState({ title: "No chats yet", message: "Type a prompt after > to start one.", symbol: "terminal" })
            : null
    ]),
    HStack({ spacing: 8 }, [
      Text("recently closed…").monospaced().color("secondary").hoverBackground("hover").cursor("pointer").onTap(() => run("recentlyClosed")),
      Spacer()
    ])
  ])
}

globalThis.__cmuxAppExports = { renderNewTab }
