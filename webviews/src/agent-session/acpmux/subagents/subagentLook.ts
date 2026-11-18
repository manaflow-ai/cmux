// Whether two snapshots of a subagent draw the same row in the agent pane's subagent lists: the
// summary card's Subagents tab (SubagentsTab.tsx `listRows`), its Subagents section
// (SubagentStatusList.tsx `SubagentStatusRow`) and the agents pill's list (AgentsPill.tsx
// `AgentsPillRow`). Every snapshot acpmux sends is new objects, so a row memoized on its agent by
// reference drew again on every snapshot, every row of the list, though nothing it shows changed. A
// row compares the fields it draws instead, by this one table over every field of a Subagent: a new
// field fails to compile here until it is classed as drawn (compared) or not (null).
import { sameValue } from "../session-info/sameValue";
import type { Subagent } from "./subagentFold";

type Same<T> = (a: T, b: T) => boolean;

/// Each field of a Subagent: how a row compares it (it draws it, or reads it to place, name, retry,
/// resume or open the row), or null for one no row of these lists reads.
const LOOK: { [K in keyof Subagent]-?: Same<Subagent[K]> | null } = {
  id: Object.is,
  parent: Object.is,
  name: Object.is,
  task: Object.is,
  kind: Object.is,
  state: Object.is,
  startedAt: Object.is,
  endedAt: Object.is,
  action: Object.is,
  actionShell: Object.is,
  tokens: Object.is,
  toolUses: Object.is,
  agents: sameValue,
  runId: Object.is,
  phases: sameValue,
  workflowAgents: sameValue,
  paused: Object.is,
  background: Object.is,
  reaction: sameValue,
  prompt: Object.is,
  stopReason: sameValue,
  agentId: Object.is,
  harness: Object.is,
  model: Object.is,
  effort: Object.is,
  command: Object.is,
  session: Object.is,
  host: Object.is,
  result: Object.is,
  lastMessage: Object.is,
  child: Object.is,
  retry: sameValue,
  retryable: Object.is,
  retriedOut: sameValue,
  resumable: Object.is,
  resumes: Object.is,
  resumedBy: Object.is,
  error: Object.is,
  // The event fold's own sequence, bumped by every progress event (usage-only ones included): it
  // orders the fold's updates; no row reads it.
  progressVersion: null,
  // When it went quiet: only a list that reads the clock turns it Idle by it (Session Info's
  // Subagents, subagentStatusListModel.ts `isIdle` with `now`); these rows read their status
  // without the clock.
  quietSince: null,
  // What a resume of a workflow names again, and the chat that started a sub-session: the fold's
  // and Resume's, read from the fold, never drawn by a row.
  scriptPath: null,
  args: null,
  startedBySession: null,
  // Where it works: Session Info's Environment reads them (session-info/subagentScope.ts), no row.
  isolated: null,
  cwd: null,
  worktree: null,
};

const FIELDS = Object.entries(LOOK).filter((entry): entry is [keyof Subagent, Same<unknown>] => entry[1] !== null);

/// Whether `a` and `b` draw the same row: the same object, or every field a row reads the same.
export function sameSubagentLook(a: Subagent, b: Subagent): boolean {
  return a === b || FIELDS.every(([key, same]) => same(a[key], b[key]));
}

/// Memo for a row that takes one `agent` and plain values (numbers, strings, booleans, the list's
/// stable callbacks): the agent by its look, the rest by identity.
export function sameAgentRowProps<P extends { agent: Subagent }>(a: P, b: P): boolean {
  for (const key in a) {
    if (key === "agent") continue;
    if (!Object.is(a[key], b[key])) return false;
  }
  for (const key in b) if (!(key in a)) return false;
  return sameSubagentLook(a.agent, b.agent);
}
