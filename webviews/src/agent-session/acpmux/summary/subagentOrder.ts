// The summary's subagent order: build the parent index once, then walk it without rescanning
// all agents at each level. A malformed self-parent or cycle still leaves every agent visible.
// Source ranks and sibling order stay the summary's own (needs input first, then newest).
export type AgentLineage = { id: string; parent: string | null; startedAt: number };
type Ranked<T> = { agent: T; rank: number; index: number };

export function orderedSubagents<T extends AgentLineage>(
  agents: readonly T[],
  rank: (agent: T) => number,
): { agent: T; depth: number }[] {
  const known = new Set(agents.map((agent) => agent.id));
  const children = new Map<string | null, Ranked<T>[]>();
  const nodes: Ranked<T>[] = [];
  for (const [index, agent] of agents.entries()) {
    const node = { agent, rank: rank(agent), index };
    nodes.push(node);
    const parent = agent.parent && agent.parent !== agent.id && known.has(agent.parent) ? agent.parent : null;
    const bucket = children.get(parent);
    if (bucket) bucket.push(node);
    else children.set(parent, [node]);
  }

  const compare = (a: Ranked<T>, b: Ranked<T>) =>
    a.rank - b.rank || b.agent.startedAt - a.agent.startedAt || a.index - b.index;
  for (const bucket of children.values()) bucket.sort(compare);

  const out: { agent: T; depth: number }[] = [];
  const seen = new Set<string>();
  // Iterative preorder traverses a long delegation chain without growing the call stack.
  const append = (roots: readonly Ranked<T>[], depth: number) => {
    const stack: { node: Ranked<T>; depth: number }[] = [];
    for (let i = roots.length - 1; i >= 0; i--) stack.push({ node: roots[i]!, depth });
    while (stack.length) {
      const item = stack.pop()!;
      const agent = item.node.agent;
      if (seen.has(agent.id)) continue;
      seen.add(agent.id);
      out.push({ agent, depth: item.depth });
      const next = children.get(agent.id) ?? [];
      for (let i = next.length - 1; i >= 0; i--) stack.push({ node: next[i]!, depth: item.depth + 1 });
    }
  };
  append(children.get(null) ?? [], 0);
  // A parent cycle has no top-level member. Promote its highest-priority survivor and
  // show the other members underneath it; otherwise that work disappears from the inspector.
  for (const node of [...nodes].sort(compare)) {
    if (!seen.has(node.agent.id)) append([node], 0);
  }
  return out;
}
