// Muse: cmux as a Muse bot. The Muse home on every New Tab: a greeting, one prompt box that
// starts a Muse chat (the `muse` harness), and your recent Muse chats. One chat read per
// change (agent_chat.changed); nothing polls.

const HARNESS = "muse"
const [chats, setChats] = signal([])
const [now, setNow] = signal(Date.now())
const [draft, setDraft] = signal("")

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Muse`, message: message(e), tone: "warning" })
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

let following = false
function follow() {
  if (following) return
  following = true
  loadChats()
  cmux.events.on("agent_chat.changed", loadChats)
  cmux.timer.every(60_000, () => setNow(Date.now()))
}

const mine = (c) => String(c.harness || "").toLowerCase().startsWith(HARNESS)
const recents = computed(() =>
  chats()
    .filter(mine)
    .sort((a, b) => (b.updated_ms || b.created_ms || 0) - (a.updated_ms || a.created_ms || 0))
    .slice(0, 6)
)

function ago(ms) {
  if (!ms) return ""
  const s = Math.max(0, Math.round((now() - ms) / 1000))
  if (s < 60) return "just now"
  if (s < 3600) return `${Math.floor(s / 60)} min ago`
  if (s < 86400) return `${Math.floor(s / 3600)} h ago`
  return `${Math.floor(s / 86400)} d ago`
}

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function start(text) {
  const t = String(text ?? draft()).trim()
  run("palette.newAgentChat", t ? { harness: HARNESS, draft: t } : { harness: HARNESS })
  setDraft("")
}

const SUGGESTIONS = ["Explain this repo", "Plan a feature", "Review my diff"]

function renderHome() {
  follow()
  return VStack({ spacing: 18 }, [
    Spacer(),
    HStack({ spacing: 10 }, [
      Spacer(),
      Icon("task.ai").size(28).color(cmux.theme.accent),
      Text("What can Muse do for you?").font("largeTitle").weight("regular"),
      Spacer()
    ]),
    Panel({ style: "card" }, [
      TextField(draft, { placeholder: "Ask Muse anything", onEdit: setDraft, onSubmit: () => start() }).font("title3"),
      HStack({ spacing: 8 }, [
        Button("Model", () => run("agentPane.switchModel")),
        Spacer(),
        Button(HStack({ spacing: 4 }, [Icon("composer.send"), Text("Ask")]), () => start())
      ])
    ]),
    HStack({ spacing: 8 }, [Spacer(), ...SUGGESTIONS.map((s) => Button(s, () => start(s))), Spacer()]),
    Panel({ title: "Recent", style: "card" }, [
      ForEach({ items: recents, key: (c) => c.id }, (c) =>
        Row({
          title: () => c().title,
          subtitle: () => ago(c().updated_ms || c().created_ms),
          symbol: () => (c().state === "working" ? "status.inprogress" : c().state === "input" ? "status.needsinput" : "agent.chat"),
          tint: () => (c().state === "input" ? cmux.theme.warning : c().unread ? cmux.theme.accent : cmux.theme.text.secondary)
        }).onTap(() => show(c()))
      ),
      () => (recents().length ? null : EmptyState({ title: "No Muse chats yet", message: "Ask something above to start one.", symbol: "task.ai" }))
    ]),
    Spacer()
  ])
}

globalThis.__cmuxAppExports = { renderHome }
