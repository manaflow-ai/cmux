/// <reference path="../../../../cmux-tui/crates/cmux-app-host/generated/cmux-app.d.ts" />
// Priority View, as an app: the agents that need you first, built only from public primitives
// (cmux.live, the scene DSL, a tap gesture). It replaces nothing in the native sidebar; it shows
// what the native `sidebar.priorityView.*` feature would look like as a `cmux.section/1` app.
// Spec: plans/cmux-next/extensibility-DESIGN.md, "First example: Priority View".

type Agent = Cmux.AgentSnapshot

/** The native tiers (AgentPriorityRanking.tier), mapped onto the states `agent.list` has today. */
const TIERS: Array<{ state: Cmux.AgentState; title: string; symbol: string; tone: string }> = [
  { state: "blocked", title: "Needs you", symbol: "exclamationmark.bubble", tone: "warning" },
  { state: "done", title: "Finished", symbol: "checkmark.circle", tone: "success" },
  { state: "working", title: "Working", symbol: "circle.dotted", tone: "accent" },
  { state: "idle", title: "Idle", symbol: "moon", tone: "secondary" }
]

const tier = (state: Cmux.AgentState) => {
  const index = TIERS.findIndex((t) => t.state === state)
  return index < 0 ? TIERS.length : index
}

const label = (a: Agent) => {
  const extra = (a.extra ?? {}) as Record<string, unknown>
  return String(extra.name ?? extra.title ?? a.source_session ?? a.source)
}

/** Ranks agents: tier first, then the most recent change first. Pure, so a test can call it. */
export function rank(agents: Agent[], showIdle: boolean): Agent[] {
  return agents
    .filter((a) => showIdle || a.state !== "idle")
    .slice()
    .sort((a, b) => tier(a.state) - tier(b.state) || Number(b.updated_at_ms) - Number(a.updated_at_ms))
}

/** Shows the tab of an agent's terminal; only in answer to a tap (the gesture token). */
async function focusTerminal(terminal: string) {
  const gesture = cmux.gesture() ?? undefined
  const t = await cmux.terminal.get({ terminal })
  if (t.tab_id) await cmux.tab.focus({ tab: t.tab_id }, { gesture })
}

export function renderPriority() {
  // One live read; it re-reads only on agent.changed (no timer), and the keyed ForEach sends
  // an `update` op only for the row whose props changed.
  const agents = cmux.live<Agent[]>("agent.list", {})
  const ranked = computed(() => rank(agents() ?? [], cmux.app.settings().showIdle === true))
  const style = (a: Agent) => TIERS[tier(a.state)] ?? TIERS[TIERS.length - 1]!
  return VStack({ spacing: 2 }, [
    ForEach({ items: ranked, key: (a) => a.id }, (a) =>
      Row({
        title: () => label(a()),
        subtitle: () => style(a()).title,
        symbol: () => style(a()).symbol,
        tint: () => style(a()).tone,
        unread: () => a().state === "blocked" || a().state === "done"
      }).onTap(() => focusTerminal(a().terminal_id))
    ),
    () => (agents.loading() || ranked().length ? null : EmptyState({ title: "Nothing needs you", symbol: "bell" }))
  ])
}
