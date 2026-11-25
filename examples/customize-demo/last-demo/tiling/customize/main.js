// Tiling, redone: the showcase's numbered rows and status bar, the bar now a glass strip with
// the workspace name, tinted segments and a rolling clock, under a riced glass theme.
//
// Tiling: the window settings in this profile turn cmux into a scrolling tiling window manager
// (a column per terminal and browser, sideways scrolling, focus follows the mouse). This script
// adds the two things a tiling desktop has that cmux does not: numbered tags and a status bar.

// ---- Numbered workspaces --------------------------------------------------------------------
// The first nine rows get 1 to 9, the Command-number key that shows them; the rest get a dot.
const GLYPHS = ["1.circle", "2.circle", "3.circle", "4.circle", "5.circle", "6.circle", "7.circle", "8.circle", "9.circle"]

function numberRows() {
  const workspaces = cmux.live("workspace.list", {})
  return VStack([
    ForEach({ items: () => (workspaces() ?? []).map((w, i) => ({ ...w, index: i })), key: (w) => w.id }, (w) =>
      Group({
        row: () => w().id,
        icon: () => GLYPHS[w().index] ?? "circle.dotted",
        weight: () => (w().focused ? "bold" : "regular"),
        indicator: "dot"
      }, [])
    )
  ])
}

// ---- Status bar -------------------------------------------------------------------------------
const [now, setNow] = signal(Date.now())
const [focused, setFocused] = signal({ name: "", panes: 0, tabs: 0 })
const [agents, setAgents] = signal(0)

let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    const workspaces = await cmux.workspace.list({})
    const w = workspaces.find((x) => x.focused) || workspaces[0]
    if (w) {
      const [panes, tabs] = await Promise.all([cmux.pane.list({ workspace: w.id }), cmux.tab.list({ workspace: w.id })])
      setFocused({ name: w.name, panes: panes.length, tabs: tabs.length })
    }
    setAgents((await cmux.call("agent_chat.list", {})).chats.filter((c) => c.state === "working").length)
  } catch (e) {
    cmux.toast({ title: "Status bar cannot read cmux", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

const two = (n) => String(n).padStart(2, "0")
const clock = computed(() => {
  const d = new Date(now())
  return `${two(d.getHours())}:${two(d.getMinutes())}`
})

// A status bar like a tiling desktop's: the workspace as the lead line in the accent with the
// clock, then tinted segments (an icon in its tone, the count rolling when it changes).
function segment(symbol, text, tone) {
  return HStack({ spacing: 4 }, [
    Icon(symbol).font("caption").color(tone).symbolRendering("hierarchical"),
    Text(text).font("caption").weight("semibold").monospaced().contentTransition("numericText")
  ])
}

function renderBar() {
  load()
  for (const stream of ["workspace.changed", "pane.changed", "tab.changed", "agent_chat.changed"]) cmux.events.on(stream, load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return Panel({ style: "glass", spacing: 6 }, [
    HStack({ spacing: 6 }, [
      Icon("square.split.2x1.fill").font("caption").color(cmux.theme.accent),
      Text(() => focused().name || "Workspace").font("caption").weight("bold").lineLimit(1).truncation("tail"),
      Spacer(),
      Text(clock).font("caption").weight("semibold").monospaced().color(cmux.theme.accent).contentTransition("numericText")
    ]),
    HStack({ spacing: 12 }, [
      segment("square.grid.2x2.fill", () => `${focused().panes}`, cmux.theme.accent),
      segment("rectangle.stack.fill", () => `${focused().tabs}`, cmux.theme.success),
      segment("sparkles", () => `${agents()}`, () => (agents() ? cmux.theme.warning : cmux.theme.text.tertiary)),
      Spacer()
    ])
  ]).help(() => `${focused().name}: ${focused().panes} panes, ${focused().tabs} tabs; ${agents()} agents working`)
}

globalThis.__cmuxAppExports = { numberRows, renderBar }
