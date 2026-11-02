import { AgentProgressStore } from "./agentProgressSource";
import type { AcpmuxRow } from "../model";
import { textFromContent } from "../direct";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSummaryVersion,
} from "../summary/transcriptPullRequests";
import { ChildRowView, type ChildEntry } from "./childRows";
import { hiddenCall, isPlumbingName, showsNothing } from "../hiddenTools";
import { applyRetry, applyRetryStep, type RetryState } from "./retryState";
import { mergeWorkflowAgents, workflowPhases, type WorkflowAgent, type WorkflowPhase } from "./workflowAgents";
import {
  type AgentRun,
  agentRun,
  agentRunOf,
  backgroundOutputPath,
  harnessFamily,
  harnessLabel,
  promptTitle,
  runModel,
  runReply,
} from "./agentRuns";

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
  /// `action` is a shell call's title, the command as typed (its call's ACP kind is `execute`).
  actionShell?: boolean;
  /// Tokens it has used and tool calls it has made so far (Claude's task progress).
  tokens?: number;
  toolUses?: number;
  /// A Claude workflow's agents: how many returned of how many started, and how many failed or wait
  /// for a slot when any do.
  agents?: { done: number; started: number; failed?: number; queued?: number };
  /// A Claude workflow's run (`wf_…`), which a resume of it names again; its phases and its agents
  /// by index (workflowAgents.ts), from acpmux's `workflow-agents-v1` updates.
  runId?: string;
  /// What a resume of it names again (`Workflow({scriptPath, resumeFromRunId, args})`): the script
  /// path Claude Code returned and the call's args, when acpmux sent them (its launch).
  scriptPath?: string;
  args?: unknown;
  phases?: WorkflowPhase[];
  workflowAgents?: ReadonlyMap<number, WorkflowAgent>;
  /// A Claude workflow Claude Code paused: its agents stopped, and a resume by `runId` runs it again.
  paused?: boolean;
  /// Monotonic event sequence for progress, including usage-only workflow updates.
  progressVersion?: number;
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
  /// worktree and branch its result reports (`worktreePath:`, `worktreeBranch:`). Session Info's
  /// Environment for the subagent reads them (session-info/subagentScope.ts).
  isolated?: boolean;
  cwd?: string;
  worktree?: { path: string; branch?: string };
  /// An acpmux child session explicitly recorded for a shell call: the protocol supplies its
  /// harness, model and effort. Command text and stdout never establish session identity.
  /// It has no `prompt`: Restart and Stop are a Claude subagent's.
  harness?: string;
  model?: string;
  effort?: string;
  command?: string;
  session?: string;
  host?: string;
  result?: string;
  lastMessage?: string;
  /// The acpmux sub-session it is (`acpmux run --parent`), by id: Open chat opens it, and its
  /// records (``reduceChild``) say its state and reply.
  child?: string;
  /// The acpmux session that started this sub-session. This is session lineage, not pane nesting;
  /// direct children keep `parent: null` so retry and automatic pane opening still apply.
  startedBySession?: string;
  /// acpmux's retry while one waits, whether acpmux can retry it, and the retry it gave up on
  /// (retryState.ts).
  retry?: RetryState;
  retryable?: boolean;
  retriedOut?: RetryState;
  /// Why it failed, as acpmux recorded it (`error`): its end line says it.
  error?: string;
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
type Step = { event: Event; update: any };
/// The most `acpmux run --parent` calls waiting for their sub-session's start at once.
const PENDING_CHILDREN = 16;
type Group = { id: string; at: number; version: number; ids: string[]; seq?: number };
type ChildIdentity = { name?: string; prompt?: string };
type PendingParent = {
  run: AgentRun;
  command: string;
  first: Step;
  last?: Step;
  identity: ChildIdentity;
  ambiguous: boolean;
};
type ViewRevisions = { activity: symbol; command: symbol; summary: object };

/// Folds a session's subagent records out of its transcript. Subagents the session spawns
/// between two pieces of its own text draw as one group row where the first one started; their
/// own updates, their spawn and state events, and the tool calls that started them draw no row.
export class SubagentFold {
  readonly progressSource = new AgentProgressStore();
  private readonly agents = new Map<string, Subagent>();
  /// The event that first introduced each agent, retained for a late top-level promotion.
  private readonly startedSeq = new Map<string, number>();
  /// Replay can show a child's spawn before the sender's own spawn. Keep the
  /// original record so the child can be moved under that sender later.
  private readonly pending = new Map<string, Map<string, Event>>();
  /// Native session ids that are the owning chat, rather than subagents. Codex collaboration
  /// metadata names the issuing thread; keeping this identity across replay prevents an echoed
  /// root update from becoming a child of the thread that happened to report it.
  private readonly rootThreads = new Set<string>();
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
  private readonly viewRevisions = new Map<string, ViewRevisions>();
  private readonly settledViews = new Map<string, { state: string; name: string }>();
  private readonly viewTools = new Map<string, Map<string, boolean>>();
  private readonly viewToolSummaries = new Map<string, Map<string, string>>();
  private readonly pendingReplySummaries = new Set<string>();
  /// The latest assistant message id per child, so a steer's new stream settles the prior reply.
  private readonly replyMessageIds = new Map<string, string>();
  /// Each subagent's incremental source fold and drawn rows, while its version holds.
  private readonly drawn = new Map<string, { version: number; view: ChildRowView; rows: AcpmuxRow[] }>();
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
  /// The acpmux session whose updates this folds (direct.ts sets the selected one). A Claude
  /// subagent's lines stream under `<session>/<its Agent call>` (acpmux
  /// claude_stdio/subagent_route.rs), which is also the id acpmux tags them with (``ownerOf``).
  session: string | undefined;
  /// Every id a record named as a subagent, a parent or an owner (``names``).
  private readonly named = new Set<string>();
  /// The chat's harness (`claude`, `codex`, a profile such as `claude-sr2`), when the pane knows
  /// it: a shell call starting an agent of its own family stays a command.
  harness: string | undefined;
  /// The agent each starting shell call is (``reduceRun``), by call id; the calls that start none.
  private readonly runs = new Map<string, string>();
  private readonly notRuns = new Set<string>();
  /// A background run's output file (Claude Code's "Output is being written to"), and the calls
  /// that read one: what such a read shows is the run's reply.
  private readonly runOutputs = new Map<string, string>();
  private readonly outputReads = new Map<string, string>();
  /// A parent-session call arrived while the chat's harness was unknown: once known, replay
  /// can associate the call with an explicit child-session record.
  deferredRun = false;
  /// `acpmux run --parent` calls whose sub-session acpmux has not said started (``reduceChild``):
  /// what each runs, its first update and its newest. The oldest go past PENDING_CHILDREN.
  private readonly parentCalls = new Map<string, PendingParent>();
  /// Active MCP starts can overlap a parent shell call. Completed starts leave an identity
  /// tombstone because their child may still be queued and arrive after the call ends.
  private readonly sessionStarts = new Map<string, ChildIdentity>();
  private readonly retiredStarts: ChildIdentity[] = [];
  /// The run each sub-session is, by its session id; the runs whose reply acpmux recorded.
  private readonly children = new Map<string, string>();
  private readonly recorded = new Set<string>();

