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

function segment(symbol, text) {
  return HStack({ spacing: 3 }, [Icon(symbol).color("secondary"), Text(text).font("caption").monospaced()])
}

function renderBar() {
  load()
  for (const stream of ["workspace.changed", "pane.changed", "tab.changed", "agent_chat.changed"]) cmux.events.on(stream, load)
  cmux.timer.every(30000, () => setNow(Date.now()))
  return HStack({ spacing: 10 }, [
    segment("square.grid.2x2", () => `${focused().panes}`),
    segment("rectangle.stack", () => `${focused().tabs}`),
    segment("sparkles", () => `${agents()}`),
    Spacer(),
    Text(clock).font("caption").weight("semibold").monospaced()
  ]).help(() => `${focused().name}: ${focused().panes} panes, ${focused().tabs} tabs; ${agents()} agents working`)
}

globalThis.__cmuxAppExports = { numberRows, renderBar }
