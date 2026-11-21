import type { Subagent } from "./subagentFold";

/// A section's agents in its order, each nested agent moved right under the agent that spawned it
/// when that one is in the section too, with how deep it then sits. An agent whose parent is in
/// another section, or unknown, stays at the top level.
export function nestAgents(agents: readonly Subagent[]): { agent: Subagent; depth: number }[] {
  const ids = new Set(agents.map((agent) => agent.id));
  const under = new Map<string | null, Subagent[]>();
  for (const agent of agents) {
    const parent = agent.parent !== null && ids.has(agent.parent) ? agent.parent : null;
    const siblings = under.get(parent);
    if (siblings) siblings.push(agent);
    else under.set(parent, [agent]);
  }
  const rows: { agent: Subagent; depth: number }[] = [];
  const placed = new Set<string>();
  const visit = (parent: string | null, depth: number) => {
    for (const agent of under.get(parent) ?? []) {
      if (placed.has(agent.id)) continue;
      placed.add(agent.id);
      rows.push({ agent, depth });
      visit(agent.id, depth + 1);
    }
  };
  visit(null, 0);
  // A parent loop never reaches the top level: list those agents flat rather than drop them.
  for (const agent of agents) if (!placed.has(agent.id)) rows.push({ agent, depth: 0 });
  return rows;
}
