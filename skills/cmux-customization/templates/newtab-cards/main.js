// Cards: a whole New Tab page. One field that starts an agent chat, the folder the tab starts in
// and the agent the chat starts on as chips under it, then your three newest chats as cards (the
// folder, a status or the age, the title, what the chat does now). A click shows the chat.
//
// This was cmux's built-in "Cards" New Tab template. It no longer ships in Settings: it is now
// yours to edit. Install: copy this folder to the views folder from `cmux customize paths` (cmux reloads it on each
// save), then run `cmux settings set tabs.newTabApp local/customize`. To get cmux's own page
// back: `cmux settings unset tabs.newTabApp`.
//
// The field runs newTab.submit, the same table as cmux's own field: a prompt starts a chat, `!cmd`
// opens a terminal with the command typed, an address opens a browser. agent_chat:read is granted
// at install; turn on actions:run and workspace:write in Settings > Apps > My views for the clicks.

const [chats, setChats] = signal([])
const [draft, setDraft] = signal("")
const [agent, setAgent] = signal("") // "" is the default agent
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
const recent = computed(() => [...chats()].sort((a, b) => lastActivity(b) - lastActivity(a)).slice(0, 3))
const harnesses = computed(() => [...new Set(chats().map((c) => c.harness).filter(Boolean))].sort())
const folderName = (path) => String(path || "").replace(/\/+$/, "").split("/").pop() || path

function age(ms) {
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  return s < 60 ? "now" : s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d`
}

// A card's status slot: what needs you, in its tone; else the age.
function status(c) {
  if (c.state === "input") return { label: "Input", tone: "warning" }
  if (c.state === "failed" || c.state === "lost") return { label: "Failed", tone: "danger" }
  if (c.state === "working") return { label: "Working", tone: "secondary" }
  if (c.unread) return { label: "Done", tone: "success" }
  return { label: age(lastActivity(c)), tone: "tertiary" }
}

// Runs inside the click or Return, so the action gets that gesture.
function send(text) {
  const prompt = String(text ?? draft()).trim()
  if (!prompt) return
  cmux.actions.run("newTab.submit", agent() ? { text: prompt, agent: agent() } : { text: prompt }).then(() => setDraft(""), refused("Run actions"))
}

function open(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else cmux.actions.run("agent.openSessionTab", { session: chat.id }).catch(refused("Run actions"))
}

function card(chat) {
  return Panel({ style: "card" }, [
    HStack({ spacing: 6 }, [
      Text(() => chat().project || "No folder").font("caption").color("secondary").lineLimit(1),
      Spacer(),
      Text(() => status(chat()).label).font("caption").color(() => status(chat()).tone)
    ]),
    Text(() => chat().title).font("headline").lineLimit(2),
    Text(() => chat().step || chat().error || "").font("caption").color("tertiary").lineLimit(1)
  ])
    .help(() => [chat().title, chat().cwd, chat().harness].filter(Boolean).join("\n"))
    .cursor("pointer")
    .onTap(() => open(chat()))
    .contextMenu([Button("Open Chat in New Tab", () => cmux.actions.run("agent.openSessionTab", { session: chat().id }).catch(refused("Run actions")))])
}

function renderNewTab(context) {
  const cwd = context && context.cwd
  load()
  cmux.events.on("agent_chat.changed", load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return VStack({ spacing: 16 }, [
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask an agent, or type ! for a command", autofocus: true, onEdit: setDraft, onSubmit: send, onCancel: () => setDraft("") }),
      HStack({ spacing: 8 }, [
        cwd ? Badge(folderName(cwd)).help(cwd) : null,
        () => Menu(agent() || "Default agent", [Button("Default agent", () => setAgent("")), Divider(), ...harnesses().map((h) => Button(h, () => setAgent(h)))]),
        Spacer(),
        Button("Start", () => send())
      ])
    ]),
    HStack({ spacing: 8 }, [Text("Chats").font("headline"), Spacer(), Button("All Chats", () => cmux.actions.run("search.chats").catch(refused("Run actions")))]),
    HStack({ spacing: 12 }, [ForEach({ items: recent, key: (c) => c.id }, card)]),
    () =>
      error()
        ? EmptyState({ title: "Cannot read your chats", message: error(), symbol: "exclamationmark.triangle" })
        : chats().length === 0
          ? EmptyState({ title: "No chats yet", message: "Type a prompt above to start one.", symbol: "bubble.left" })
          : null
  ])
}

globalThis.__cmuxAppExports = { renderNewTab }
