import type { AcpmuxRow } from "../model";
import { childRows, type ChildEntry } from "./childRows";
import { hiddenCall, isPlumbingName } from "../hiddenTools";

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
  /// What it was asked, as the harness got it (Claude's Agent `prompt`): Restart sends it again.
  prompt?: string;
  /// Why a stopped (`cancelled`) one stopped, when this pane knows (``SubagentStops``); none
  /// when it does not.
  stopReason?: SubagentStopReason;
  /// The id Claude Code's Agent call answered with (`agentId: …`), which a SendMessage to it
  /// names (conversation/agentNames.ts).
  agentId?: string;
  /// Where the harness says it works, from the call that started it: Claude's Agent call asked for
  /// a worktree of its own (`isolation: "worktree"`), the folder that call named (`cwd`), and the
  /// worktree and branch its result reports (`worktreePath:`, `worktreeBranch:`). The Inspector's
  /// Environment for the subagent reads them (inspector/subagentScope.ts).
  isolated?: boolean;
  cwd?: string;
  worktree?: { path: string; branch?: string };
};

/// Why a subagent was stopped: the person stopped it (Stop on the turn, or on the subagent), or a
/// prompt sent with Send now interrupted its turn.
export type SubagentStopReason = "user" | "sendNow";

/// What the pane knows about subagent stops, kept across the fold's rebuilds (direct.ts): the
/// subagents this pane asked to stop, and each stopped one's reason once known. A reload of the
/// page knows only what acpmux's records say (a Send now's `queue_order`).
export type SubagentStops = { requested: Set<string>; reasons: Map<string, SubagentStopReason> };
export const subagentStops = (): SubagentStops => ({ requested: new Set(), reasons: new Map() });

export type Event = { seq: number; at: number; msg?: any };
type Group = { id: string; at: number; version: number; ids: string[] };

/// Folds a session's subagent records out of its transcript. Subagents the session spawns
/// between two pieces of its own text draw as one group row where the first one started; their
/// own updates, their spawn and state events, and the tool calls that started them draw no row.
export class SubagentFold {
  private readonly agents = new Map<string, Subagent>();
  private readonly groupOf = new Map<string, Group>();
  private readonly spawnCalls = new Set<string>();
  /// The subagent each spawning call started, by call id.
  private readonly spawnedBy = new Map<string, string>();
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
  /// What stops the running turn now, when the pane knows (direct.ts `turnStopCause`): a stop
  /// it ends its foreground subagents with is theirs too.
  cause: SubagentStopReason | undefined;
  /// The chat's own agent session (its harness thread, the summary's `agentSessionId`), when the
  /// pane knows it. It is never one of its subagents (``isChat``). Learned only after records that
  /// made it one were folded, the pane folds them again (direct.ts ``learnChatThread``).
  chat: string | undefined;
  /// Every id a record named as a subagent, a parent or an owner (``names``).
  private readonly named = new Set<string>();

  constructor(private readonly stops: SubagentStops = subagentStops()) {}
  /// The subagents whose end the harness reported (not one ``stopRunning`` guessed): a progress
  /// report that trails it (Claude's last task_progress) does not run one again.
  private readonly ended = new Set<string>();
  /// Each subagent's newest tool call, and every call it made: an update to an older one does not
  /// take its action back.
  private readonly latestCall = new Map<string, string>();
  private readonly calls = new Set<string>();
  /// Plumbing calls each subagent made (hiddenTools.ts): they and their results set no action.
  private readonly hiddenCalls = new Set<string>();
  /// The subagents a tool call started (Claude's Agent call, which its turn waits on): only these
  /// end with a completed turn. Codex's native children have none and outlive their turn.
  private readonly called = new Set<string>();

