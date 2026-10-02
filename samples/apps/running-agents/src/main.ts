/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Running Agents: a sidebar section listing every agent, grouped by state.

type Agent = Cmux.AgentSnapshot

/** Shows the tab that hosts an agent's terminal (user-initiated: called from a tap). */
async function focusTerminal(terminal: string) {
  const t = await cmux.terminal.get({ terminal })
  if (t.tab_id) await cmux.tab.focus({ tab: t.tab_id })
}

const GROUPS: Array<{ state: string; title: string; symbol: string; tone: string }> = [
  { state: "blocked", title: "Waiting for you", symbol: "exclamationmark.bubble", tone: "warning" },
  { state: "working", title: "Working", symbol: "circle.dotted", tone: "accent" },
  { state: "idle", title: "Idle", symbol: "moon", tone: "secondary" },
  { state: "done", title: "Done", symbol: "checkmark.circle", tone: "success" }
]

const label = (a: Agent) => {
  const extra = (a.extra ?? {}) as Record<string, unknown>
  return String(extra.name ?? extra.title ?? a.source_session ?? a.source)
}

const since = (ms: string | number) => {
  const minutes = Math.max(0, Math.round((Date.now() - Number(ms)) / 60000))
  return minutes < 1 ? "now" : minutes < 60 ? `${minutes}m` : `${Math.round(minutes / 60)}h`
}

export function renderAgents() {
  const agents = cmux.live<Agent[]>("agent.list", {})
  const visible = computed(() => {
    const showIdle = cmux.app.settings().showIdle !== false
    return (agents() ?? []).filter((a) => showIdle || (a.state !== "idle" && a.state !== "done"))
  })
  const rows = computed(() => {
    const out: Array<{ key: string; header?: (typeof GROUPS)[number]; agent?: Agent; count?: number }> = []
    for (const g of GROUPS) {
      const members = visible().filter((a) => a.state === g.state)
      if (!members.length) continue
      out.push({ key: `h:${g.state}`, header: g, count: members.length })
      for (const a of members) out.push({ key: a.id, agent: a })
    }
    return out
  })
  return VStack({ spacing: 2 }, [
    ForEach({ items: rows, key: (r) => r.key }, (r) =>
      r().header
        ? HStack({ spacing: 6 }, [
            Text(() => r().header!.title).font("caption").secondary(),
            Spacer(),
            Badge(() => r().count ?? 0, () => r().header!.tone)
          ]).paddingHorizontal(8).paddingVertical(2)
        : Row({
            title: () => label(r().agent!),
            subtitle: () => `${r().agent!.state} · ${since(r().agent!.updated_at_ms)}`,
            symbol: () => GROUPS.find((g) => g.state === r().agent!.state)?.symbol ?? "circle",
            tint: () => GROUPS.find((g) => g.state === r().agent!.state)?.tone ?? "secondary",
            unread: () => r().agent!.state === "blocked"
          })
            .onTap(() => focusTerminal(r().agent!.terminal_id))
            .contextMenu([Button("Focus Terminal", () => focusTerminal(r().agent!.terminal_id))])
    ),
    () => (agents.loading() || visible().length ? null : EmptyState({ title: "No agents running", symbol: "sparkles" }))
  ])
}
