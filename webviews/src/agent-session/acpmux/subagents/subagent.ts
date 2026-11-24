// A subagent as the pane models it and the kind of its transcript row: a leaf apart from
// subagentFold.ts (the fold, which reads direct.ts), so model.ts names a subagent without loading it.
import type { AcpmuxBackgroundReaction } from "../model";
import type { RetryState } from "./retryState";
import type { WorkflowAgent, WorkflowPhase } from "./workflowAgents";

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
  /// The ACP kind of that call (`read`, `edit`, `execute`, `fetch`, `think`, `other`; acpmux's
  /// `tool_kind`): the composer hat says it as one bounded word, never the call (hatStep.ts).
  actionKind?: string;
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
  /// The chat's reaction to its end, when acpmux weighed it (direct.ts `attachReaction`): its done
  /// line marks a result the person has not seen, and its tooltip carries the reply.
  reaction?: AcpmuxBackgroundReaction;
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
  /// acpmux can start this stopped (or lost) subagent again from its transcript and brief, the
  /// run a Resume started that continues it (its old id), and the run that continues this one
  /// (resumeState.ts).
  resumable?: boolean;
  resumes?: string;
  resumedBy?: string;
  /// Why it failed, as acpmux recorded it (`error`): its end line says it.
  error?: string;
  /// When it last did anything (a line of its own, a call, new tokens) while none of its calls is
  /// open; none while one is. A running one quiet past ``IDLE_AFTER_MS`` has stopped and waits on
  /// work of its own in the background, and reads Idle, not Running (summary/SubagentStatusList.tsx
  /// ``subagentStatus``). Leo, 2026-11-02, on rows running for two hours: "but what's going on with these?"
  quietSince?: number;
  /// Its start came before what this fold read: it was first met through its progress or its end
  /// (a page, a lag's re-read or a reconnect that began after its spawn). It draws no "started
  /// working" line (runningTray.ts `startedLine`): it did not start there. Leo, 2026-11-22, on a
  /// row of eleven empty name pills that flickered in and out over a running turn: "ENTIRE THING
  /// FUCKING BLANKED AND FUCKING SHIFTED".
  startUnseen?: true;
};

/// Why a subagent was stopped: the person stopped it (Stop on the turn, or on the subagent), or a
/// prompt sent with Send now interrupted its turn.
export type SubagentStopReason = "user" | "sendNow";
