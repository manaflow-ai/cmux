// Calm: a whole New Tab page. The field sits at the foot of the page; over it, centered in the
// free space, the folder the tab starts in, the chats that need you (a question, a failure, a
// finished turn nobody has read) and your five newest chats as quiet rows. A click shows the chat.
// The pane's other actions stay in the Command Palette and the toolbar, not on the page.
//
// This was cmux's built-in "Calm" New Tab template (the "default" id). It no longer ships in
// Settings: it is now yours to edit. Install: copy this folder to ~/.config/cmux/customize (cmux
// reloads it on each save), then run `cmux settings set tabs.newTabApp local/customize`. To get
// cmux's own page back: `cmux settings unset tabs.newTabApp`.
//
// Left out: the built-in's environment card picked the folder a chat starts in. newTab.submit,
// the action that starts a chat with a prompt, takes no folder, so the folder here is shown only.
// The field reads like cmux's own: a prompt starts a chat, `!cmd` a terminal, an address a browser.
// agent_chat:read is granted at install; turn on actions:run and workspace:write in
// Settings > Apps > My views for the clicks.

const [chats, setChats] = signal([])
const [draft, setDraft] = signal("")
const [now, setNow] = signal(Date.now())
const [error, setError] = signal(null)

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for My views`, message: message(e), tone: "warning" })

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
const needsYou = (c) => c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread
const newest = computed(() => [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a)))
const attention = computed(() => newest().filter(needsYou))
const recent = computed(() => newest().filter((c) => !needsYou(c)).slice(0, 5))
const folderName = (path) => String(path || "").replace(/\/+$/, "").split("/").pop() || path

function age(ms) {
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  return s < 60 ? "now" : s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d`
}

function why(c) {
  if (c.state === "input") return { label: "Waiting for you", symbol: "questionmark.bubble", tone: cmux.theme.warning }
  if (c.state === "failed" || c.state === "lost") return { label: "Failed", symbol: "exclamationmark.circle", tone: cmux.theme.danger }
  return { label: "Done", symbol: "checkmark.circle", tone: cmux.theme.success }
}

// Runs inside Return, so the action gets that gesture.
function send(text) {
  const prompt = String(text ?? draft()).trim()
  if (!prompt) return
  cmux.actions.run("newTab.submit", { text: prompt }).then(() => setDraft(""), refused("Run actions"))
}

function open(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else cmux.actions.run("agent.openSessionTab", { session: chat.id }).catch(refused("Run actions"))
}

const quietRow = (chat) =>
  Row({ title: () => chat().title, subtitle: () => `${chat().project || "No folder"} · ${age(lastActivity(chat()))}`, symbol: "bubble.left", tint: cmux.theme.text.tertiary })
    .help(() => chat().cwd || "")
    .onTap(() => open(chat()))

const attentionRow = (chat) =>
  Row({ title: () => chat().title, subtitle: () => why(chat()).label, symbol: () => why(chat()).symbol, tint: () => why(chat()).tone }).onTap(() => open(chat()))

function renderNewTab(context) {
  const cwd = context && context.cwd
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return VStack({ spacing: 12 }, [
    Spacer(),
    cwd ? Panel({ style: "card" }, [Row({ title: folderName(cwd), subtitle: cwd, symbol: "folder", tint: cmux.theme.text.secondary })]) : null,
    () => (attention().length ? Panel({ title: "Needs you", style: "card" }, [ForEach({ items: attention, key: (c) => c.id }, attentionRow)]) : null),
    () => (recent().length ? Panel({ title: "Recent", style: "card" }, [ForEach({ items: recent, key: (c) => c.id }, quietRow)]) : null),
    () => (error() ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" }) : null),
    Spacer(),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "What should we work on?", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") })
    ])
  ])
}

globalThis.__cmuxAppExports = { renderNewTab }