  /// Folds one session/update record; true when it belongs to subagents and draws no row.
  reduce(event: Event, update: any): boolean {
    const mux = event.msg?.params?._meta?.acpmux;
    const events: any[] = Array.isArray(mux?.subagents) ? mux.subagents : [];
    const tag = typeof mux?.subagent === "string" ? mux.subagent : undefined;
    if (tag !== undefined) this.named.add(tag);
    // Met first through its progress, its spawn is older than what this fold read: not this turn's.
    const spawn = update?.sessionUpdate !== "subagent_progress";
    for (const change of events) this.apply(change, event, spawn);
    // An update acpmux tagged with the chat's own session is the chat's (``isChat``).
    const owner = tag !== undefined && !this.isChat(tag) ? this.agents.get(tag) : undefined;
    if (owner) {
      // What it does now is its newest call: a later update of an older call (its end) keeps it.
      const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
      // Plumbing (Claude Code's ToolSearch, hiddenTools.ts) is never what it does, nor its result.
      const hidden = call !== undefined && hiddenCall(this.hiddenCalls, `${owner.id}\u0000${call}`, update);
      // A nested subagent's Agent call says its agentId and worktree too.
      if (call && this.spawnCalls.has(call)) this.readSpawnCall(call, update);
      // A call met first through its update (a harness that sends no tool_call) is new too.
      const tool = !hidden && (update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update");
      if (tool && call && (update.sessionUpdate === "tool_call" || !this.calls.has(`${owner.id}\u0000${call}`))) {
        this.calls.add(`${owner.id}\u0000${call}`);
        this.latestCall.set(owner.id, call);
      }
      const newest = call === undefined || (this.latestCall.get(owner.id) ?? call) === call;
      if (tool && update.title && newest) owner.action = String(update.title);
      const kind = update?.sessionUpdate;
      // The Agent call that spawned it is the parent's, not a step of its own.
      const spawnCall = typeof update?.toolCallId === "string" && this.spawnCalls.has(update.toolCallId);
      if (kind !== "subagent_spawned" && kind !== "subagent_state_update" && !spawnCall)
        this.record(owner.id, { event, update });
      this.touch(owner);
      return true;
    }
    const kind = update?.sessionUpdate;
    if (kind === "subagent_spawned" || kind === "subagent_state_update" || kind === "subagent_progress") return true;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    if (call && this.spawnCalls.has(call)) {
      this.readSpawnCall(call, update);
      return true;
    }
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
      if (left.state === "completed" && !this.called.has(agent.id)) continue;
      agent.state = left.state;
      agent.endedAt = at;
      this.settleReason(agent);
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

  /// Whether `id` is the chat's own session. A Codex child reports its parent thread's state
  /// under its own session, and acpmux used to record that as a spawn: the chat became its
  /// own subagent, nested under that child, and every later subagent nested under the chat (Leo's
  /// staircase, 2026-10-22). Records written then still say so, so the fold reads them by lineage.
  private isChat(id: string): boolean {
    return id === this.chat;
  }

  /// Whether a folded record named `id` as a subagent, a subagent's parent or an update's owner.
  names(id: string): boolean {
    return this.named.has(id);
  }

  private apply(change: any, event: Event, spawn = true): void {
    if (typeof change?.id !== "string") return;
    this.named.add(change.id);
    if (typeof change.parent === "string") this.named.add(change.parent);
    if (this.isChat(change.id)) return;
    if (typeof change.toolCallId === "string") {
      this.spawnCalls.add(change.toolCallId);
      this.spawnedBy.set(change.toolCallId, change.id);
    }
    let agent = this.agents.get(change.id);
    if (!agent) {
      const parent = typeof change.parent === "string" && !this.isChat(change.parent) ? change.parent : null;
      const name = text(change.name) ?? text(change.task) ?? change.id;
      agent = {
        id: change.id,
        parent,
        name,
        task: text(change.task),
        kind: text(change.kind),
        prompt: text(change.prompt),
        state: "running",
        startedAt: event.at,
      };
      this.agents.set(agent.id, agent);
      if (spawn) this.turn.add(agent.id);
      if (typeof change.toolCallId === "string") this.called.add(agent.id);
      if (parent === null) {
        this.open ??= { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [] };
        this.open.ids.push(agent.id);
        this.groupOf.set(agent.id, this.open);
      } else this.record(parent, { event, spawned: agent.id });
    } else {
      agent.name = text(change.name) ?? agent.name;
      agent.task = text(change.task) ?? agent.task;
      agent.kind = text(change.kind) ?? agent.kind;
      agent.prompt = text(change.prompt) ?? agent.prompt;
    }
    // Claude's progress names its last tool when it has no summary: plumbing is never what it does.
    const action = text(change.action);
    if (action && !isPlumbingName(action)) agent.action = action;
    agent.tokens = count(change.tokens) ?? agent.tokens;
    agent.toolUses = count(change.toolUses) ?? agent.toolUses;
    if (change.background === true) agent.background = true;
    const done = count(change.agents?.done);
    const started = count(change.agents?.started);
    if (done !== undefined && started !== undefined) agent.agents = { done, started };
    const state = text(change.state);
    // An end the harness reported holds against a progress report that trails it; a spawn or a
    // state update saying it runs again still does.
    if (state && state !== "running" && spawn) this.ended.add(agent.id);
    else if (state === "running" && spawn) this.ended.delete(agent.id);
    if (state && state !== agent.state && !(state === "running" && !spawn && this.ended.has(agent.id))) {
      agent.state = state;
      agent.endedAt = state === "running" ? undefined : event.at;
      this.settleReason(agent);
    }
    this.touch(agent);
  }

  /// Records why a subagent that just stopped stopped (``stopReasonOf``), or forgets the reason
  /// of one that runs again.
  private settleReason(agent: Subagent): void {
    // The turn's stop is a reason only for the subagents that turn started and its stop ends.
    const cause = this.turn.has(agent.id) ? this.cause : undefined;
    const reason = stopReasonOf(agent, this.stops, cause);
    if (reason) {
      agent.stopReason = reason;
      this.stops.reasons.set(agent.id, reason);
    } else {
      delete agent.stopReason;
      // One that runs again starts a new life: an old stop's reason is not its next one's.
      if (agent.state === "running") this.stops.reasons.delete(agent.id);
    }
    if (agent.state !== "running") this.stops.requested.delete(agent.id);
  }

  /// Redraws the group row a subagent is listed in, or its parent's view.
  /// What a spawning call (Claude Code's Agent call) says of the subagent it started: from its input,
  /// whether it runs in a worktree of its own and the folder it was given; from its result, the
  /// agentId and the worktree it worked in.
  private readSpawnCall(call: string, update: any): void {
    const id = this.spawnedBy.get(call);
    const agent = id ? this.agents.get(id) : undefined;
    if (!agent) return;
    let changed = false;
    const input = update?.rawInput;
    if (input && typeof input === "object") {
      if (input.isolation === "worktree" && !agent.isolated) {
        agent.isolated = true;
        changed = true;
      }
      const cwd = text(input.cwd);
      if (cwd?.startsWith("/") && agent.cwd !== cwd) {
        agent.cwd = cwd;
        changed = true;
      }
    }
    for (const part of Array.isArray(update?.content) ? update.content : []) {
      const said = part?.content?.text;
      if (typeof said !== "string") continue;
      const found = agent.agentId ? undefined : agentIdIn(said);
      if (found) {
        agent.agentId = found;
        changed = true;
      }
      const worktree = worktreeIn(said);
      if (worktree && (worktree.path !== agent.worktree?.path || worktree.branch !== agent.worktree?.branch)) {
        agent.worktree = worktree;
        changed = true;
      }
    }
    if (changed) this.touch(agent);
  }

  private touch(agent: Subagent): void {
    if (agent.parent !== null) this.bump(agent.parent);
    const group = this.groupOf.get(agent.id);
    if (!group) return;
    group.version += 1;
    this.changed.add(group);
  }
}

/// The agentId a Claude Code Agent call's result names (`agentId: a39e817af38ddf5e7 (…)`): the
/// last one, as Claude appends it after a finished subagent's report, which may itself say `agentId:`.
export function agentIdIn(text: string): string | undefined {
  return [...text.matchAll(/\bagentId:\s*([A-Za-z0-9_-]+)/g)].at(-1)?.[1];
}

/// The worktree a Claude Code Agent call's result reports for a subagent that ran in one and changed
/// something (`worktreePath: /repo/.claude/worktrees/x` and `worktreeBranch: worktree-x`, a line
/// each), or undefined.
export function worktreeIn(text: string): { path: string; branch?: string } | undefined {
  // The rest of the line: a worktree path may hold a space.
  const path = /^worktreePath:[ \t]*(\/[^\r\n]*?)[ \t]*$/m.exec(text)?.[1];
  if (!path) return undefined;
  const branch = /^worktreeBranch:[ \t]*(\S+)/m.exec(text)?.[1];
  return branch ? { path, branch } : { path };
}

/// Which running subagents nothing will end any more, and how they read: `turn` only the
/// current turn's foreground ones, else every one.
export type SubagentsLeft = { state: "completed" | "cancelled" | "disconnected"; turn: boolean };

/// Whom acpmux's record `kind` leaves running with no one to end them: a stopped turn's
/// foreground subagents (`cancelled`; the harness keeps background ones running), a completed
/// turn's foreground ones whose end the harness never sent (`completed`: the turn waited on them;
/// they read running for good, Leo's Inspector counted 5 running with about 3 live), a turn the
/// daemon lost (`outcome_unknown`), or, when the agent process behind the chat went away or
/// started again (an exit or stop, a reopen or resume, a new or ended host), every one, as
/// acpmux's own process table reads those records (hub/processes.rs).
export function subagentsLeft(kind: string, msg: any): SubagentsLeft | undefined {
  if (kind === "turn_result" && msg?.detail === "outcome_unknown") return { state: "disconnected", turn: true };
  if (kind === "turn_result" && msg?.status === "cancelled") return { state: "cancelled", turn: true };
  if (kind === "turn_result" && msg?.status === "completed") return { state: "completed", turn: true };
  return HARNESS_GONE.has(kind) ? { state: "disconnected", turn: false } : undefined;
}
/// Why `agent` stopped, when the pane knows: only a `cancelled` one has a reason. One this pane
/// asked to stop (the subagent's own Stop) the person stopped; a foreground one its own turn
/// started, stopped while the pane's Stop or a Send now (`cause`, given only for those) was
/// ending that turn, stopped for that (a background one outlives its turn's stop, so a turn's
/// stop says nothing about it); else the reason recorded before a rebuild. Anything else (Claude's own TaskStop, another client's cancel, a
/// Codex interrupt) has none: the line shows no reason rather than a guess.
export function stopReasonOf(
  agent: Pick<Subagent, "id" | "state" | "background">,
  stops: SubagentStops,
  cause: SubagentStopReason | undefined,
): SubagentStopReason | undefined {
  if (agent.state !== "cancelled") return undefined;
  if (stops.requested.has(agent.id)) return "user";
  if (cause && !agent.background) return cause;
  return stops.reasons.get(agent.id);
}

const HARNESS_GONE = new Set(["exited", "stopped", "reopened", "resumed", "host_started", "host_ended"]);

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
