import type { AcpmuxRow } from "../model";

/// The transcript row of a batch of subagents (SubagentGroup.tsx).
export const SUBAGENTS = "subagents";

/// One subagent, from the model acpmux records in each update's `_meta.acpmux`
/// (cmux-tui/crates/acpmux/src/subagents.rs): native ACP subagent sessions and Codex's
/// collaboration calls alike.
export type Subagent = {
  id: string;
  /// The subagent that spawned it, or null for the session's own.
  parent: string | null;
  name: string;
  task?: string;
  /// `running`, `completed`, `failed`, `cancelled` or `disconnected`.
  state: string;
  startedAt: number;
  endedAt?: number;
  /// The title of its latest tool call.
  action?: string;
};

type Event = { seq: number; at: number; msg?: any };
type Group = { id: string; at: number; version: number; ids: string[] };

/// Folds a session's subagent records out of its transcript. Subagents the session spawns
/// between two pieces of its own text draw as one group row where the first one started; their
/// own updates, their spawn and state events, and the tool calls that started them draw no row.
export class SubagentFold {
  private readonly agents = new Map<string, Subagent>();
  private readonly groupOf = new Map<string, Group>();
  private readonly spawnCalls = new Set<string>();
  private readonly changed = new Set<Group>();
  private open: Group | undefined;

  /// Folds one session/update record; true when it belongs to subagents and draws no row.
  reduce(event: Event, update: any): boolean {
    const mux = event.msg?.params?._meta?.acpmux;
    const events: any[] = Array.isArray(mux?.subagents) ? mux.subagents : [];
    for (const change of events) this.apply(change, event);
    const owner = typeof mux?.subagent === "string" ? this.agents.get(mux.subagent) : undefined;
    if (owner) {
      if ((update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update") && update.title)
        owner.action = String(update.title);
      this.touch(owner);
      return true;
    }
    const kind = update?.sessionUpdate;
    if (kind === "subagent_spawned" || kind === "subagent_state_update") return true;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    if (call && this.spawnCalls.has(call)) return true;
    return events.length > 0;
  }

  /// Ends the current batch: the next subagent the session spawns starts a new group.
  closeBatch(): void {
    this.open = undefined;
  }

  /// The group rows that changed since the last call.
  takeRows(): AcpmuxRow[] {
    const rows = [...this.changed].map((group) => ({
      id: group.id,
      version: group.version,
      at: group.at,
      kind: SUBAGENTS,
      subagents: group.ids.map((id) => ({ ...this.agents.get(id)! })),
    }));
    this.changed.clear();
    return rows;
  }

  /// Every subagent seen, nested ones included.
  all(): Subagent[] {
    return [...this.agents.values()];
  }

  private apply(change: any, event: Event): void {
    if (typeof change?.id !== "string") return;
    if (typeof change.toolCallId === "string") this.spawnCalls.add(change.toolCallId);
    let agent = this.agents.get(change.id);
    if (!agent) {
      const parent = typeof change.parent === "string" ? change.parent : null;
      const name = text(change.name) ?? text(change.task) ?? change.id;
      agent = { id: change.id, parent, name, task: text(change.task), state: "running", startedAt: event.at };
      this.agents.set(agent.id, agent);
      if (parent === null) {
        this.open ??= { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [] };
        this.open.ids.push(agent.id);
        this.groupOf.set(agent.id, this.open);
      }
    } else {
      agent.name = text(change.name) ?? agent.name;
      agent.task = text(change.task) ?? agent.task;
    }
    const state = text(change.state);
    if (state && state !== agent.state) {
      agent.state = state;
      agent.endedAt = state === "running" ? undefined : event.at;
    }
    this.touch(agent);
  }

  /// Redraws the group row a subagent is listed in.
  private touch(agent: Subagent): void {
    const group = this.groupOf.get(agent.id);
    if (!group) return;
    group.version += 1;
    this.changed.add(group);
  }
}

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
