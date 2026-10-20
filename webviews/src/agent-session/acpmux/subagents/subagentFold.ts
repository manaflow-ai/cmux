import type { AcpmuxRow } from "../model";
import { childRows, type ChildEntry } from "./childRows";

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
  /// The kind of agent it is, when the harness names one (Claude's subagent_type: Explore,
  /// general-purpose, a user agent).
  kind?: string;
  /// `running`, `completed`, `failed`, `cancelled` or `disconnected`.
  state: string;
  startedAt: number;
  endedAt?: number;
  /// The title of its latest tool call, or what the harness says it does now (Claude's progress
  /// summary or last tool; a workflow's current step).
  action?: string;
  /// Tokens it has used and tool calls it has made so far (Claude's task progress).
  tokens?: number;
  toolUses?: number;
  /// A Claude workflow's agents: how many returned of how many started.
  agents?: { done: number; started: number };
  /// The harness runs it in the background: it outlives its turn's stop.
  background?: boolean;
};

export type Event = { seq: number; at: number; msg?: any };
type Group = { id: string; at: number; version: number; ids: string[] };

/// Folds a session's subagent records out of its transcript. Subagents the session spawns
/// between two pieces of its own text draw as one group row where the first one started; their
/// own updates, their spawn and state events, and the tool calls that started them draw no row.
export class SubagentFold {
  private readonly agents = new Map<string, Subagent>();
  private readonly groupOf = new Map<string, Group>();
  private readonly spawnCalls = new Set<string>();
  /// Codex's `wait` and `closeAgent` calls between its subagents, by call id: a later update of
  /// the same call may come without its `_meta`, and must draw no row either.
  private readonly collabCalls = new Set<string>();
  private readonly changed = new Set<Group>();
  private open: Group | undefined;
  /// Each subagent's own updates and the points where it spawned subagents, in order: its view.
  private readonly own = new Map<string, ChildEntry[]>();
  /// Each subagent view's rows, while its version holds.
  private readonly drawn = new Map<string, { version: number; rows: AcpmuxRow[] }>();
  private readonly versions = new Map<string, number>();
  /// The subagents spawned since the current turn started, which its stop ends.
  private turn = new Set<string>();

