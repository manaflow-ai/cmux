// A Claude workflow's phases and agents, as acpmux sends them on the workflow's subagent
// (cmux-tui/crates/acpmux/src/claude_stdio/workflows.rs, `subagents.rs`): the phases whole when
// they change, and in `workflowAgents` each agent that changed, as its `index` and only the fields
// that changed (a removed one null). At the run's end every agent comes whole
// (`workflowAgentsFull`), which replaces what the pane had, so a pane that read only recent history
// still has each agent. subagentFold.ts keeps them on the workflow's `Subagent`; a phase board
// reads them from there.

/// One agent of a workflow, merged from its updates. `tokens` is what its latest request held, as
/// Claude Code's own board counts it, not what it spent.
export type WorkflowAgent = {
  index: number;
  label?: string;
  /// `queued`, `running`, `completed`, `failed`, `skipped`, `blocked`, or Claude's own word for a
  /// state acpmux does not know.
  state?: string;
  phase?: string;
  phaseIndex?: number;
  /// Claude's id for the agent, which names its transcript in the run's folder.
  agentId?: string;
  kind?: string;
  model?: string;
  fallbackModel?: string;
  tokens?: number;
  toolUses?: number;
  elapsedMs?: number;
  queuedAt?: number;
  startedAt?: number;
  lastProgressAt?: number;
  attempt?: number;
  retryReason?: string;
  /// Served from a resumed run's journal: no new spend.
  cached?: boolean;
  isolation?: string;
  remoteSessionId?: string;
  action?: string;
  prompt?: string;
  result?: string;
  error?: string;
};

export type WorkflowPhase = { index: number; title: string };

const TEXT = [
  "label",
  "state",
  "phase",
  "agentId",
  "kind",
  "model",
  "fallbackModel",
  "retryReason",
  "isolation",
  "remoteSessionId",
  "action",
  "prompt",
  "result",
  "error",
] as const;
const NUMBER = [
  "phaseIndex",
  "tokens",
  "toolUses",
  "elapsedMs",
  "queuedAt",
  "startedAt",
  "lastProgressAt",
  "attempt",
] as const;

const index = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
const number = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/// The phases of one update, in order; undefined when it carries none or they do not read.
export function workflowPhases(value: unknown): WorkflowPhase[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const phases = value.flatMap((entry) => {
    const at = index(entry?.index);
    return at === undefined || typeof entry?.title !== "string" ? [] : [{ index: at, title: entry.title }];
  });
  return phases.sort((a, b) => a.index - b.index);
}

/// `agents` with one update's `workflowAgents` merged in, as a new map when anything changed (the
/// one passed in is never changed, so a row drawn from it keeps what it drew). `full` replaces:
/// agents the update does not name are dropped. A field the update sets null is removed; one of the
/// wrong type is ignored. `agents` that is not a map (a row restored from the page's cached
/// snapshot, whose JSON turned the map into `{}`) counts as none.
export function mergeWorkflowAgents(
  agents: ReadonlyMap<number, WorkflowAgent> | undefined,
  value: unknown,
  full = false,
): ReadonlyMap<number, WorkflowAgent> | undefined {
  if (!Array.isArray(value)) return agents;
  const next = new Map(full || !(agents instanceof Map) ? [] : agents);
  for (const entry of value) {
    const at = index(entry?.index);
    if (at === undefined) continue;
    const agent: Record<string, unknown> = { ...(full ? undefined : next.get(at)), index: at };
    for (const key of TEXT) {
      if (entry[key] === null) delete agent[key];
      else if (typeof entry[key] === "string") agent[key] = entry[key];
    }
    for (const key of NUMBER) {
      if (entry[key] === null) delete agent[key];
      else if (number(entry[key]) !== undefined) agent[key] = entry[key];
    }
    if (entry.cached === null || entry.cached === false) delete agent.cached;
    else if (entry.cached === true) agent.cached = true;
    next.set(at, agent as WorkflowAgent);
  }
  return next;
}