  constructor(private readonly stops: SubagentStops = subagentStops()) {}

  /// Seeds the native root before a persisted event window is replayed. A malformed historical
  /// record can mention the root as a subagent, so this must happen before the first `apply`.
  /// True when a record folded already named the root (``names``): the fold repaired its tree
  /// here, and a pane that drew it folds again (direct.ts `seedRoots`).
  setRoot(id: string | undefined): boolean {
    if (typeof id !== "string" || id.length === 0 || this.rootThreads.has(id)) return false;
    this.rootThreads.add(id);
    const named = this.named.has(id);
    this.resolvePending(id, null, true);
    // A live update can arrive before the session summary. Remove that late phantom and promote
    // anything it had already acquired so a later root seed repairs the in-memory tree too.
    const phantom = this.agents.get(id);
    if (phantom) this.dropPhantom(id);
    // Children can name the root as parent without the root ever getting a row of its own.
    const promoted = [...this.agents.values()].filter((agent) => agent.parent === id);
    for (const agent of promoted) this.moveAgent(agent, null);
    return named;
  }
  /// Removes a root thread that was folded as a subagent before its identity was known.
  private dropPhantom(id: string): void {
    const groups = new Set<Group>([...this.groupOf.values(), ...this.changed, ...(this.open ? [this.open] : [])]);
    this.agents.delete(id);
    this.progressSource.remove(id);
    this.startedSeq.delete(id);
    const phantomGroup = this.groupOf.get(id);
    this.groupOf.delete(id);
    this.own.delete(id);
    this.drawn.delete(id);
    this.versions.delete(id);
    for (const group of groups) {
      if (!group.ids.includes(id)) continue;
      group.ids = group.ids.filter((child) => child !== id);
      this.changed.add(group);
    }
    if (phantomGroup) this.changed.add(phantomGroup);
    // An open batch the phantom emptied is not reused: later workers start a group of their own,
    // not the phantom's row and place.
    if (this.open && this.open.ids.length === 0) this.open = undefined;
    for (const parent of this.own.keys()) this.removeSpawn(parent, id);
  }
  /// The subagents whose end the harness reported (not one ``stopRunning`` guessed): a progress
  /// report that trails it (Claude's last task_progress) does not run one again.
  private readonly ended = new Set<string>();
  /// Each subagent's newest tool call, and every call it made: an update to an older one does not
  /// take its action back.
  private readonly latestCall = new Map<string, string>();
  /// Each subagent's calls whose ACP kind is `execute` (`agent\u0000call`): a shell call's title is its command.
  private readonly shellCalls = new Set<string>();
  private readonly calls = new Set<string>();
  /// Plumbing calls each subagent made (hiddenTools.ts): they and their results set no action.
  private readonly hiddenCalls = new Set<string>();
  /// The subagents a tool call started (Claude's Agent call, which its turn waits on): only these
  /// end with a completed turn. Codex's native children have none and outlive their turn.
  private readonly called = new Set<string>();

