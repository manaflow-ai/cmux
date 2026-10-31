import { retryKey } from "./retryState";
import type { Subagent } from "./subagentFold";
import type { AcpmuxRow } from "../model";

export type AgentProgress = Pick<Subagent, "agents" | "tokens" | "toolUses">;
const EMPTY: AgentProgress = {};
const same = (a: AgentProgress, b: AgentProgress) =>
  a.tokens === b.tokens &&
  a.toolUses === b.toolUses &&
  a.agents?.done === b.agents?.done &&
  a.agents?.started === b.agents?.started &&
  a.agents?.failed === b.agents?.failed &&
  a.agents?.queued === b.agents?.queued;

export class AgentProgressStore {
  private values = new Map<string, AgentProgress>();
  structureVersion = 0;
  private structures = new Map<string, string>();
  private listeners = new Map<string, Set<() => void>>();
  private changedProgress = new Map<string, AgentProgress>();
  constructor(agents: readonly Subagent[] = []) {
    this.update(agents);
  }
  has(id: string): boolean {
    return this.structures.has(id);
  }
  get(id: string): AgentProgress {
    return this.values.get(id) ?? EMPTY;
  }
  subscribe(id: string, notify: () => void): () => void {
    let listeners = this.listeners.get(id);
    if (!listeners) this.listeners.set(id, (listeners = new Set()));
    listeners.add(notify);
    return () => {
      listeners.delete(notify);
      if (listeners.size === 0) this.listeners.delete(id);
    };
  }
  update(agents: readonly Subagent[]): void {
    for (const agent of agents) this.updateAgent(agent);
  }
  updateProgress(id: string, progress: AgentProgress): void {
    const previous = this.get(id);
    if (same(previous, progress)) return;
    this.values.set(id, progress);
    this.listeners.get(id)?.forEach((notify) => notify());
  }
  updateAgent(agent: Subagent): void {
    const structure = [
      agent.id,
      agent.name,
      agent.parent,
      agent.kind,
      agent.state,
      agent.action,
      agent.actionShell,
      agent.endedAt,
      agent.agentId,
      agent.harness,
      agent.task,
      agent.startedAt,
      agent.background,
      agent.command,
      retryKey(agent),
    ].join("\u0000");
    if (this.structures.get(agent.id) !== structure) {
      this.structures.set(agent.id, structure);
      this.structureVersion += 1;
    }
    if (same(this.get(agent.id), agent)) return;
    const progress = {
      tokens: agent.tokens,
      toolUses: agent.toolUses,
      agents: agent.agents ? { ...agent.agents } : undefined,
    };
    this.values.set(agent.id, progress);
    this.changedProgress.set(agent.id, progress);
    this.listeners.get(agent.id)?.forEach((notify) => notify());
  }
  takeChangedProgress(): Record<string, AgentProgress> {
    const changed = Object.fromEntries(this.changedProgress);
    this.changedProgress.clear();
    return changed;
  }
  remove(id: string): void {
    this.changedProgress.delete(id);
    if (this.structures.delete(id)) this.structureVersion += 1;
    if (!this.values.delete(id)) return;
    this.listeners.get(id)?.forEach((notify) => notify());
  }
}

// In-process source metadata stays off the serialized snapshot/cache. Direct-client snapshots
// sharing a row array share the source; bridge/gallery snapshots use the compatibility path.
const sources = new WeakMap<readonly AcpmuxRow[], AgentProgressStore>();
export const markAgentProgressSource = (rows: readonly AcpmuxRow[], source: AgentProgressStore) =>
  sources.set(rows, source);
export const agentProgressSource = (rows: readonly AcpmuxRow[]) => sources.get(rows);
