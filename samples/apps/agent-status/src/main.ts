/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Agent Status: "2 working · 1 waiting" with a menu of the agents.

type Agent = Cmux.AgentSnapshot

/** Shows the tab that hosts an agent's terminal (user-initiated: called from a tap). */
async function focusTerminal(terminal: string) {
  const t = await cmux.terminal.get({ terminal })
  if (t.tab_id) await cmux.tab.focus({ tab: t.tab_id })
}

export function renderStatus() {
  const agents = cmux.live<Agent[]>("agent.list", {})
  const working = computed(() => (agents() ?? []).filter((a) => a.state === "working").length)
  const waiting = computed(() => (agents() ?? []).filter((a) => a.state === "blocked").length)
  const summary = computed(() => {
    const parts: string[] = []
    if (working()) parts.push(`${working()} working`)
    if (waiting()) parts.push(`${waiting()} waiting`)
    return parts.join(" · ") || "No agents"
  })
  const menu = () =>
    (agents() ?? [])
      .filter((a) => a.state === "working" || a.state === "blocked")
      .map((a) => Button(`${a.state === "blocked" ? "Waiting" : "Working"}: ${String((a.extra as Record<string, unknown> | undefined)?.name ?? a.source)}`, () => focusTerminal(a.terminal_id)))
  return HStack({ spacing: 4 }, [
    Icon(() => (waiting() ? "exclamationmark.bubble" : "sparkles")).color(() => (waiting() ? "warning" : "secondary")),
    Text(summary).font("caption").monospaced(),
    () => (waiting() ? Badge(waiting, "warning") : null)
  ])
    .paddingHorizontal(6)
    .cornerRadius(6)
    .hoverBackground("hover")
    .contextMenu(menu)
}