  /// Folds one session/update record; true when it belongs to subagents and draws no row.
  reduce(event: Event, update: any): boolean {
    const kind = update?.sessionUpdate;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    const sessionStart = startsSession(update);
    if (call && (sessionStart || this.sessionStarts.has(call))) {
      if (kind === "tool_call" || (kind === "tool_call_update" && !isTerminal(update.status))) {
        if (sessionStart) this.sessionStarts.set(call, sessionStart);
        const identity = this.sessionStarts.get(call);
        if (identity) this.markAmbiguous(identity);
      } else if (isTerminal(update.status)) {
        const identity = this.sessionStarts.get(call) ?? sessionStart;
        this.sessionStarts.delete(call);
        if (identity) this.retire(identity);
      }
    }
    const mux = event.msg?.params?._meta?.acpmux;
    const events: any[] = Array.isArray(mux?.subagents) ? mux.subagents : [];
    // Codex puts its collaboration item on the session update itself. Keep the event-level
    // fallback for older persisted records that lifted `_meta` beside `update`.
    const collaboration = update?._meta?.codex?.collaboration ?? event.msg?.params?._meta?.codex?.collaboration;
    const reporter = typeof collaboration?.senderThreadId === "string" ? collaboration.senderThreadId : undefined;
    // Only a spawnAgent's sender is the parent of the threads it lists (Rust's codex_legacy); a
    // `wait` or `closeAgent` names whoever waits, which says nothing of a worker it first meets.
    const sender = collaboration?.tool === "spawnAgent" ? reporter : undefined;
    const tag = typeof mux?.subagent === "string" ? mux.subagent : this.ownerOf(event.msg?.params?.sessionId);
    if (tag !== undefined) this.named.add(tag);
    // Met first through its progress, its spawn is older than what this fold read: not this turn's.
    const spawn = update?.sessionUpdate !== "subagent_progress";
    for (const change of events) {
      if (typeof change?.id !== "string" || this.rootThreads.has(change.id)) continue;
      const rootRepair =
        typeof change.parent === "string" &&
        this.rootThreads.has(change.parent) &&
        (reporter === undefined || this.rootThreads.has(reporter));
      const normalized =
        sender === undefined
          ? rootRepair
            ? { ...change, parent: null, __rootRepair: true }
            : change
          : {
              ...change,
              parent: this.parentFor(sender, change.parent, change.id, event),
              ...(rootRepair ? { __rootRepair: true } : {}),
            };
      const authoritative =
        sender !== undefined &&
        (this.rootThreads.has(sender) || (this.agents.has(sender) && this.canParent(change.id, sender)));
      this.apply(normalized, event, spawn, authoritative);
    }
    // An update acpmux tagged with the chat's own session is the chat's (``isChat``).
    const owner = tag !== undefined && !this.isChat(tag) ? this.agents.get(tag) : undefined;
    // A subagent's own `acpmux run --parent` never becomes one of the chat's calls, but its child
    // comes to the chat's log too: it competes for the parent's child records, as a start_session does.
    if (tag !== undefined && !this.isChat(tag) && call) this.reduceNestedRun(`${tag}\u0000${call}`, update);
    // A tail page can start after the child's spawn. Its ownership tag still keeps its work
    // out of the parent transcript; retain that work for its own view without inventing a
    // lifecycle row. Later progress/spawn metadata supplies the child's identity as usual.
    if (tag !== undefined && !this.isChat(tag) && !owner) {
      const spawnCall = call !== undefined && this.spawnCalls.has(call);
      if (kind !== "subagent_spawned" && kind !== "subagent_state_update" && !spawnCall)
        this.record(tag, { event, update });
      return true;
    }
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
      if (tool && update.title && newest) {
        owner.action = String(update.title);
        // A shell call's title is its command as typed (ACP kind `execute`); the tray says it in words.
        // An update that omits its kind keeps what its own call said, never another call's.
        const key = call === undefined ? undefined : `${owner.id}\u0000${call}`;
        if (key && typeof update.kind === "string") {
          if (update.kind === "execute") this.shellCalls.add(key);
          else this.shellCalls.delete(key);
        }
        const shell =
          update.kind === "execute" || (update.kind === undefined && key !== undefined && this.shellCalls.has(key));
        if (shell) owner.actionShell = true;
        else delete owner.actionShell;
      }
      const kind = update?.sessionUpdate;
      // The Agent call that spawned it is the parent's, not a step of its own.
      const spawnCall = typeof update?.toolCallId === "string" && this.spawnCalls.has(update.toolCallId);
      if (kind !== "subagent_spawned" && kind !== "subagent_state_update" && !spawnCall)
        this.record(owner.id, { event, update });
      this.touch(owner);
      return true;
    }
    if (kind === "subagent_spawned" || kind === "subagent_state_update" || kind === "subagent_progress") return true;
    if (this.reduceRun(event, update)) return true;
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

  /// Whether shell call `call` started an agent, which draws as that agent and not as the call.
  isRun(call: string): boolean {
    return this.runs.has(call);
  }

  /// A call becomes a session card only after `reduceChild` receives its explicit child-session
  /// record. Parsing a command only locates a possible parent call; ordinary Bash stays a tool.
  private reduceRun(event: Event, update: any): boolean {
    const kind = update?.sessionUpdate;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    if (!call) return false;
    const known = this.runs.get(call);
    if (kind === "background_task_update") {
      const agent = known ? this.agents.get(known) : undefined;
      // A `--parent` call still waiting for its child's start that ended starts none.
      if (!agent && isTerminal(update.state)) {
        this.retire(this.parentCalls.get(call)?.identity);
        this.parentCalls.delete(call);
        this.notRuns.add(call);
      }
      if (!agent) return false;
      const state = update.state;
      // Every terminal state ends it (a timed-out run failed, a stopped one was cancelled): none
      // leaves its card running.
      const timedOut = String(state).startsWith("time");
      const failed = state === "failed" || timedOut || (Number.isInteger(update.exitCode) && update.exitCode !== 0);
      const cancelled = state === "stopped" || state === "cancelled";
      if (isTerminal(state)) this.endRun(agent, failed ? "failed" : cancelled ? "cancelled" : "completed", event.at);
      return true;
    }
    if (kind !== "tool_call" && kind !== "tool_call_update") return false;
    // Only a call that names its input, or one already known to read a run's output: never a scan
    // per streamed update.
    const reads = this.outputReads.has(call) || (this.runOutputs.size > 0 && update?.rawInput);
    if (reads) this.readOutput(call, update);
    if (known) {
      this.updateRun(this.agents.get(known)!, event, update);
      return true;
    }
    if (this.notRuns.has(call)) return false;
    const pending = this.parentCalls.get(call);
    if (pending) {
      // Drawn as the call until acpmux says its sub-session started. One that ended (not one moved
      // to the background) started none, or its start already came.
      pending.last = { event, update };
      const ended = isTerminal(update.status);
      if (ended && !(update.status === "completed" && backgroundOutputPath(outputOf(update)))) {
        this.retire(pending.identity);
        this.parentCalls.delete(call);
        this.notRuns.add(call);
      }
      return false;
    }
    const command = update?.rawInput?.command;
    // A call whose command has not come yet may still be one.
    if (typeof command !== "string" && !Array.isArray(command)) return false;
    const run = typeof command === "string" ? agentRun(command) : agentRunOf(command.map(String));
    const line = typeof command === "string" ? command : command.join(" ");
    // A sub-session of a chat (acpmux #25019): its records name its harness, even one the command
    // does not, and only this chat's own children come to its log.
    if (run?.parent !== undefined && this.harness) {
      // Child names are made unique by the daemon, and prompts can be identical. Neither
      // distinguishes concurrent shell starts, even after one call ends or fails.
      const identity = runIdentity(run);
      const ambiguous =
        [...this.parentCalls.values()].some((pending) => identitiesOverlap(identity, pending.identity)) ||
        [...this.sessionStarts.values()].some((start) => identitiesOverlap(identity, start)) ||
        this.retiredStarts.some((start) => identitiesOverlap(identity, start));
      for (const pending of this.parentCalls.values())
        if (identitiesOverlap(identity, pending.identity)) pending.ambiguous = true;
      this.parentCalls.set(call, { run, command: line, first: { event, update }, identity, ambiguous });
      for (const old of this.parentCalls.keys()) {
        if (this.parentCalls.size <= PENDING_CHILDREN) break;
        this.retire(this.parentCalls.get(old)?.identity);
        this.parentCalls.delete(old);
        this.notRuns.add(old);
      }
      return false;
    }
    if (run?.parent !== undefined && !this.harness) this.deferredRun = true;
    this.notRuns.add(call);
    return false;
  }

