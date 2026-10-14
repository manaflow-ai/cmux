// A turn that started four subagents, three still running, for `debug.agent_pane seed_rows` with
// `fixture: "subagents"`: scripts/cmux-next/tile-subagents-e2e.py opens them beside the chat (a
// card row's click) and tiles them (Tile Subagents). Each one's task names its tab.
import type { AcpmuxRow } from "./model";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

/// The subagents' tasks, oldest first; the last one has ended.
export const subagentsTurnTasks = ["Explore auth flow", "Audit retry policy", "Write timeout tests", "Read the docs"];

/// The prompt and the group of subagents, starting at `at`.
export function subagentsTurnRows(at: number): AcpmuxRow[] {
  const agents: Subagent[] = subagentsTurnTasks.map((task, index) => ({
    id: `e2e-subagent-${index + 1}`,
    parent: null,
    name: task,
    task,
    state: index < 3 ? "running" : "completed",
    startedAt: at + 1_000 + index,
    ...(index === 3 && { endedAt: at + 20_000 }),
  }));
  return [
    { id: "subagents-user", version: 1, at, kind: "user", text: "Split the review across subagents." },
    { id: "subagents-group", version: 1, at: at + 1_000, kind: SUBAGENTS, subagents: agents },
  ] as AcpmuxRow[];
}
