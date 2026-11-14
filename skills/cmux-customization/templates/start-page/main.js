// A start page of your own, the variant of the New Tab page you build yourself: a greeting
// and the time, buttons that open a chat, a terminal or a browser, the workspaces you have
// open and your PRs. It is the customize app's pane, so it opens as a tab with "Open My
// views" in the Command Palette, or from the Start row this app puts in the sidebar. Cmd-T
// still opens cmux's own New Tab page; there is no setting that swaps it for this one yet.
// Workspaces come from cmux.watch("workspace.list") (pushed, never polled) and PRs from
// cmux.watch("github.pulls") through your connected GitHub account. Clicks need actions:run
// (open) and workspace:write (show a workspace), in Settings > Apps > My views; the two reads
// (workspace:read, integration:github:read) are granted at install.

const [now, setNow] = signal(Date.now())

const two = (n) => String(n).padStart(2, "0")
const greeting = computed(() => {
  const h = new Date(now()).getHours()
  return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
})
const time = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})
const date = computed(() => {
  const d = new Date(now())
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
  return `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()}`
})

const message = (e) => (e instanceof Error ? e.message : String(e))
const refused = (what) => (e) => cmux.toast({ title: `Turn on ${what} for My views`, message: message(e), tone: "warning" })

// The same actions cmux's New Tab page runs for its New Chat, Terminal and Browser buttons.
const run = (id, args) => cmux.actions.run(id, args).catch(refused("Run actions"))
const launchers = [
  { title: "New chat", symbol: "bubble.left.and.text.bubble.right", id: "palette.newAgentChat" },
  { title: "Terminal", symbol: "terminal", id: "newSurface" },
  { title: "Browser", symbol: "globe", id: "openBrowser" }
]

const reviewing = (p) => p.roles.includes("review-requested")

function renderStart() {
  cmux.timer.every(15000, () => setNow(Date.now()))
  const workspaces = cmux.watch("workspace.list")
  const prs = cmux.watch("github.pulls", { roles: ["review-requested", "author"], limit: 5 })
  return VStack({ spacing: 12 }, [
    VStack({ spacing: 2 }, [
      Text(greeting).font("largeTitle").weight("semibold"),
      HStack({ spacing: 8 }, [Text(time).font("title2").monospaced(), Text(date).font("title3").color(cmux.theme.text.secondary)])
    ]),
    HStack({ spacing: 8 }, [...launchers.map((l) => Button(HStack({ spacing: 4 }, [Icon(l.symbol), Text(l.title)]), () => run(l.id))), Spacer()]),
    Panel({ title: "Jump back in", style: "card" }, [
      ForEach({ items: () => workspaces.value() ?? [], key: (w) => w.id }, (w) =>
        Row({
          title: () => w().name,
          symbol: () => (w().focused ? "rectangle.fill.on.rectangle.fill" : "rectangle.on.rectangle"),
          tint: () => (w().focused ? cmux.theme.accent : cmux.theme.text.secondary)
        }).onTap(() => cmux.workspace.focus({ workspace: w().id }).catch(refused("Change workspaces")))
      ),
      () => (workspaces.status() === "loading" ? ProgressView() : (workspaces.value() ?? []).length === 0 ? EmptyState({ title: "No workspaces yet", symbol: "rectangle.on.rectangle" }) : null)
    ]),
    Panel({ title: "Your PRs", style: "card" }, [
      ForEach({ items: () => [...(prs.value() ?? [])].sort((a, b) => Number(reviewing(b)) - Number(reviewing(a))), key: (p) => p.id }, (p) =>
        Row({
          title: () => p().title,
          subtitle: () => `${p().repo} · PR ${p().number}${reviewing(p()) ? " · waits for your review" : p().draft ? " · Draft" : ""}`,
          symbol: () => (reviewing(p()) ? "eye" : p().draft ? "circle.dashed" : "arrow.triangle.pull"),
          tint: () => (reviewing(p()) ? cmux.theme.warning : p().draft ? cmux.theme.text.secondary : cmux.theme.success)
        }).onTap(() => run("openBrowser", { url: p().url }))
      ),
      () => {
        if (prs.status() === "loading") return ProgressView()
        if (prs.status() === "error") return Text("Connect GitHub in Settings > Integrations to see your PRs.").font("caption").color(cmux.theme.text.secondary)
        return (prs.value() ?? []).length === 0 ? EmptyState({ title: "No open PRs", symbol: "checkmark.circle" }) : null
      }
    ])
  ])
}

function renderOpener() {
  return Row({ title: "Start page", symbol: "house" }).onTap(() => run("app.open", { app: "local/customize" }))
}

globalThis.__cmuxAppExports = { renderStart, renderOpener }