  /// The agent shell call `call` started, from its first update.
  private startRun(call: string, { event, update }: Step, run: AgentRun, command: string): Subagent {
    const description = text(update.rawInput.description);
    const model = runModel(run);
    const label = run.harness ? harnessLabel(run.harness) : undefined;
    const agent: Subagent = {
      id: `run:${call}`,
      parent: null,
      name: promptTitle(run.prompt) ?? description ?? label ?? "acpmux",
      ...(description && { task: description }),
      ...((label || model) && { kind: [label, model].filter(Boolean).join(" · ") }),
      state: "running",
      startedAt: event.at,
      command,
      ...(run.harness && { harness: run.harness }),
      ...(model && { model }),
      ...(run.effort && { effort: run.effort }),
      ...(run.session && { session: run.session }),
      ...(run.host && { host: run.host }),
      ...(update.rawInput.run_in_background === true && { background: true }),
    };
    this.runs.set(call, agent.id);
    this.agents.set(agent.id, agent);
    this.startedSeq.set(agent.id, event.seq);
    this.named.add(agent.id);
    this.turn.add(agent.id);
    // A foreground run ends with its call; the turn's end ends one whose end never came.
    if (!agent.background) this.called.add(agent.id);
    // Its own card in the transcript, where it started: never a batch with Claude's subagents.
    const group: Group = { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [agent.id], seq: event.seq };
    this.groupOf.set(agent.id, group);
    this.open = undefined;
    this.updateRun(agent, event, update);
    return agent;
  }

  /// A `subsession` record on the chat's log (acpmux #25019, `hub/subsession_results.rs`). A child
  /// of another family that an `acpmux run --parent` call of the chat started is that call's run,
  /// with acpmux's harness, model and effort; each `turn_ended` says its state and its reply. A
  /// child the `start_session` tool started has its card already (SubsessionCallCard.tsx). Returns
  /// the call whose row the run now stands for.
  /// A `subagent_retry` record (retryState.ts ``applyRetryStep``): whether acpmux gave up on one.
  reduceRetryStep(record: any): void {
    const agent = typeof record?.subagentId === "string" ? this.agents.get(record.subagentId) : undefined;
    if (agent && applyRetryStep(agent, record)) this.touch(agent);
  }

  reduceChild(event: Event, record: any): string | undefined {
    const child = text(record?.childSessionId);
    if (!child) return undefined;
    if (record.event === "started") return this.startChild(record, child);
    const agent = record.event === "turn_ended" ? this.agents.get(this.children.get(child) ?? "") : undefined;
    if (!agent) return undefined;
    // Each turn repeats the child's current model and effort. Keep the previous value when the
    // producer omits a field, but honor an explicit null as acpmux's deletion signal.
    for (const key of ["model", "effort"] as const) {
      if (!Object.prototype.hasOwnProperty.call(record, key)) continue;
      if (record[key] === null) delete agent[key];
      else if (typeof record[key] === "string") agent[key] = record[key];
    }
    // Each turn's end says the whole of it: a turn that said nothing has no reply, not the last one's.
    const said = text(record.result?.reply) ?? text(record.result?.error);
    if (said) {
      agent.result = said;
      agent.lastMessage = said;
    } else {
      delete agent.result;
      delete agent.lastMessage;
    }
    this.recorded.add(agent.id);
    agent.state = record.state === "done" ? "completed" : record.state === "cancelled" ? "cancelled" : "failed";
    agent.endedAt = event.at;
    this.ended.add(agent.id);
    this.forgetOutput(agent.id);
    this.touch(agent);
    return undefined;
  }

  private startChild(record: any, child: string): string | undefined {
    if (this.children.has(child)) return undefined;
    // The call that named it (`-n`) or asked it what it was asked: never a guess, since a child the
    // start_session tool started meanwhile has the same parent. A call that says neither (its
    // prompt in a file) stays its command.
    const name = daemonShortName(record.shortName);
    const asked = promptKey(record.prompt);
    // A name is the surer of the two: a different explicit name cannot fall back to its prompt.
    // The daemon allocates `base-2`, `base-3`, ... when a requested short name is taken. When a
    // start requested that base, the suffix has no provenance in this record; never let it promote
    // a shell call whose requested name happens to equal the renamed child. An explicit `-n fix-2`
    // with no competing `fix` is its own name.
    if (name && this.mayBeRenamed(name)) return undefined;
    const identity = { name, prompt: asked };
    if (this.retiredStarts.some((start) => identitiesOverlap(start, identity))) return undefined;
    // The call's requested name in the daemon's spelling (`-n Alpha` claims `alpha`).
    const calls = [...this.parentCalls];
    const call =
      calls.find(([, pending]) => name !== undefined && pending.identity.name === name)?.[0] ??
      calls.find(
        ([, pending]) => !pending.identity.name && asked !== undefined && pending.identity.prompt === asked,
      )?.[0];
    const pending = call !== undefined ? this.parentCalls.get(call) : undefined;
    if (call === undefined || !pending || pending.ambiguous) return undefined;
    this.parentCalls.delete(call);
    const harness = text(record.harness);
    if (!harness || !this.harness || harnessFamily(harness) === harnessFamily(this.harness)) {
      this.notRuns.add(call);
      return undefined;
    }
    const model = text(record.model);
    const effort = text(record.effort);
    const prompt = pending.run.prompt ?? text(record.prompt);
    // Identity comes entirely from the session record, including absent metadata. CLI flags
    // describe a requested run and cannot fill gaps in what the protocol actually observed.
    const run: AgentRun = {
      harness,
      ...(model && { model }),
      ...(effort && { effort }),
      ...(prompt && { prompt }),
      ...(name && { session: name }),
      ...(text(record.host) && { host: text(record.host) }),
    };
    const agent = this.startRun(call, pending.first, run, pending.command);
    agent.child = child;
    const startedBy = text(record.startedBy);
    if (startedBy) agent.startedBySession = startedBy;
    if (!promptTitle(prompt)) agent.name = text(record.title) ?? agent.name;
    this.children.set(child, agent.id);
    if (pending.last) this.updateRun(agent, pending.last.event, pending.last.update);
    return call;
  }

