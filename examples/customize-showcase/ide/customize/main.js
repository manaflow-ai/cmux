// IDE: an Explorer for the workspace you are in, the way an editor lists its open editors by
// group: each pane, then its tabs, the focused one selected. The profile's settings do the rest
// (vertical tabs, every new terminal a split, links beside the code, chats with tool output).

const [view, setView] = signal(null) // { workspace, panes: [{ pane, tabs }] }
const [error, setError] = signal(null)

const symbolOf = (kind) => (kind === "browser" ? "globe" : kind === "conversation" ? "bubble.left" : "terminal")
const warn = (what) => (e) => cmux.toast({ title: what, message: e instanceof Error ? e.message : String(e), tone: "warning" })

let reading = false
let again = false
async function load() {
  if (reading) return void (again = true)
  reading = true
  try {
    const workspaces = await cmux.workspace.list({})
    const workspace = workspaces.find((w) => w.focused) || workspaces[0] || null
    if (!workspace) return void setView(null)
    const [panes, tabs] = await Promise.all([cmux.pane.list({ workspace: workspace.id }), cmux.tab.list({ workspace: workspace.id })])
    setView({ workspace, panes: panes.map((pane, index) => ({ pane, index, tabs: tabs.filter((t) => t.pane_id === pane.id).sort((a, b) => a.index - b.index) })) })
    setError(null)
  } catch (e) {
    setError(e instanceof Error ? e.message : String(e))
  } finally {
    reading = false
    if (again) {
      again = false
      load()
    }
  }
}

function focusedPane() {
  const v = view()
  return v && (v.panes.find((p) => p.pane.focused) || v.panes[0])
}

function renderExplorer() {
  load()
  for (const stream of ["workspace.changed", "pane.changed", "tab.changed"]) cmux.events.on(stream, load)
  return VStack({ spacing: 2 }, [
    HStack({ spacing: 6 }, [
      Text(() => (view() ? view().workspace.name : "")).font("headline").lineLimit(1),
      Spacer(),
      Menu("New", [
        Button("Terminal", () => cmux.actions.run("newSurface").catch(warn("Turn on Run actions for IDE"))),
        Button("Browser", () => cmux.actions.run("openBrowser").catch(warn("Turn on Run actions for IDE"))),
        Divider(),
        Button("Split Right", () => {
          const p = focusedPane()
          if (p) cmux.pane.split({ pane: p.pane.id, direction: "right" }).catch(warn("Turn on Change workspaces for IDE"))
        }),
        Button("Split Down", () => {
          const p = focusedPane()
          if (p) cmux.pane.split({ pane: p.pane.id, direction: "down" }).catch(warn("Turn on Change workspaces for IDE"))
        })
      ])
    ]),
    ForEach({ items: () => (view() ? view().panes : []), key: (p) => p.pane.id }, (p) =>
      VStack({ spacing: 1 }, [
        Text(() => `Group ${p().index + 1}`).font("caption").weight("medium").color("secondary"),
        ForEach({ items: () => p().tabs, key: (t) => t.id }, (t) =>
          Row({ title: () => t().name || t().content_kind, symbol: () => symbolOf(t().content_kind), selected: () => t().focused }).onTap(() =>
            cmux.tab.focus({ tab: t().id }).catch(warn("Turn on Change workspaces for IDE"))
          )
        )
      ])
    ),
    () => (error() ? EmptyState({ title: "Cannot read the workspace", message: error(), symbol: "exclamationmark.triangle" }) : null)
  ])
}

globalThis.__cmuxAppExports = { renderExplorer }
