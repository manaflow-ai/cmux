import type { AcpmuxSnapshot } from "../model";

export type WorkflowAgent = {
  id: string;
  name: string;
  state: "pending" | "running" | "waiting" | "completed" | "failed";
  doing?: string;
  tokens?: number;
  transcriptRowId?: string;
};

export type WorkflowPhase = {
  id: string;
  name: string;
  state: "pending" | "running" | "completed" | "failed";
  agentIds: string[];
};

export type WorkflowSummary = {
  id: string;
  title: string;
  state: "pending" | "running" | "paused" | "completed" | "failed";
  phase?: string;
  phases: WorkflowPhase[];
  agents: WorkflowAgent[];
  elapsedMs?: number;
  tokens?: number;
  large?: boolean;
  selectedAgentId?: string;
};

const STATES = {
  workflow: new Set<WorkflowSummary["state"]>(["pending", "running", "paused", "completed", "failed"]),
  phase: new Set<WorkflowPhase["state"]>(["pending", "running", "completed", "failed"]),
  agent: new Set<WorkflowAgent["state"]>(["pending", "running", "waiting", "completed", "failed"]),
};

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;

const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);
const count = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/// The optional adapter seam for future acpmux workflow events. Until the daemon sends `workflow`,
/// this returns undefined and the Labs-only surface stays absent; no state is inferred from rows.
export function workflowFromSnapshot(snapshot: AcpmuxSnapshot): WorkflowSummary | undefined {
  return workflowFromWire(snapshot.workflow);
}

export function workflowFromWire(value: unknown): WorkflowSummary | undefined {
  const raw = record(value);
  if (!raw) return undefined;
  const id = text(raw.id);
  const title = text(raw.title);
  const state = text(raw.state);
  if (!id || !title || !state || !STATES.workflow.has(state as WorkflowSummary["state"])) return undefined;
  // A partial event must not make the UI claim it knows phases or agent totals.
  if (!Array.isArray(raw.phases) || !Array.isArray(raw.agents)) return undefined;
  const agents = Array.isArray(raw.agents)
    ? raw.agents.flatMap((entry): WorkflowAgent[] => {
        const agent = record(entry);
        const agentId = text(agent?.id);
        const name = text(agent?.name);
        const agentState = text(agent?.state);
        if (!agentId || !name || !agentState || !STATES.agent.has(agentState as WorkflowAgent["state"])) return [];
        return [
          {
            id: agentId,
            name,
            state: agentState as WorkflowAgent["state"],
            ...(text(agent?.doing) ? { doing: text(agent?.doing) } : {}),
            ...(count(agent?.tokens) !== undefined ? { tokens: count(agent?.tokens) } : {}),
            ...(text(agent?.transcriptRowId) ? { transcriptRowId: text(agent?.transcriptRowId) } : {}),
          },
        ];
      })
    : [];
  const phases = Array.isArray(raw.phases)
    ? raw.phases.flatMap((entry): WorkflowPhase[] => {
        const phase = record(entry);
        const phaseId = text(phase?.id);
        const name = text(phase?.name);
        const phaseState = text(phase?.state);
        if (!phaseId || !name || !phaseState || !STATES.phase.has(phaseState as WorkflowPhase["state"])) return [];
        const agentIds = Array.isArray(phase?.agentIds)
          ? phase.agentIds.filter((id): id is string => typeof id === "string")
          : [];
        return [{ id: phaseId, name, state: phaseState as WorkflowPhase["state"], agentIds }];
      })
    : [];
  return {
    id,
    title,
    state: state as WorkflowSummary["state"],
    ...(text(raw.phase) ? { phase: text(raw.phase) } : {}),
    phases,
    agents,
    ...(count(raw.elapsedMs) !== undefined ? { elapsedMs: count(raw.elapsedMs) } : {}),
    ...(count(raw.tokens) !== undefined ? { tokens: count(raw.tokens) } : {}),
    ...(raw.large === true ? { large: true } : {}),
    ...(text(raw.selectedAgentId) ? { selectedAgentId: text(raw.selectedAgentId) } : {}),
  };
}