  /// A subagent's shell call (`key` is its tag and call id): while it runs, an `acpmux run --parent`
  /// it made is a competing start; once it ends, its identity is a tombstone, since its child may
  /// still arrive.
  private reduceNestedRun(key: string, update: any): void {
    const kind = update?.sessionUpdate;
    if (kind !== "tool_call" && kind !== "tool_call_update") return;
    if (!this.sessionStarts.has(key)) {
      const command = update?.rawInput?.command;
      if (typeof command !== "string" && !Array.isArray(command)) return;
      const run = typeof command === "string" ? agentRun(command) : agentRunOf(command.map(String));
      if (run?.parent === undefined) return;
      this.sessionStarts.set(key, runIdentity(run));
    }
    const identity = this.sessionStarts.get(key)!;
    if (isTerminal(update.status)) {
      this.sessionStarts.delete(key);
      this.retire(identity);
    } else this.markAmbiguous(identity);
  }

  private markAmbiguous(identity: ChildIdentity): void {
    for (const pending of this.parentCalls.values())
      if (identitiesOverlap(identity, pending.identity)) pending.ambiguous = true;
  }

  /// `name` ends in `-N` and a pending, running or retired start requested it without that suffix.
  private mayBeRenamed(name: string): boolean {
    const base = /-\d+$/.test(name) ? name.replace(/-\d+$/, "") : undefined;
    if (!base) return false;
    const identities = [
      ...[...this.parentCalls.values()].map((pending) => pending.identity),
      ...this.sessionStarts.values(),
      ...this.retiredStarts,
    ];
    return identities.some((identity) => identity.name === base);
  }

  private retire(identity: ChildIdentity | undefined): void {
    // A start that said neither name nor prompt (`--prompt-file`) has nothing to compare: kept,
    // it would overlap every later start forever.
    if (!identity || (!identity.name && !identity.prompt)) return;
    if (this.retiredStarts.some((start) => sameIdentity(start, identity))) return;
    this.retiredStarts.push(identity);
  }

  private updateRun(agent: Subagent, event: Event, update: any): void {
    this.record(agent.id, { event, update });
    const status = update?.status;
    if (agent.state === "running" && (status === "completed" || status === "failed")) {
      const output = outputOf(update);
      const file = status === "completed" ? backgroundOutputPath(output) : undefined;
      // Moved to the background (by the call, or by Claude Code while it ran): it runs on.
      if (file || (status === "completed" && agent.background)) {
        agent.background = true;
        if (file) this.runOutputs.set(file, agent.id);
      } else {
        const reply = runReply(output);
        // What acpmux recorded it said is its reply, not what the shell printed of it.
        if (reply && !this.recorded.has(agent.id)) {
          agent.result = reply;
          agent.lastMessage = reply;
        }
        this.endRun(agent, status === "failed" ? "failed" : "completed", event.at);
        return;
      }
    }
    this.touch(agent);
  }

  private endRun(agent: Subagent, state: string, at: number): void {
    if (agent.state !== "running") return;
    agent.state = state;
    agent.endedAt = at;
    this.ended.add(agent.id);
    // Its file was read while it ran: a read after its end says what that one said, and is drawn.
    if (agent.result) this.forgetOutput(agent.id);
    this.touch(agent);
  }

  private forgetOutput(id: string): void {
    for (const [file, owner] of this.runOutputs) if (owner === id) this.runOutputs.delete(file);
  }

  /// A call that reads a background run's output file (a Read of it, a `cat` or a `tail`): once it
  /// returns, what it read is the run's reply.
  private readOutput(call: string, update: any): void {
    let id = this.outputReads.get(call);
    if (!id) {
      const input = update?.rawInput;
      const path = text(input?.file_path) ?? text(input?.path);
      const command = typeof input?.command === "string" ? input.command : undefined;
      for (const [file, agent] of this.runOutputs)
        if (path === file || command?.includes(file)) {
          id = agent;
          this.outputReads.set(call, agent);
        }
    }
    const agent = id ? this.agents.get(id) : undefined;
    if (!agent || update?.status !== "completed") return;
    this.outputReads.delete(call);
    const reply = runReply(withoutLineNumbers(outputOf(update)));
    if (reply && reply !== agent.result && !this.recorded.has(agent.id)) {
      agent.result = reply;
      agent.lastMessage = reply;
      this.touch(agent);
    }
    // Read once the run ended, its file says nothing more.
    if (agent.state !== "running") this.forgetOutput(agent.id);
  }

  private parentFor(sender: string, recordedParent: unknown, child: string, event: Event): string | null {
    if (this.rootThreads.has(sender)) return null;
    if (this.agents.has(sender)) return this.canParent(child, sender) ? sender : null;
    if (!this.pending.has(sender)) this.pending.set(sender, new Map());
    this.pending.get(sender)!.set(child, event);
    const recorded =
      typeof recordedParent === "string" && !this.rootThreads.has(recordedParent) ? recordedParent : undefined;
    return recorded !== undefined && this.canParent(child, recorded) ? recorded : null;
  }

