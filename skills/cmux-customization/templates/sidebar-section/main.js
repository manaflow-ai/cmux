// A sidebar section that follows the workspace you are in: its name and its tabs, the
// focused tab selected. It reads with workspace:read (granted at install) and redraws on
// every workspace or tab change. A click focuses the tab once workspace:write is on in
// Settings > Apps > My views.

const [view, setView] = signal(null) // { workspace, tabs } of the focused workspace
const [error, setError] = signal(null)

const symbolOf = (kind) => (kind === "browser" ? "globe" : kind === "conversation" ? "bubble.left" : "terminal")

// A burst of change events costs at most two reads: one running, one after it.
let reading = false
let again = false
async function load() {
  if (reading) {
    again = true
    return
  }
  reading = true
  try {
    const workspaces = await cmux.workspace.list({})
    const workspace = workspaces.find((w) => w.focused) || workspaces[0] || null
    const tabs = workspace ? await cmux.tab.list({ workspace: workspace.id }) : []
    setView({ workspace, tabs })
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

async function focus(tab) {
  try {
    await cmux.tab.focus({ tab: tab.id })
  } catch (e) {
    cmux.toast({ title: "Cannot focus the tab", message: e instanceof Error ? e.message : String(e), tone: "warning" })
  }
}

function renderWorkspace() {
  load()
  for (const stream of ["workspace.changed", "tab.changed"]) cmux.events.on(stream, load)
  const tabs = computed(() => (view() ? view().tabs : []))
  return VStack({ spacing: 2 }, [
    Text(() => (view() && view().workspace ? view().workspace.name : "")).font("headline"),
    ForEach({ items: tabs, key: (t) => t.id }, (t) =>
      Row({
        title: () => t().name || t().content_kind,
        symbol: () => symbolOf(t().content_kind),
        selected: () => t().focused
      }).onTap(() => focus(t()))
    ),
    () => (error() ? EmptyState({ title: "Cannot read the workspace", message: error(), symbol: "exclamationmark.triangle" }) : null)
  ])
}

globalThis.__cmuxAppExports = { renderWorkspace }
