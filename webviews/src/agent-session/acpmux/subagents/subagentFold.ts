import type { AcpmuxRow } from "../model";
import {
  markPullRequestActivityVersion,
  markPullRequestCommandVersion,
  markTranscriptSummaryVersion,
} from "../summary/transcriptPullRequests";
import { childRows, type ChildEntry } from "./childRows";
import { hiddenCall, isPlumbingName } from "../hiddenTools";
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
  /// A shell call that started an agent of another family (`codex exec`, `acpmux run`;
  /// agentRuns.ts) is that agent: its harness (its mark), its model and effort ("gpt-6-astra
  /// xhigh"), the command as the call ran it, the acpmux session it made and the other machine it
  /// runs on, and what it finally said (``runReply``) once it ended. `kind` is "Codex · gpt-6-astra
  /// xhigh". It has no `prompt`: Restart and Stop are a Claude subagent's.
  harness?: string;
  model?: string;
  command?: string;
  session?: string;
  host?: string;
  result?: string;
  /// The acpmux sub-session it is (`acpmux run --parent`), by id: Open chat opens it, and its
  /// records (``reduceChild``) say its state and reply.
  child?: string;
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
type Group = { id: string; at: number; version: number; ids: string[] };
type ViewRevisions = { activity: symbol; command: symbol; summary: symbol };

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
  private readonly viewRevisions = new Map<string, ViewRevisions>();
  private readonly settledViews = new Map<string, string>();
  private readonly viewTools = new Map<string, Map<string, boolean>>();
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
  /// A call started another family's agent while the chat's harness was not known: once it is,
  /// the pane folds the records again (direct.ts ``learnChatThread``).
  deferredRun = false;
  /// `acpmux run --parent` calls whose sub-session acpmux has not said started (``reduceChild``):
  /// what each runs, its first update and its newest. The oldest go past PENDING_CHILDREN.
  private readonly parentCalls = new Map<string, { run: AgentRun; command: string; first: Step; last?: Step }>();
  /// The run each sub-session is, by its session id; the runs whose reply acpmux recorded.
  private readonly children = new Map<string, string>();
  private readonly recorded = new Set<string>();

  constructor(private readonly stops: SubagentStops = subagentStops()) {}
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
    const kind = update?.sessionUpdate;
    if (kind === "subagent_spawned" || kind === "subagent_state_update" || kind === "subagent_progress") return true;
    if (this.reduceRun(event, update)) return true;
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

  /// Whether shell call `call` started an agent, which draws as that agent and not as the call.
  isRun(call: string): boolean {
    return this.runs.has(call);
  }

  /// A shell call of the chat's own that starts an agent of another family (agentRuns.ts), as that
  /// agent: its start, its output (its reply, or that it went to the background) and how a
  /// background one ended. True when the update was the agent's and draws no row. Its updates are
  /// its own view, so opening it shows the command and all it printed.
  private reduceRun(event: Event, update: any): boolean {
    const kind = update?.sessionUpdate;
    const call = typeof update?.toolCallId === "string" ? update.toolCallId : undefined;
    if (!call) return false;
    const known = this.runs.get(call);
    if (kind === "background_task_update") {
      const agent = known ? this.agents.get(known) : undefined;
      // A `--parent` call still waiting for its child's start that ended starts none.
      if (!agent && ["completed", "failed", "stopped"].includes(update.state)) this.parentCalls.delete(call);
      if (!agent) return false;
      const state = update.state;
      const failed = state === "failed" || (Number.isInteger(update.exitCode) && update.exitCode !== 0);
      if (state === "completed" || state === "failed" || state === "stopped")
        this.endRun(agent, failed ? "failed" : state === "stopped" ? "cancelled" : "completed", event.at);
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
      const ended = update.status === "failed" || update.status === "completed";
      if (ended && !(update.status === "completed" && backgroundOutputPath(outputOf(update))))
        this.parentCalls.delete(call);
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
      this.parentCalls.set(call, { run, command: line, first: { event, update } });
      for (const old of this.parentCalls.keys()) {
        if (this.parentCalls.size <= PENDING_CHILDREN) break;
        this.parentCalls.delete(old);
      }
      return false;
    }
    // Only another family's: both harnesses known and different (a chat whose harness is not known
    // yet keeps its calls).
    if (!run?.harness || !this.harness || harnessFamily(run.harness) === harnessFamily(this.harness)) {
      // The pane folds again once it knows the chat's harness (direct.ts ``learnChatThread``).
      if (run?.harness && !this.harness) this.deferredRun = true;
      this.notRuns.add(call);
      return false;
    }
    this.startRun(call, { event, update }, run, line);
    return true;
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
      ...(run.session && { session: run.session }),
      ...(run.host && { host: run.host }),
      ...(update.rawInput.run_in_background === true && { background: true }),
    };
    this.runs.set(call, agent.id);
    this.agents.set(agent.id, agent);
    this.named.add(agent.id);
    this.turn.add(agent.id);
    // A foreground run ends with its call; the turn's end ends one whose end never came.
    if (!agent.background) this.called.add(agent.id);
    // Its own card in the transcript, where it started: never a batch with Claude's subagents.
    const group: Group = { id: `${SUBAGENTS}-${event.seq}`, at: event.at, version: 0, ids: [agent.id] };
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
    // Each turn's end says the whole of it: a turn that said nothing has no reply, not the last one's.
    const said = text(record.result?.reply) ?? text(record.result?.error);
    if (said) agent.result = said;
    else delete agent.result;
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
    const name = text(record.shortName);
    const asked = promptKey(record.prompt);
    // A name is the surer of the two: any call it names wins over one only its prompt matches.
    const calls = [...this.parentCalls];
    const call =
      calls.find(([, pending]) => name !== undefined && pending.run.session === name)?.[0] ??
      calls.find(([, pending]) => asked !== undefined && promptKey(pending.run.prompt) === asked)?.[0];
    const pending = call !== undefined ? this.parentCalls.get(call) : undefined;
    if (call === undefined || !pending) return undefined;
    this.parentCalls.delete(call);
    const harness = text(record.harness) ?? pending.run.harness;
    if (!harness || !this.harness || harnessFamily(harness) === harnessFamily(this.harness)) {
      this.notRuns.add(call);
      return undefined;
    }
    const model = text(record.model);
    const effort = text(record.effort);
    const prompt = pending.run.prompt ?? text(record.prompt);
    const run = {
      ...pending.run,
      harness,
      ...(model && { model }),
      ...(effort && { effort }),
      ...(prompt && { prompt }),
    };
    const agent = this.startRun(call, pending.first, run, pending.command);
    agent.child = child;
    if (!promptTitle(prompt)) agent.name = text(record.title) ?? agent.name;
    this.children.set(child, agent.id);
    if (pending.last) this.updateRun(agent, pending.last.event, pending.last.update);
    return call;
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
        if (reply && !this.recorded.has(agent.id)) agent.result = reply;
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
      this.touch(agent);
    }
    // Read once the run ended, its file says nothing more.
    if (agent.state !== "running") this.forgetOutput(agent.id);
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
      // Publish revisions from the first chunk, avoiding the unversioned O(rows) fallback.
      const revisions = this.viewRevisions.get(id) ?? {
        activity: Symbol(),
        command: Symbol(),
        summary: Symbol(),
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
    let streaming = update?.sessionUpdate === "agent_message_chunk" || update?.sessionUpdate === "agent_thought_chunk";
    if (update?.sessionUpdate === "tool_call" || update?.sessionUpdate === "tool_call_update") {
      const tools = this.viewTools.get(id) ?? new Map<string, boolean>();
      const call = String(update.toolCallId ?? `tool-${entry.event.seq}`);
      const settled =
        update.status === undefined ? tools.get(call) : update.status === "completed" || update.status === "failed";
      // New tools and every update of a settled tool change the summary, even without a status.
      streaming = tools.has(call) && !settled;
      tools.set(call, settled ?? false);
      this.viewTools.set(id, tools);
    }
    if (!streaming) this.bumpViewRevision(id);
    this.bump(id);
  }

  private bumpViewRevision(id: string): void {
    this.viewRevisions.set(id, { activity: Symbol(), command: Symbol(), summary: Symbol() });
  }

  private settleView(agent: Subagent): boolean {
    if (this.settledViews.get(agent.id) === agent.state) return false;
    this.settledViews.set(agent.id, agent.state);
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
    if (action && !isPlumbingName(action)) {
      agent.action = action;
      delete agent.actionShell;
    }
    agent.tokens = count(change.tokens) ?? agent.tokens;
    agent.toolUses = count(change.toolUses) ?? agent.toolUses;
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
    const stateChanged = this.settleView(agent);
    if (agent.parent !== null) {
      if (stateChanged) this.bumpParentViews(agent.parent);
      else this.bump(agent.parent);
    }
    const group = this.groupOf.get(agent.id);
    if (!group) return;
    group.version += 1;
    this.changed.add(group);
  }

  private bumpParentViews(id: string): void {
    this.bumpViewRevision(id);
    this.bump(id);
    const parent = this.agents.get(id)?.parent;
    if (parent !== null && parent !== undefined) this.bumpParentViews(parent);
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

const text = (value: unknown) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
const count = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