  /// Whether putting `child` under `parent` would close a lineage cycle.
  private canParent(child: string, parent: string): boolean {
    if (child === parent) return false;
    let at: string | undefined = parent;
    for (let i = 0; i <= this.agents.size; i += 1) {
      if (at === child) return false;
      at = this.agents.get(at)?.parent ?? undefined;
      if (at === undefined) return true;
    }
    return false;
  }

  private forgetPending(child: string): void {
    for (const [sender, pending] of this.pending) {
      pending.delete(child);
      if (pending.size === 0) this.pending.delete(sender);
    }
  }

  private resolvePending(sender: string, parent: string | null, authoritative = false): void {
    const pending = this.pending.get(sender);
    if (!pending) return;
    this.pending.delete(sender);
    for (const [child, event] of pending) {
      const agent = this.agents.get(child);
      if (agent) {
        if (authoritative) this.forgetPending(child);
        this.moveAgent(agent, parent, event);
      }
    }
  }

  private removeSpawn(parent: string, child: string): void {
    const entries = this.own.get(parent);
    if (!entries) return;
    const kept = entries.filter((entry) => entry.spawned !== child);
    if (kept.length === entries.length) return;
    this.own.set(parent, kept);
    // ChildRowView consumes an append-only log; removing an entry resets its cursor and groups.
    this.drawn.delete(parent);
    this.bumpViewRevision(parent);
    this.bump(parent);
  }