  /// Folds one session/update record; true when it belongs to subagents and draws no row.
  reduce(event: Event, update: any): boolean {
    const mux = event.msg?.params?._meta?.acpmux;
    const events: any[] = Array.isArray(mux?.subagents) ? mux.subagents : [];
    for (const change of events) this.apply(change, event);
    const owner = typeof mux?.subagent === "string" ? this.agents.get(mux.subagent) : undefined;
    if (owner) {
      if ((update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update") && update.title)
        owner.action = String(update.title);
      const kind = update?.sessionUpdate;
      if (kind !== "subagent_spawned" && kind !== "subagent_state_update") this.record(owner.id, { event, update });
      this.touch(owner);
      return true;
    }
    const kind = update?.sessionUpdate;
    if (kind === "subagent_spawned" || kind === "subagent_state_update" || kind === "subagent_progress") return true;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    if (call && this.spawnCalls.has(call)) return true;
    // Codex's own bookkeeping between its subagents (`wait` for them, `closeAgent`): the group
    // row already shows who is working and who is done, so these draw no row of their own.
    if (call && this.collabCalls.has(call)) return true;
    const collab = update?._meta?.codex?.collaboration?.tool;
    if (this.agents.size > 0 && (collab === "wait" || collab === "closeAgent")) {
      if (call) this.collabCalls.add(call);
      return true;
    }
    return events.length > 0;
  }

  /// A turn starts: its stop ends the subagents spawned from here on.
  startTurn(): void {
    this.turn = new Set();
  }

  /// Ends the subagents still running that nothing will end any more (``subagentsLeft``): the
  /// current turn's foreground ones at its stop, or every one when the agent process behind the
  /// chat went away. One that reports again (a `running` state) runs again. Returns whether any
  /// changed.
  stopRunning(left: SubagentsLeft, at: number): boolean {
    let changed = false;
    for (const agent of this.agents.values()) {
      if (agent.state !== "running") continue;
      if (left.turn && (!this.turn.has(agent.id) || agent.background)) continue;
      agent.state = left.state;
      agent.endedAt = at;
      this.touch(agent);
      changed = true;
    }
    return changed;
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

  /// Each subagent's own view (its text, thoughts and tool calls, and the subagents it spawned
  /// as group rows), for the child view. Unchanged views keep their rows.
  views(): Record<string, AcpmuxRow[]> {
    const views: Record<string, AcpmuxRow[]> = {};
    for (const [id, entries] of this.own) {
      const version = this.versions.get(id) ?? 0;
      let drawn = this.drawn.get(id);
      if (drawn?.version !== version) {
        drawn = { version, rows: childRows(id, entries, this.agents, version) };
        this.drawn.set(id, drawn);
      }
      views[id] = drawn.rows;
    }
    return views;
  }

  private record(id: string, entry: ChildEntry): void {
    const entries = this.own.get(id) ?? [];
    entries.push(entry);
    this.own.set(id, entries);
    this.bump(id);
  }

  private bump(id: string): void {
    this.versions.set(id, (this.versions.get(id) ?? 0) + 1);
  }

  private apply(change: any, event: Event): void {
    if (typeof change?.id !== "string") return;
    if (typeof change.toolCallId === "string") this.spawnCalls.add(change.toolCallId);
    let agent = this.agents.get(change.id);
    if (!agent) {
      const parent = typeof change.parent === "string" ? change.parent : null;
      const name = text(change.name) ?? text(change.task) ?? change.id;
      agent = {
        id: change.id,
        parent,
        name,
        task: text(change.task),
        kind: text(change.kind),
        state: "running",
        startedAt: event.at,
      };
      this.agents.set(agent.id, agent);
      this.turn.add(agent.id);
      if (parent === null) {
        this.open ??= { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [] };
        this.open.ids.push(agent.id);
        this.groupOf.set(agent.id, this.open);
      } else this.record(parent, { event, spawned: agent.id });
    } else {
      agent.name = text(change.name) ?? agent.name;
      agent.task = text(change.task) ?? agent.task;
      agent.kind = text(change.kind) ?? agent.kind;
    }
    agent.action = text(change.action) ?? agent.action;
    agent.tokens = count(change.tokens) ?? agent.tokens;
    agent.toolUses = count(change.toolUses) ?? agent.toolUses;
    if (change.background === true) agent.background = true;
    const done = count(change.agents?.done);
    const started = count(change.agents?.started);
    if (done !== undefined && started !== undefined) agent.agents = { done, started };
    const state = text(change.state);
    if (state && state !== agent.state) {
      agent.state = state;
      agent.endedAt = state === "running" ? undefined : event.at;
    }
    this.touch(agent);
  }

  /// Redraws the group row a subagent is listed in, or its parent's view.
  private touch(agent: Subagent): void {
    if (agent.parent !== null) this.bump(agent.parent);
    const group = this.groupOf.get(agent.id);
    if (!group) return;
    group.version += 1;
    this.changed.add(group);
  }
}

/// Which running subagents nothing will end any more, and how they read: `turn` only the
/// current turn's foreground ones, else every one.
export type SubagentsLeft = { state: "cancelled" | "disconnected"; turn: boolean };

/// Whom acpmux's record `kind` leaves running with no one to end them: a stopped turn's
/// foreground subagents (`cancelled`; the harness keeps background ones running), a turn the
/// daemon lost (`outcome_unknown`), or, when the agent process behind the chat went away or
/// started again (an exit or stop, a reopen or resume, a new or ended host), every one, as
/// acpmux's own process table reads those records (hub/processes.rs).
export function subagentsLeft(kind: string, msg: any): SubagentsLeft | undefined {
  if (kind === "turn_result" && msg?.detail === "outcome_unknown") return { state: "disconnected", turn: true };
  if (kind === "turn_result" && msg?.status === "cancelled") return { state: "cancelled", turn: true };
  return HARNESS_GONE.has(kind) ? { state: "disconnected", turn: false } : undefined;
}
const HARNESS_GONE = new Set(["exited", "stopped", "reopened", "resumed", "host_started", "host_ended"]);

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
