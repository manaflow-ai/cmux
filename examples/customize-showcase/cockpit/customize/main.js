// Cockpit: the New Tab page becomes mission control, and the sidebar gets a Needs You section
// on top. Both read the same chat list: one read per change (agent_chat.changed), no polling.
// Workspaces and PRs come from cmux.watch, which the daemon pushes.

const [chats, setChats] = signal([])
const [now, setNow] = signal(Date.now())

let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    setChats((await cmux.call("agent_chat.list", {})).chats)
  } catch (e) {
    setChats([])
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for Cockpit`, message: message(e), tone: "warning" })
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))

const waiting = (c) => c.state === "input" || c.state === "failed" || c.state === "lost" || c.unread
const why = (c) => (c.state === "input" ? "asks you" : c.state === "failed" || c.state === "lost" ? "failed" : "done, unread")
const toneOf = (c) => (c.state === "input" ? cmux.theme.warning : c.state === "failed" || c.state === "lost" ? cmux.theme.danger : cmux.theme.success)
const symbolOf = (c) => (c.state === "input" ? "questionmark.bubble" : c.state === "failed" || c.state === "lost" ? "exclamationmark.circle" : "checkmark.circle")
const needsYou = computed(() => chats().filter(waiting))
const working = computed(() => chats().filter((c) => c.state === "working"))

function show(chat) {
  if (chat.workspace) cmux.workspace.focus({ workspace: chat.workspace }).catch(refused("Change workspaces"))
  else run("agent.openSessionTab", { session: chat.id })
}

function chatRow(c) {
  return Row({
    title: () => c().title,
    subtitle: () => `${c().project || "No folder"} · ${why(c())}`,
    symbol: () => symbolOf(c()),
    tint: () => toneOf(c())
  }).onTap(() => show(c()))
}

function follow() {
  load()
  cmux.events.on("agent_chat.changed", load)
}

const two = (n) => String(n).padStart(2, "0")
const clock = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})

function stat(label, value, tone) {
  return Panel({ style: "card" }, [Text(value).font("title").weight("semibold").monospaced().color(tone), Text(label).font("caption").color(cmux.theme.text.secondary)])
}

function renderCockpit() {
  follow()
  cmux.timer.every(15000, () => setNow(Date.now()))
  const workspaces = cmux.watch("workspace.list")
  const prs = cmux.watch("github.pulls", { roles: ["review-requested", "author"], limit: 6 })
  return VStack({ spacing: 14 }, [
    HStack({ spacing: 10 }, [Text("Cockpit").font("largeTitle").weight("semibold"), Spacer(), Text(clock).font("title2").monospaced().color(cmux.theme.text.secondary)]),
    HStack({ spacing: 10 }, [
      stat("need you", () => String(needsYou().length), () => (needsYou().length ? cmux.theme.warning : cmux.theme.text.secondary)),
      stat("working", () => String(working().length), cmux.theme.accent),
      stat("workspaces", () => String((workspaces.value() ?? []).length), cmux.theme.text.primary),
      stat("PRs", () => String((prs.value() ?? []).length), cmux.theme.success),
      Spacer()
    ]),
    HStack({ spacing: 8 }, [
      Button(HStack({ spacing: 4 }, [Icon("bubble.left.and.text.bubble.right"), Text("New chat")]), () => run("palette.newAgentChat")),
      Button(HStack({ spacing: 4 }, [Icon("terminal"), Text("Terminal")]), () => run("newSurface")),
      Button(HStack({ spacing: 4 }, [Icon("globe"), Text("Browser")]), () => run("openBrowser")),
      Spacer()
    ]),
    HStack({ spacing: 12 }, [
      Panel({ title: "Needs you", style: "card" }, [
        ForEach({ items: needsYou, key: (c) => c.id }, chatRow),
        () => (needsYou().length ? null : EmptyState({ title: "Nothing waits on you", symbol: "checkmark.seal" }))
      ]),
      Panel({ title: "Your PRs", style: "card" }, [
        ForEach({ items: () => prs.value() ?? [], key: (p) => p.id }, (p) =>
          Row({
            title: () => p().title,
            subtitle: () => `${p().repo} · PR ${p().number}${p().roles.includes("review-requested") ? " · your review" : ""}`,
            symbol: () => (p().roles.includes("review-requested") ? "eye" : "arrow.triangle.pull"),
            tint: () => (p().roles.includes("review-requested") ? cmux.theme.warning : cmux.theme.success)
          }).onTap(() => run("openBrowser", { url: p().url }))
        ),
        () => (prs.status() === "error" ? Text("Connect GitHub in Settings > Integrations to see your PRs.").font("caption").color(cmux.theme.text.secondary) : null)
      ])
    ]),
    Panel({ title: "Workspaces", style: "card" }, [
      ForEach({ items: () => workspaces.value() ?? [], key: (w) => w.id }, (w) =>
        Row({ title: () => w().name, symbol: "rectangle.on.rectangle", selected: () => w().focused }).onTap(() =>
          cmux.workspace.focus({ workspace: w().id }).catch(refused("Change workspaces"))
        )
      )
    ])
  ])
}

function renderNeedsYou() {
  follow()
  return VStack({ spacing: 1 }, [
    ForEach({ items: needsYou, key: (c) => c.id }, chatRow),
    () => (needsYou().length ? null : Text("Nothing waits on you").font("caption").color(cmux.theme.text.secondary).paddingHorizontal(10))
  ])
}

globalThis.__cmuxAppExports = { renderCockpit, renderNeedsYou }
