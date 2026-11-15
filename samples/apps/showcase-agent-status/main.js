// Agent status in one glance; tapping a row jumps to its terminal.
async function focus(terminal) {
  try {
    const gesture = cmux.gesture() ?? undefined
    const tab = await cmux.terminal.get({ terminal })
    if (tab.tab_id) await cmux.tab.focus({ tab: tab.tab_id }, { gesture })
  } catch (e) { cmux.toast({ title: "Cannot focus agent", message: e instanceof Error ? e.message : String(e), tone: "warning" }) }
}
function name(agent) {
  const extra = agent.extra || {}
  return String(extra.name || extra.title || agent.source_session || agent.source)
}
function renderStatus() {
  const agents = cmux.live("agent.list", {})
  const visible = computed(() => (agents() || []).filter((a) => a.state === "working" || a.state === "blocked"))
  return VStack({ spacing: 2 }, [
    ForEach({ items: visible, key: (agent) => agent.id }, (agent) => Row({
      title: () => name(agent()), subtitle: () => agent().state, symbol: () => agent().state === "blocked" ? "exclamationmark.bubble" : "sparkles",
      tint: () => agent().state === "blocked" ? "warning" : "accent", unread: () => agent().state === "blocked"
    }).onTap(() => focus(agent().terminal_id))),
    () => agents.error() ? EmptyState({ title: "Cannot read agents", message: agents.error().message, symbol: "exclamationmark.triangle" }) : agents.loading() || visible().length ? null : EmptyState({ title: "No active agents", symbol: "sparkles" })
  ])
}
globalThis.__cmuxAppExports = { renderStatus }
