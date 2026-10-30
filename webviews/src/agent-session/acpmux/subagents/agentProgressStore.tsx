// Per-pane progress subscriptions keep usage-only updates out of structural row lists.
import { createContext, useCallback, useContext, useSyncExternalStore } from "react";
import { usePaneLanguage, useT } from "../i18n";
import type { Subagent } from "./subagentFold";
import { subagentProgress } from "./subagentProgress";

type Progress = Pick<Subagent, "agents" | "tokens" | "toolUses">;
const EMPTY: Progress = {};
const same = (a: Progress, b: Progress) =>
  a.tokens === b.tokens && a.toolUses === b.toolUses &&
  a.agents?.done === b.agents?.done && a.agents?.started === b.agents?.started &&
  a.agents?.failed === b.agents?.failed && a.agents?.queued === b.agents?.queued;

export class AgentProgressStore {
  private values = new Map<string, Progress>();
  private listeners = new Map<string, Set<() => void>>();
  constructor(agents: readonly Subagent[]) { this.update(agents); }
  get(id: string): Progress { return this.values.get(id) ?? EMPTY; }
  subscribe(id: string, notify: () => void): () => void {
    let listeners = this.listeners.get(id);
    if (!listeners) this.listeners.set(id, listeners = new Set());
    listeners.add(notify);
    return () => {
      listeners.delete(notify);
      if (listeners.size === 0) this.listeners.delete(id);
    };
  }
  update(agents: readonly Subagent[]): void {
    for (const agent of agents) this.updateAgent(agent);
  }
  updateChanged(agents: readonly Subagent[], seen: Map<string, number | undefined>): void {
    for (const agent of agents) {
      if (seen.get(agent.id) === agent.progressVersion) continue;
      seen.set(agent.id, agent.progressVersion);
      this.updateAgent(agent);
    }
  }
  updateAgent(agent: Subagent): void {
    if (same(this.get(agent.id), agent)) return;
    this.values.set(agent.id, {
      tokens: agent.tokens, toolUses: agent.toolUses,
      agents: agent.agents ? { ...agent.agents } : undefined,
    });
    this.listeners.get(agent.id)?.forEach((notify) => notify());
  }
  remove(id: string): void {
    if (!this.values.delete(id)) return;
    this.listeners.get(id)?.forEach((notify) => notify());
  }
}

export const AgentProgressContext = createContext<AgentProgressStore | undefined>(undefined);
export function useAgentProgress(agent?: Subagent): string | undefined {
  const store = useContext(AgentProgressContext);
  const id = agent?.id;
  const subscribe = useCallback((notify: () => void) =>
    store && id !== undefined ? store.subscribe(id, notify) : () => {}, [store, id]);
  const snapshot = useCallback(() => store && id !== undefined ? store.get(id) : agent ?? EMPTY, [store, id, agent]);
  const progress = useSyncExternalStore(subscribe, snapshot, snapshot);
  const t = useT();
  const language = usePaneLanguage();
  return agent ? subagentProgress(t, language, progress).join(" · ") : undefined;
}
export function AgentProgressText({ agent }: { agent: Subagent }) {
  const text = useAgentProgress(agent);
  return text ? <span className="acpmux-agent-line__progress">{text}</span> : null;
}
