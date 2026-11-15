// Follow the current workspace. Saving this file reloads the section.
function renderTabs() {
  const [view, setView] = signal(null)
  const [error, setError] = signal(null)
  let active = true, reading = false, again = false
  async function load() {
    if (!active) return
    if (reading) { again = true; return }
    reading = true
    try {
      const spaces = await cmux.workspace.list({})
      if (!active) return
      const workspace = spaces.find((space) => space.focused)
      const tabs = workspace ? await cmux.tab.list({ workspace: workspace.id }) : []
      if (active) { setView({ workspace, tabs }); setError(null) }
    } catch (failure) {
      if (active) setError(String(failure))
    } finally {
      reading = false
      if (active && again) { again = false; load() }
    }
  }
  onCleanup(() => { active = false })
  cmux.events.on("workspace.changed", load)
  cmux.events.on("tab.changed", load)
  load()
  const warn = (error) => cmux.toast({ title: "Cannot focus tab", message: String(error), tone: "warning" })
  return VStack([
    Text(() => view()?.workspace?.name || "This workspace").font("headline"),
    ForEach({ items: computed(() => view()?.tabs || []), key: (tab) => tab.id }, (tab) =>
      Row({
        title: () => tab().name || tab().content_kind,
        symbol: () => tab().content_kind === "browser" ? "globe" : tab().content_kind === "conversation" ? "bubble.left" : "terminal",
        selected: () => tab().focused
      }).onTap(() => cmux.tab.focus({ tab: tab().id }).catch(warn))
    ),
    () => error() ? EmptyState({ title: "Cannot read workspace", message: error() }) : null,
    () => !error() && !view() ? EmptyState({ title: "Loading workspace…" }) : null,
    () => view() && !error() && !view().tabs.length ? EmptyState({ title: view().workspace ? "No tabs here yet" : "No focused workspace" }) : null
  ])
}

globalThis.__cmuxAppExports = { renderTabs }