  private moveAgent(agent: Subagent, parent: string | null, event?: Event): void {
    if (agent.parent === parent || (parent !== null && (!event || !this.canParent(agent.id, parent)))) return;
    if (agent.parent !== null) this.removeSpawn(agent.parent, agent.id);
    const previous = this.groupOf.get(agent.id);
    if (previous) {
      previous.ids = previous.ids.filter((child) => child !== agent.id);
      previous.version += 1;
      this.changed.add(previous);
      this.groupOf.delete(agent.id);
    }
    agent.parent = parent;
    if (parent === null) {
      const group: Group = {
        id: `${SUBAGENTS}-root-${agent.id}`,
        at: agent.startedAt,
        version: 0,
        ids: [agent.id],
        seq: this.startedSeq.get(agent.id),
      };
      this.groupOf.set(agent.id, group);
      this.changed.add(group);
    } else if (event) this.record(parent, { event, spawned: agent.id });
    this.bump(agent.id);
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
      // A run's output file says nothing more once it ended.
      if (agent.command) this.forgetOutput(agent.id);
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
      ...(group.seq !== undefined ? { seq: group.seq } : {}),
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
        const view = drawn?.view ?? new ChildRowView(id);
        drawn = { version, view, rows: view.update(entries, this.agents, version) };
        this.drawn.set(id, drawn);
      }
      // Publish revisions from the first chunk, avoiding the unversioned O(rows) fallback.
      const revisions = this.viewRevisions.get(id) ?? {
        activity: Symbol(),
        command: Symbol(),
        summary: {},
      };
      this.viewRevisions.set(id, revisions);
      markPullRequestActivityVersion(drawn.rows, revisions.activity);
      markPullRequestCommandVersion(drawn.rows, revisions.command);
      markTranscriptSummaryVersion(drawn.rows, revisions.summary);
      views[id] = drawn.rows;
    }
    return views;
  }

  private record(id: string, entry: ChildEntry): void {
    const entries = this.own.get(id) ?? [];
    entries.push(entry);
    this.own.set(id, entries);
    const update = entry.update;
    const state = this.agents.get(id)?.state;
    const active = state === undefined || state === "running";
    let streaming =
      active && (update?.sessionUpdate === "agent_message_chunk" || update?.sessionUpdate === "agent_thought_chunk");
    let replySettled = false;
    const messageId = typeof update?.messageId === "string" ? update.messageId : undefined;
    const messageChanged =
      update?.sessionUpdate === "agent_message_chunk" &&
      !!messageId &&
      this.replyMessageIds.has(id) &&
      this.replyMessageIds.get(id) !== messageId;
    if (messageChanged && textFromContent(update?.content)) {
      this.pendingReplySummaries.delete(id);
      this.bumpViewRevision(id);
    }
    if (streaming && textFromContent(update?.content)) {
      if (update?.sessionUpdate === "agent_message_chunk") {
        this.pendingReplySummaries.add(id);
        if (messageId) this.replyMessageIds.set(id, messageId);
      }
      // The first thought can settle a reply; subsequent thought deltas keep its summary cached.
      if (update?.sessionUpdate === "agent_thought_chunk" && this.pendingReplySummaries.delete(id)) streaming = false;
    }
    if (update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update") {
      const call = String(update.toolCallId ?? `tool-${entry.event.seq}`);
      // ToolSearch is hidden from the child view, so it cannot settle the visible reply. Keep
      // the marker until a rendered tool or thought actually follows it.
      const hidden = hiddenCall(this.hiddenCalls, `${id}\u0000${call}`, update);
      const tools = this.viewTools.get(id) ?? new Map<string, boolean>();
      const summaries = this.viewToolSummaries.get(id) ?? new Map<string, string>();
      const summaryKey = JSON.stringify({
        title: update.title,
        name: update.name,
        description: update.description ?? update.rawInput?.description,
        command: update.command ?? update.rawInput?.command,
        inputSummary: update.inputSummary,
        kind: update.kind,
        status: update.status,
        exitCode: update.exitCode,
        startedAt: update.startedAt,
        background: update.background ?? update.rawInput?.run_in_background,
        rawInput: update.rawInput,
      });
      const metadataChanged = summaries.has(call) && summaries.get(call) !== summaryKey;
      summaries.set(call, summaryKey);
      this.viewToolSummaries.set(id, summaries);
      // A page opened after a ToolSearch started has only its title-less result. Treat a result
      // with no renderable content as hidden too, matching direct transcript folding.
      const unknownHiddenResult =
        update?.sessionUpdate === "tool_call_update" && !tools.has(call) && (!update.title || showsNothing(update));
      replySettled = !hidden && !unknownHiddenResult && this.pendingReplySummaries.delete(id);
      if (hidden || unknownHiddenResult) {
        this.bump(id);
        return;
      }
      const settled =
        update.status === undefined ? tools.get(call) : update.status === "completed" || update.status === "failed";
      // New tools and every update of a settled tool change the summary, even without a status.
      // A running-tool update can arrive immediately after the reply was settled; keep the
      // reply's settled state authoritative so the child summary revision is published.
      streaming = tools.has(call) && !settled && !replySettled;
      tools.set(call, settled ?? false);
      this.viewTools.set(id, tools);
      if (metadataChanged) this.bumpViewRevision(id);
    }
    if (replySettled) streaming = false;
    if (!streaming) this.bumpViewRevision(id);
    this.bump(id);
  }

  private bumpViewRevision(id: string): void {
    this.viewRevisions.set(id, { activity: Symbol(), command: Symbol(), summary: {} });
  }

  private settleView(agent: Subagent): boolean {
    const previous = this.settledViews.get(agent.id);
    if (previous?.state === agent.state && previous.name === agent.name) return false;
    this.settledViews.set(agent.id, { state: agent.state, name: agent.name });
    const last = this.own.get(agent.id)?.at(-1);
    // Completion can precede the final reply chunk. Preserve that completed tail
    // before a resume makes new chunks stream again.
    if (last && previous && previous.state !== "running" && agent.state === "running") last.settled = true;
    if (agent.state !== "running") {
      this.pendingReplySummaries.delete(agent.id);
      this.replyMessageIds.delete(agent.id);
    }
    this.bumpViewRevision(agent.id);
    this.bump(agent.id);
    return true;
  }

  private bump(id: string): void {
    this.versions.set(id, (this.versions.get(id) ?? 0) + 1);
  }

  /// Whether `id` is the chat's own session. A Codex child reports its parent thread's state
  /// under its own session, and acpmux used to record that as a spawn: the chat became its
  /// own subagent, nested under that child, and every later subagent nested under the chat (Leo's
  /// staircase, 2026-10-22). Records written then still say so, so the fold reads them by lineage.
  /// The subagent an untagged update streams under, from its own `sessionId`: a known subagent's
  /// id, or the chat's session with a subagent part (`<session>/<Agent call>`). acpmux tags a
  /// subagent's lines with that id, but a hub that just adopted its host lost its subagent tree
  /// until the subagent's next progress event, and the lines between came untagged. Folded as the
  /// chat's own, a background subagent's call drew as a "Running grep …" row under the finished
  /// turn and never ended there, since its end came tagged (Leo, 2026-11-01: "why does it say
  /// you're still running grep"). Its own view and the running tray show it instead.
  private ownerOf(sessionId: unknown): string | undefined {
    if (typeof sessionId !== "string" || sessionId.length === 0 || this.isChat(sessionId)) return undefined;
    if (this.agents.has(sessionId)) return sessionId;
    const session = this.session;
    return session && sessionId.length > session.length + 1 && sessionId.startsWith(`${session}/`)
      ? sessionId
      : undefined;
  }

  private isChat(id: string): boolean {
    return id === this.chat || this.rootThreads.has(id);
  }

  /// Whether a folded record named `id` as a subagent, a subagent's parent or an update's owner.
  names(id: string): boolean {
    return this.named.has(id);
  }

  private apply(change: any, event: Event, spawn = true, authoritative = false): void {
    if (typeof change?.id !== "string") return;
    this.named.add(change.id);
    if (typeof change.parent === "string") this.named.add(change.parent);
    if (this.isChat(change.id)) return;
    if (authoritative || change.__rootRepair) this.forgetPending(change.id);
    if (typeof change.toolCallId === "string") {
      this.spawnCalls.add(change.toolCallId);
      this.spawnedBy.set(change.toolCallId, change.id);
    }
    let agent = this.agents.get(change.id);
    if (!agent) {
      const parent =
        typeof change.parent === "string" && !this.isChat(change.parent) && this.canParent(change.id, change.parent)
          ? change.parent
          : null;
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
      this.startedSeq.set(agent.id, event.seq);
      if (spawn) this.turn.add(agent.id);
      if (typeof change.toolCallId === "string") this.called.add(agent.id);
      if (parent === null) {
        this.open ??= { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [], seq: event.seq };
        this.open.ids.push(agent.id);
        this.groupOf.set(agent.id, this.open);
      } else this.record(parent, { event, spawned: agent.id });
      this.resolvePending(agent.id, agent.id);
    } else {
      if (authoritative || change.__rootRepair) this.moveAgent(agent, change.parent, event);
      agent.name = text(change.name) ?? agent.name;
      agent.task = text(change.task) ?? agent.task;
      agent.kind = text(change.kind) ?? agent.kind;
      agent.prompt = text(change.prompt) ?? agent.prompt;
    }
    // Claude's progress names its last tool when it has no summary: plumbing is never what it does.
    const action = text(change.action);
    if (action && !isPlumbingName(action)) {
      agent.action = action;
      delete agent.actionShell;
    }
    agent.tokens = count(change.tokens) ?? agent.tokens;
    agent.toolUses = count(change.toolUses) ?? agent.toolUses;
    // Optional orchestration fields may be removed explicitly when a resumed harness no longer
    // reports them. Keep omitted fields unchanged, but do not leave stale values after `null`.
    for (const key of ["model", "effort", "lastMessage"] as const) {
      if (!Object.prototype.hasOwnProperty.call(change, key)) continue;
      if (change[key] === null) delete agent[key];
      else {
        const value = text(change[key]);
        if (value !== undefined) agent[key] = value;
      }
    }
    if (change.background === true) agent.background = true;
    const done = count(change.agents?.done);
    const started = count(change.agents?.started);
    if (done !== undefined && started !== undefined) {
      const failed = count(change.agents?.failed);
      const queued = count(change.agents?.queued);
      agent.agents = { done, started, ...(failed ? { failed } : {}), ...(queued ? { queued } : {}) };
    }
    agent.runId = text(change.runId) ?? agent.runId;
    agent.scriptPath = text(change.scriptPath) ?? agent.scriptPath;
    if (change.args !== undefined && change.args !== null) agent.args = change.args;
    agent.phases = workflowPhases(change.phases) ?? agent.phases;
    agent.workflowAgents = mergeWorkflowAgents(
      agent.workflowAgents,
      change.workflowAgents,
      change.workflowAgentsFull === true,
    );
    if (!spawn) agent.progressVersion = event.seq;
    if (change.reason === "paused") agent.paused = true;
    applyRetry(agent, change);
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
    // A subagent that runs again, or finished, gave nothing up.
    if (agent.state === "running" || agent.state === "completed") delete agent.retriedOut;
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
    this.progressSource.updateAgent(agent);
    const summaryChanged = this.settleView(agent);
    if (agent.parent !== null) {
      if (summaryChanged) this.bumpParentViews(agent.parent);
      else this.bump(agent.parent);
    }
    const group = this.groupOf.get(agent.id);
    if (!group) return;
    group.version += 1;
    this.changed.add(group);
  }

  private bumpParentViews(id: string): void {
    // Historical records can make two agents each other's parent (an echoed root): walk once.
    const seen = new Set<string>();
    for (let at: string | null | undefined = id; typeof at === "string" && !seen.has(at);) {
      seen.add(at);
      this.bumpViewRevision(at);
      this.bump(at);
      at = this.agents.get(at)?.parent;
    }
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
/// they read running for good, Leo's Session Info counted 5 running with about 3 live), a turn the
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

/// A tool call's output: its content's text (Claude Code), else its raw output's.
function outputOf(update: any): string | undefined {
  const parts = Array.isArray(update?.content) ? update.content : [];
  const said = parts
    .map((part: any) =>
      typeof part?.content?.text === "string" ? part.content.text : typeof part?.text === "string" ? part.text : "",
    )
    .join("");
  if (said) return said;
  const raw = update?.rawOutput;
  if (typeof raw === "string") return raw;
  return typeof raw?.output === "string" ? raw.output : typeof raw?.stdout === "string" ? raw.stdout : undefined;
}

/// A file Claude Code's Read returned, without the line numbers it puts before each line.
function withoutLineNumbers(output: string | undefined): string | undefined {
  if (!output) return output;
  const lines = output.split("\n");
  const numbered = /^\s*\d+(?:\t|→)/;
  return lines.every((line) => !line.trim() || numbered.test(line))
    ? lines.map((line) => line.replace(numbered, "")).join("\n")
    : output;
}

const HARNESS_GONE = new Set(["exited", "stopped", "reopened", "resumed", "host_started", "host_ended"]);

/// A prompt's start as acpmux's `started` record quotes it (masked, its whitespace as it was): what a
/// call's own prompt is matched by.
function promptKey(prompt: unknown): string | undefined {
  const start = typeof prompt === "string" ? prompt.replace(/\s+/g, " ").trim().slice(0, 60) : "";
  return start || undefined;
}

/// Both MCP servers expose start_session; Claude names the tool, Codex nests its arguments.
/// An unknown server's identically named tool is conservatively a possible competing start.
function startsSession(update: any): ChildIdentity | undefined {
  const named = [update?._meta?.claude?.tool, update?.title, update?.rawInput?.tool].some(
    (name) => typeof name === "string" && /(?:^|[_.])start_session(?: call)?$/.test(name),
  );
  if (!named) return undefined;
  const input = update?.rawInput;
  const args = input && typeof input.arguments === "object" && input.arguments !== null ? input.arguments : input;
  return {
    ...(daemonShortName(args?.name) && { name: daemonShortName(args.name) }),
    ...(promptKey(args?.prompt) && { prompt: promptKey(args.prompt) }),
  };
}

function runIdentity(run: AgentRun): ChildIdentity {
  return {
    ...(daemonShortName(run.session) && { name: daemonShortName(run.session) }),
    ...(promptKey(run.prompt) && { prompt: promptKey(run.prompt) }),
  };
}

/// A child record with no call id is safe to pair only when no other candidate could have
/// produced the same name or prompt. Distinct explicit names are deterministic even with the
/// same prompt; an absent name keeps prompt matching conservative.
function identitiesOverlap(a: ChildIdentity, b: ChildIdentity): boolean {
  if (a.name && b.name) return nameFamily(a.name) === nameFamily(b.name);
  if (a.prompt && b.prompt) return a.prompt === b.prompt;
  return true;
}

/// `claim_name` reserves the requested base then appends `-2`, `-3`, ...; compare the full
/// rename family when call provenance is absent. Unrelated names such as alpha and beta remain
/// independent, while alpha, alpha-2 and alpha-2-2 cannot be paired safely.
function nameFamily(name: string): string {
  return name.replace(/(?:-\d+)+$/, "");
}

/// Mirrors acpmux `short_name_of`: Unicode words, lowercased and joined by dashes, capped at
/// forty characters. Matching the daemon's claimed spelling is required before family matching;
/// raw request text (`Alpha`, `review/router`) is not protocol identity.
function daemonShortName(value: unknown): string | undefined {
  const source = text(value);
  if (!source) return undefined;
  let out = "";
  for (const word of source.split(/[^\p{Letter}\p{Number}]+/u).filter(Boolean)) {
    const lower = word.toLowerCase();
    const next = out ? `${out}-${lower}` : lower;
    if (Array.from(next).length > 40) {
      if (!out) out = Array.from(next).slice(0, 40).join("");
      break;
    }
    out = next;
  }
  return out || "task";
}

function sameIdentity(a: ChildIdentity, b: ChildIdentity): boolean {
  return a.name === b.name && a.prompt === b.prompt;
}

function isTerminal(status: unknown): boolean {
  return ["completed", "failed", "stopped", "cancelled", "timed_out", "timed-out", "timeout"].includes(String(status));
}

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
