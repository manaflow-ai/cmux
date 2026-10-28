import type { Subagent } from "../subagents/subagentFold";
import type { WorkflowAgent as FoldAgent } from "../subagents/workflowAgents";
import type { WorkflowAgent, WorkflowPhase, WorkflowSummary } from "./workflow";

export type WorkflowDetailRequest = { sessionId: string; runId: string; agentId: string };
export type WorkflowLaunch = { scriptPath: string; args?: unknown; resumeFromRunId?: string };
// Provider-wide events are separate from a pane's displayed workflows. No signal is inferred
// from partial workflow history; a future daemon producer must supply this explicit scope.
export type WorkflowCapacitySignal = {
  daemonId: string;
  errors: readonly { daemonId: string; agentId: string; at: number; reason: string }[];
};

const STATES = new Set(["pending", "running", "waiting", "completed", "failed", "paused", "cancelled"]);
/// Claude's workflow agent states as the pane's: queued waits; blocked (a dependency failed) failed;
/// skipped ended without running, as a cancelled agent did.
const ALIASES: Record<string, WorkflowAgent["state"]> = { queued: "waiting", blocked: "failed", skipped: "cancelled" };
const stateOf = (state?: string): WorkflowAgent["state"] =>
  STATES.has(state ?? "") ? (state as WorkflowAgent["state"]) : (ALIASES[state ?? ""] ?? "unknown");

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
    lastMessage: agent.result,
    tokens: agent.tokens,
    lastProgressAt: agent.lastProgressAt,
    retryReason: agent.retryReason,
    cached: agent.cached,
    model: agent.model,
    effort: agent.effort,
    elapsedMs: agent.elapsedMs,
    startedAt: agent.startedAt,
  };
}

/// How many of `agents` run, wait, ended well and failed. A paused agent counts as running (its
/// row says paused); one whose state is not known counts only in `total`.
export type Tally = { running: number; queued: number; done: number; failed: number; total: number };
export function tally(agents: readonly WorkflowAgent[]): Tally {
  const out = { running: 0, queued: 0, done: 0, failed: 0, total: agents.length };
  for (const agent of agents) {
    if (agent.state === "completed") out.done += 1;
    else if (agent.state === "failed" || agent.state === "cancelled") out.failed += 1;
    else if (agent.state === "running" || agent.state === "paused") out.running += 1;
    else if (agent.state === "waiting" || agent.state === "pending") out.queued += 1;
  }
  return out;
}

/// A phase's state from its agents: running while one runs, completed when all ended well, failed
/// when one failed and none runs or waits, pending before any started.
export function phaseState(agents: readonly WorkflowAgent[]): WorkflowPhase["state"] {
  const { running, queued, done, failed, total } = tally(agents);
  if (running > 0) return "running";
  if (total > 0 && done === total) return "completed";
  if (failed > 0 && queued === 0) return "failed";
  if (done + failed > 0) return "running";
  return "pending";
}

/// The agents of `phase`, in the workflow's order.
export function phaseAgents(workflow: WorkflowSummary, phase: WorkflowPhase): WorkflowAgent[] {
  const ids = new Set(phase.agentIds);
  return workflow.agents.filter((agent) => ids.has(agent.id));
}

/// The phases after the last one any agent started in, none of whose agents started: what runs next.
export function upNext(workflow: WorkflowSummary): WorkflowPhase[] {
  const started = workflow.phases.map((phase) => phaseState(phaseAgents(workflow, phase)) !== "pending");
  const last = started.lastIndexOf(true);
  return workflow.phases.filter((phase, i) => i > last && phase.id !== "unassigned");
}

/// A model id as people say it: `claude-opus-5-5` -> "Opus 5.5", `sonnet` -> "Sonnet"; else as is.
export function modelName(model: string): string {
  const match = /^(?:claude-)?([a-z]+)(?:-(\d+)(?:-(\d+))?)?(?:-\d{8})?$/i.exec(model.trim());
  if (!match) return model;
  const [, family, major, minor] = match;
  const name = family!.charAt(0).toUpperCase() + family!.slice(1);
  return major ? `${name} ${major}${minor ? `.${minor}` : ""}` : name;
}

/// The node's workflow agents, in order. A node restored from the page's cached snapshot carries the
/// map as `{}` (JSON has no Map): none.
const foldAgents = (node: Subagent): FoldAgent[] =>
  node.workflowAgents instanceof Map ? [...node.workflowAgents.values()] : [];

/// One workflow node's summary, uncached (a transcript card; the panel's list uses the adapter).
export const workflowOf = (node: Subagent, sessionId: string): WorkflowSummary => summarize(node, sessionId);

function summarize(node: Subagent, sessionId: string): WorkflowSummary {
  const agents = foldAgents(node).map((agent) => agentOf(node, agent));
  const phases: WorkflowPhase[] = (node.phases ?? []).map((phase) => {
    const members = foldAgents(node).filter((agent) => agent.phaseIndex === phase.index);
    return {
      id: String(phase.index),
      name: phase.title,
      state: phaseState(members.map((agent) => agentOf(node, agent))),
      agentIds: members.map((agent) => workflowAgentKey(node.id, agent.index)),
    };
  });
  // Unassigned agents remain visible; an absent phase is not evidence of a completed phase.
  const assigned = new Set(phases.flatMap((phase) => phase.agentIds));
  const unassigned = agents.filter((agent) => !assigned.has(agent.id));
  if (unassigned.length)
    phases.push({
      id: "unassigned",
      name: "",
      state: phaseState(unassigned),
      agentIds: unassigned.map((agent) => agent.id),
    });
  const counts = node.agents;
  const sampled = foldAgents(node).filter(
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
    description: node.task,
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
        node.task,
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
