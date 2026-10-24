import type { Subagent } from "../subagents/subagentFold";
import type { WorkflowAgent as FoldAgent } from "../subagents/workflowAgents";
import type { WorkflowAgent, WorkflowSummary } from "./workflow";

export type WorkflowDetailRequest = { sessionId: string; runId: string; agentId: string };
export type WorkflowLaunch = { scriptPath: string; args?: unknown; resumeFromRunId?: string };
// Provider-wide events are separate from a pane's displayed workflows. No signal is inferred
// from partial workflow history; a future daemon producer must supply this explicit scope.
export type WorkflowCapacitySignal = {
  daemonId: string;
  errors: readonly { daemonId: string; agentId: string; at: number; reason: string }[];
};

const STATES = new Set(["pending", "running", "waiting", "completed", "failed", "paused", "cancelled"]);
const stateOf = (state?: string): WorkflowAgent["state"] =>
  STATES.has(state ?? "") ? (state as WorkflowAgent["state"]) : state === "queued" ? "waiting" : "unknown";

// Node identity owns UI state. The same runId on two nodes is a resume relationship, never a
// React key: each node can contain an agent at index 0 with a different live lifetime.
export const workflowAgentKey = (nodeId: string, index: number): string => JSON.stringify([nodeId, index]);

export function workflowDetailRequest(
  workflow: WorkflowSummary,
  agent: WorkflowAgent,
): WorkflowDetailRequest | undefined {
  return workflow.sessionId && workflow.runId && agent.agentId
    ? { sessionId: workflow.sessionId, runId: workflow.runId, agentId: agent.agentId }
    : undefined;
}

function agentOf(node: Subagent, agent: FoldAgent): WorkflowAgent {
  return {
    id: workflowAgentKey(node.id, agent.index),
    index: agent.index,
    name: agent.label ?? agent.agentId ?? String(agent.index),
    state: node.paused && agent.state === "running" ? "paused" : stateOf(agent.state),
    agentId: agent.agentId,
    doing: agent.action,
    tokens: agent.tokens,
    lastProgressAt: agent.lastProgressAt,
    retryReason: agent.retryReason,
    cached: agent.cached,
  };
}

function summarize(node: Subagent, sessionId: string): WorkflowSummary {
  const agents = [...(node.workflowAgents?.values() ?? [])].map((agent) => agentOf(node, agent));
  const phases = (node.phases ?? []).map((phase) => ({
    id: String(phase.index),
    name: phase.title,
    state: "unknown" as const,
    agentIds: [...(node.workflowAgents?.values() ?? [])]
      .filter((agent) => agent.phaseIndex === phase.index)
      .map((agent) => workflowAgentKey(node.id, agent.index)),
  }));
  // Unassigned agents remain visible; an absent phase is not evidence of a completed phase.
  const assigned = new Set(phases.flatMap((phase) => phase.agentIds));
  const unassigned = agents.filter((agent) => !assigned.has(agent.id));
  if (unassigned.length)
    phases.push({ id: "unassigned", name: "", state: "unknown", agentIds: unassigned.map((agent) => agent.id) });
  const counts = node.agents;
  const sampled = [...(node.workflowAgents?.values() ?? [])].filter(
    (agent) => agent.state === "completed" && !agent.cached && agent.tokens !== undefined,
  );
  const live = node.tokens;
  const projected =
    live !== undefined && counts && sampled.length
      ? Math.max(
          live,
          Math.round(
            live +
              (sampled.reduce((n, agent) => n + agent.tokens!, 0) / sampled.length) *
                Math.max(0, counts.started - counts.done),
          ),
        )
      : undefined;
  return {
    id: node.id,
    sessionId,
    runId: node.runId,
    title: node.name,
    state: node.paused ? "paused" : stateOf(node.state),
    action: node.action,
    phases,
    agents,
    counts,
    startedAt: node.startedAt,
    elapsedMs: node.endedAt === undefined ? undefined : Math.max(0, node.endedAt - node.startedAt),
    tokens: live,
    projectedTokens: projected,
  };
}

// The fold clones nodes on unrelated text updates. Cache by their fields and immutable map/
// phase references so a streamed token does not rebuild each workflow's phase/agent arrays.
export function createWorkflowAdapter() {
  const cache = new Map<string, { key: unknown[]; summary: WorkflowSummary }>();
  let previous: WorkflowSummary[] = [];
  return (nodes: readonly Subagent[], sessionId: string): WorkflowSummary[] => {
    const workflows: WorkflowSummary[] = [];
    const runs = new Map<string, string>();
    const seen = new Set<string>();
    for (const node of nodes) {
      if (node.kind !== "workflow") continue;
      seen.add(node.id);
      const key = [
        sessionId,
        node.name,
        node.state,
        node.paused,
        node.runId,
        node.phases,
        node.workflowAgents,
        node.agents?.done,
        node.agents?.started,
        node.agents?.failed,
        node.agents?.queued,
        node.tokens,
        node.action,
        node.startedAt,
        node.endedAt,
      ];
      let entry = cache.get(node.id);
      if (!entry || key.some((part, i) => part !== entry!.key[i])) entry = { key, summary: summarize(node, sessionId) };
      const resumedFrom = node.runId ? runs.get(node.runId) : undefined;
      if (entry.summary.resumedFrom !== resumedFrom) entry = { ...entry, summary: { ...entry.summary, resumedFrom } };
      cache.set(node.id, entry);
      workflows.push(entry.summary);
      if (node.runId) runs.set(node.runId, node.id);
    }
    for (const id of cache.keys()) if (!seen.has(id)) cache.delete(id);
    if (previous.length === workflows.length && previous.every((workflow, i) => workflow === workflows[i]))
      return previous;
    return (previous = workflows);
  };
}

export function workflowSignals(workflows: readonly WorkflowSummary[], now: number, daemon?: WorkflowCapacitySignal) {
  const idle = new Set<string>();
  const erroring = new Set(
    daemon?.errors
      .filter(
        (error) =>
          error.daemonId === daemon.daemonId &&
          now >= error.at &&
          now - error.at <= 120_000 &&
          /(?:\b503\b|\b429\b|exhausted)/i.test(error.reason),
      )
      .map((error) => error.agentId),
  );
  for (const workflow of workflows)
    for (const agent of workflow.agents) {
      const age = agent.lastProgressAt === undefined ? undefined : now - agent.lastProgressAt;
      if (agent.state === "running" && age !== undefined && age >= 120_000) idle.add(agent.id);
    }
  return { capacity: erroring.size >= 2, idle };
}

export function workflowDraft(launch: WorkflowLaunch | undefined, runId?: string): string | undefined {
  if (!launch?.scriptPath || (runId !== undefined && !runId)) return undefined;
  return `Workflow(${JSON.stringify({ scriptPath: launch.scriptPath, ...(runId ? { resumeFromRunId: runId } : {}), ...(launch.args !== undefined ? { args: launch.args } : {}) })})`;
}
