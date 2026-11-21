// Threads: a whole New Tab page. One field at the top that starts an agent chat, then every chat
// as a list, newest first (its status, folder and age under the title), then Recently Closed.
// A click shows the chat; its menu opens it in a new tab.
//
// This was cmux's built-in "Threads" New Tab template. It no longer ships in Settings: it is now
// yours to edit. Install: copy this folder to ~/.config/cmux/customize (cmux reloads it on each
// save), then run `cmux settings set tabs.newTabApp local/customize`. To get cmux's own page
// back: `cmux settings unset tabs.newTabApp`.
//
// Left out: the built-in listed your recently closed tabs on the page. No app API reads that
// list, so here a "Recently Closed…" button opens cmux's own list (the recentlyClosed action).
// The field reads like cmux's own: a prompt starts a chat, `!cmd` a terminal, an address a browser.
// agent_chat:read is granted at install; turn on actions:run and workspace:write in
// Settings > Apps > My views for the clicks.

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

function status(c) {
  if (c.state === "input") return { label: "Input", symbol: "questionmark.bubble", tone: cmux.theme.warning }
  if (c.state === "failed" || c.state === "lost") return { label: "Failed", symbol: "exclamationmark.circle", tone: cmux.theme.danger }
  if (c.state === "working") return { label: "Working", symbol: "circle.dashed", tone: cmux.theme.text.secondary }
  if (c.unread) return { label: "Done", symbol: "checkmark.circle", tone: cmux.theme.success }
  return { label: age(lastActivity(c)), symbol: "bubble.left", tone: cmux.theme.text.tertiary }
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

const thread = (chat) =>
  Row({
    title: () => chat().title,
    subtitle: () => [status(chat()).label, chat().project || "No folder", chat().harness].filter(Boolean).join(" · "),
    symbol: () => status(chat()).symbol,
    tint: () => status(chat()).tone
  })
    .help(() => [chat().step, chat().cwd].filter(Boolean).join("\n"))
    .onTap(() => open(chat()))
    .contextMenu([Button("Open Chat in New Tab", () => run("agent.openSessionTab", { session: chat().id }))])

function renderNewTab() {
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return VStack({ spacing: 12 }, [
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Start a thread", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") })
    ]),
    Panel({ title: () => `All chats · ${chats().length}`, style: "card" }, [
      ForEach({ items: all, key: (c) => c.id }, thread),
      () =>
        error()
          ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
          : chats().length === 0
            ? EmptyState({ title: "No chats yet", message: "Type a prompt above to start one.", symbol: "bubble.left" })
            : null
    ]),
    HStack({ spacing: 8 }, [Button(HStack({ spacing: 4 }, [Icon("clock.arrow.circlepath"), Text("Recently Closed…")]), () => run("recentlyClosed")), Spacer()])
  ])
}

globalThis.__cmuxAppExports = { renderNewTab }
