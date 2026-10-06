import { stricterTrust, type HarnessTrust, type TrustLevel } from "./folderTrust";
import type { AcpmuxHostConfig, EventRecord } from "./direct";
import { FORK_OP } from "./operations";
import { HANDOFF_OPS } from "./handoff/protocol";
import { MockHandoffs } from "./handoff/mock";
import {
  claudeModels,
  codexModels,
  mockSessions,
  newSessionSummary,
  sessionHistory,
  sessionSummary,
  workedTurn,
  WORKED_SESSION,
  type SeedStep,
} from "./mockFixture";
import { mockGitDiff, mockGitStatus } from "./mockGit";
import { mockFileSearch } from "./mockFiles";

// Mock transport: the host answers `ready` with `{transport: "mock"}` when no
// acpmux daemon is wanted (demos, screenshots, tests). The page then runs the
// real acpmux client against this in-page daemon, which speaks the daemon's
// JSON-RPC and streams a scripted turn as ACP events, so every frame of a mock
// turn goes through the same reducer and renderers as a real agent's. It starts seeded with
// the workspace in mockFixture.ts, so the pane opens populated.

const sessionId = WORKED_SESSION;
const harnesses = [
  { id: "claude", name: "Claude Code", models: claudeModels },
  { id: "codex", name: "Codex", models: codexModels },
];
/// A recorded MockScript replays against the catalog and session it was recorded with.
const scriptHarnesses = [
  { id: "claude", name: "Claude Code", models: [{ id: "claude-sonnet", name: "Claude Sonnet" }] },
  { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: "GPT-6-Astra" }] },
];
const commands = [
  {
    name: "compact",
    description: "Clear conversation history but keep a summary in context",
    input: { hint: "optional custom summarization instructions" },
  },
  { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
  { name: "pr-comments", description: "Get comments from a GitHub pull request" },
  { name: "review", description: "Review a pull request" },
];
/// The one empty session a recorded MockScript replays into.
const scriptSession = {
  sessionId,
  title: "Mock session",
  harness: "claude",
  model: "claude-sonnet",
  status: "idle",
  turnCount: 0,
};

/// The host config the page connects with in mock mode.
export const mockHost: AcpmuxHostConfig = {
  protocolVersion: 1,
  transport: "acpmux-websocket",
  endpoint: "ws://mock.invalid/acp",
  token: "mock",
  sessionId,
};

export function mockReply(prompt: string): string {
  return `Mock reply to **${prompt.replace(/[*_`]/g, "")}**. No acpmux daemon is attached; this pane is running in mock mode.`;
}

type Update = Record<string, unknown>;
/// One scripted step: an ACP `session/update`, or a daemon (mux) event.
type Step = { update: Update } | { mux: string; msg?: Record<string, unknown> };
/// A recorded turn to replay instead of the scripted one (the screenshot harness,
/// `webviews/scripts/agent-pane`). `atMs` stamps a step that far after the turn
/// started, so durations read as recorded; steps are delivered without pacing.
export type MockScript = { steps: Array<Step & { atMs?: number }>; endAtMs?: number };

const text = (value: string): Update => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: value },
});
const tool = (toolCallId: string, kind: string, title: string, status: string, extra: Update = {}): Update => ({
  sessionUpdate: "tool_call",
  toolCallId,
  kind,
  title,
  status,
  ...extra,
});
const done = (toolCallId: string, extra: Update = {}): Update => ({
  sessionUpdate: "tool_call_update",
  toolCallId,
  status: "completed",
  ...extra,
});

/// A turn shaped like a real agent's: text, a tool call, more text, file edits, a closing answer.
export function mockTurn(prompt: string, turn: number): Step[] {
  const greeting = "/mock/project/src/greeting.ts";
  const notes = "/mock/project/NOTES.md";
  return [
    { update: text("I'll look at the greeting helper") },
    { update: text(" first.") },
    {
      update: tool(`read-${turn}`, "read", "Read src/greeting.ts", "in_progress", { locations: [{ path: greeting }] }),
    },
    {
      update: done(`read-${turn}`, {
        content: [
          {
            type: "content",
            content: { type: "text", text: 'export function greet(name: string) {\n  return "Hello " + name;\n}' },
          },
        ],
      }),
    },
    { update: text("It concatenates without punctuation, so I'll add an optional argument and a notes file.") },
    {
      update: tool(`edit-${turn}`, "edit", "Edit src/greeting.ts", "in_progress", {
        locations: [{ path: greeting, line: 1 }],
        content: [
          {
            type: "diff",
            path: greeting,
            oldText: 'export function greet(name: string) {\n  return "Hello " + name;\n}\n',
            newText:
              'export function greet(name: string, punctuation = "!") {\n  return `Hello, ${name}${punctuation}`;\n}\n',
          },
        ],
      }),
    },
    { update: done(`edit-${turn}`) },
    {
      update: tool(`write-${turn}`, "edit", "Write NOTES.md", "completed", {
        locations: [{ path: notes }],
        content: [{ type: "diff", path: notes, newText: `# Notes\n\nMock turn ${turn}.\n` }],
      }),
    },
    {
      update: text(
        `${mockReply(prompt)}\n\n- \`greet(name)\` now ends with "!"\n- \`greet(name, "?")\` picks the punctuation:\n  - \`greet("Ada", "?")\` returns \`Hello, Ada?\`\n  - the default keeps old callers working`,
      ),
    },
  ];
}

/// An in-page acpmux daemon behind the WebSocket interface the client uses.
export class MockAcpmuxSocket {
  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onmessage: ((message: { data: string }) => void) | null = null;
  private sessions: Record<string, any>[] = [];
  /// Folder trust as acpmux would project it from Claude Code's and Codex's own files (read
  /// only): the seeded projects the user has worked in are trusted by both, atlas-web only by
  /// Codex so far; billing-service and dotfiles were never decided.
  private agentTrust = new Map<string, HarnessTrust>([
    ["~/code/cmux", { claude: "trusted", codex: "trusted" }],
    ["~/code/acpmux", { claude: "trusted", codex: "trusted" }],
    ["~/code/atlas-web", { claude: "unknown", codex: "trusted" }],
  ]);
  /// acpmux's own record, which `acp.trust.set` writes; the agents' files never change.
  private trust = new Map<string, TrustLevel>([["~/code/atlas-web", "trusted"]]);
  private handoffs = new MockHandoffs(
    () => this.sessions,
    (source, harness) => {
      const created: Record<string, any> = {
        ...newSessionSummary(`mock-session-${this.sessions.length + 1}`, source.cwd, Date.now()),
        harness,
        enforcement: source.enforcement,
      };
      this.sessions.push(created);
      this.touch(created.sessionId, {}, false);
      return created.sessionId;
    },
    (id) => {
      const events = this.events.filter((event) => event.sessionId === id);
      return {
        seq: events.at(-1)?.seq ?? 0,
        text: events.map((event) => JSON.stringify(event.msg)).join("\n") || "Continue this repository task.",
      };
    },
    (id, text, promptId) => this.prompt(id, text, promptId),
    (id) => {
      const session = this.sessions.find((s) => s.sessionId === id);
      this.sessions = this.sessions.filter((s) => s.sessionId !== id);
      this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "purged", session } });
    },
  );
  private events: EventRecord[] = [];
  private seq = 0;
  private turns = 0;
  private running?: { cancelled: boolean; target: string };
  /// Seeded sessions whose turn is still open (running, or waiting on a permission).
  private openTurns = new Set<string>();
  /// A new chat opens in the project of the session the reader last opened.
  private attached = sessionId;
  private closed = false;
  /// Prompts run one at a time, as the daemon queues them.
  private queue: Promise<unknown> = Promise.resolve();
  /// Prompts sent and not yet finished; one sent while another runs is reported queued.
  private pending = 0;

  /// `delay` paces the scripted turn; tests pass one that resolves at once.
  constructor(
    private readonly delay: (ms: number) => Promise<void> = (ms) =>
      new Promise((resolve) => window.setTimeout(resolve, ms)),
    private readonly script?: MockScript,
  ) {
    // A replayed turn starts from an empty session, as the recording did.
    if (script) this.sessions = [{ ...scriptSession }];
    else this.seed(Date.now());
    queueMicrotask(() => {
      this.readyState = 1;
      this.onopen?.();
    });
  }

  /// The fixture's sessions, each with its history; the worked session also lists Claude's commands.
  private seed(now: number): void {
    for (const entry of mockSessions) {
      this.sessions.push(sessionSummary(entry, now, 1));
      if (entry.sessionId === sessionId) this.listCommands(sessionId, now - 7 * 60_000);
      const steps: SeedStep[] = entry.sessionId === sessionId ? workedTurn : sessionHistory(entry);
      for (const { ago, ...step } of steps) this.record(entry.sessionId, step as Step, now - ago);
      if (entry.status === "running" || entry.permission) this.openTurns.add(entry.sessionId);
    }
  }

  /// Claude lists its slash commands when a session starts, so the composer's + and `/` work.
  private listCommands(target: string, at?: number): void {
    this.record(target, { update: { sessionUpdate: "available_commands_update", availableCommands: commands } }, at);
  }

  /// Ends a seeded open turn: its permission is answered or withdrawn, its waiting or running tool settles,
  /// and the session goes idle. A turn already closed stays as it is.
  private closeSeededTurn(target: string, status: "completed" | "cancelled", allowed = false): void {
    if (!this.openTurns.delete(target)) return;
    const tool = this.events.find(
      (event) =>
        event.sessionId === target &&
        event.kind === "tool_call" &&
        ["pending", "in_progress"].includes((event.msg as any)?.params?.update?.status),
    );
    const toolCallId = (tool?.msg as any)?.params?.update?.toolCallId;
    if (toolCallId)
      this.emit(target, {
        update: { sessionUpdate: "tool_call_update", toolCallId, status: allowed ? "completed" : "failed" },
      });
    const pending = this.events.find((event) => event.sessionId === target && event.kind === "permission_request");
    if (pending)
      this.emit(target, { mux: "permission_decision", msg: { permissionId: (pending.msg as any).permissionId } });
    this.emit(target, { mux: "turn_result", msg: { status } });
    this.touch(target, { status: "idle", pendingPermissions: 0 });
  }

  send(raw: string): void {
    const request = JSON.parse(raw) as { id?: number; method: string; params?: Record<string, any> };
    if (request.method === "session/cancel") {
      const target = String(request.params?.sessionId ?? sessionId);
      if (this.running?.target === target) this.running.cancelled = true;
      else this.closeSeededTurn(target, "cancelled");
      return;
    }
    if (request.id === undefined) return;
    void this.answer(request.method, request.params ?? {}).then(
      (result) => this.deliver({ jsonrpc: "2.0", id: request.id, result }),
      (error: Error & { code?: string; details?: unknown; data?: unknown }) =>
        this.deliver({
          jsonrpc: "2.0",
          id: request.id,
          error: {
            code: -32000,
            message: error.message,
            data:
              error.data ??
              (error.code ? { code: error.code, ...(error.details ? { details: error.details } : {}) } : undefined),
          },
        }),
    );
  }

  close(): void {
    this.readyState = 3;
    this.closed = true;
    if (this.running) this.running.cancelled = true;
  }

  private async answer(method: string, params: Record<string, any>): Promise<unknown> {
    const target = String(params.sessionId ?? sessionId);
    if (Object.values(HANDOFF_OPS).includes(method as any)) return this.handoffs.answer(method, params);
    switch (method) {
      // The mock serves forks, so the pane's fork action can be tried before acpmux ships it.
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: { operations: [FORK_OP, ...Object.values(HANDOFF_OPS)], handoff: { maxCapsuleBytes: 65536 } },
          },
        };
      case FORK_OP:
        return this.fork(target, Number(params.throughSeq));
      case "_acpmux/watch":
        return { sessions: this.sessions };
      case "_acpmux/harnesses":
        return { harnesses: this.script ? scriptHarnesses : harnesses };
      case "_acpmux/attach": {
        this.attached = target;
        // Opening a session reads it; it keeps its place in the list.
        if (this.sessions.find((entry) => entry.sessionId === target)?.unread)
          this.touch(target, { unread: false }, false);
        return {
          session: {
            ...this.sessions.find((entry) => entry.sessionId === target),
            enforcement: { policy: "default", label: "native_policy", isolation: "unverified", detail: null },
          },
          events: this.events.filter((event) => event.sessionId === target),
        };
      }
      case "_acpmux/events":
        return this.page(target, params);
      case "_acpmux/permission_respond":
        this.closeSeededTurn(target, "completed", String(params.optionId ?? "").startsWith("allow"));
        return {};
      case "session/new": {
        // A new chat opens in the project of the session it was started from.
        const from = this.sessions.find((entry) => entry.sessionId === this.attached) ?? this.sessions[0];
        const created = newSessionSummary(
          `mock-session-${this.sessions.length + 1}`,
          String(params.cwd ?? from?.cwd ?? "~/code/cmux"),
          Date.now(),
          params._meta?.acpmux?.harness === "codex" ? "codex" : "claude",
        );
        if (params._meta?.acpmux?.harness) created.harness = params._meta.acpmux.harness;
        // It runs on the same machine, with the harness's model the catalog offers.
        if (from?.host) Object.assign(created, { host: from.host, hostKind: from.hostKind });
        if (this.script) created.model = scriptHarnesses[0]!.models[0]!.id;
        if (!this.script) this.listCommands(String(created.sessionId));
        this.sessions.push(created);
        this.deliver({
          jsonrpc: "2.0",
          method: "_acpmux/session_changed",
          params: { kind: "created", session: created },
        });
        return { sessionId: created.sessionId };
      }
      case "session/prompt": {
        const text = String(params.prompt?.[0]?.text ?? "");
        const promptId = params._meta?.acpmux?.promptId;
        const queued = this.pending > 0 && promptId !== undefined;
        if (queued) this.emit(target, { mux: "queued", msg: { promptId, text } });
        this.pending += 1;
        const turn = this.queue
          .then(() => {
            if (queued) this.emit(target, { mux: "dequeued", msg: { promptId } });
            return this.prompt(target, text, promptId);
          })
          .finally(() => {
            this.pending -= 1;
          });
        this.queue = turn.catch(() => undefined);
        return turn;
      }
      // The pickers' switches land on the session the way an agent reports them.
      case "session/set_model":
        this.touch(target, { model: String(params.modelId) }, false);
        return {};
      case "session/set_config_option": {
        const session = this.sessions.find((entry) => entry.sessionId === target);
        const options = (session?.configOptions ?? []) as { id: string; currentValue?: string }[];
        const configOptions = options.map((option) =>
          option.id === params.configId ? { ...option, currentValue: String(params.value) } : option,
        );
        this.touch(target, { configOptions }, false);
        return {};
      }
      case "acp.trust.get": {
        const cwd = String(params.cwd ?? "");
        const harnesses: HarnessTrust = { claude: "unknown", codex: "unknown", ...this.agentTrust.get(cwd) };
        // acpmux's own decision answers first; without one, the stricter of the agents' levels.
        const level = this.trust.get(cwd) ?? stricterTrust(harnesses.claude!, harnesses.codex!);
        return { cwd, level, harnesses };
      }
      case "acp.trust.set": {
        const cwd = String(params.cwd ?? "");
        // "unknown" forgets acpmux's record, so the agents' own levels answer again.
        if (params.level === "unknown") {
          this.trust.delete(cwd);
          return { cwd, level: "unknown" };
        }
        const level: TrustLevel = params.level === "untrusted" ? "untrusted" : "trusted";
        this.trust.set(cwd, level);
        return { cwd, level };
      }
      case "file.search":
        return mockFileSearch(
          typeof params.path === "string"
            ? params.path
            : this.sessions.find((entry) => entry.sessionId === target)?.cwd,
          params.query,
          params.limit,
        );
      case "git.checkpoint.diff":
        // The fixture has no checkpoints: a turn reads as the uncommitted changes.
        return {
          ...mockGitDiff(target, "uncommitted", params.include_patch === true),
          from: params.from,
          ...(typeof params.to === "string" ? { to: params.to } : {}),
        };
      case "git.diff":
        return mockGitDiff(target, params.scope, params.include_patch === true);
      case "git.status":
        return mockGitStatus(target);
      default:
        return {};
    }
  }

  /// A new session holding `target`'s events through `throughSeq`, under its own sequence.
  private fork(target: string, throughSeq: number): { sessionId: string } {
    const source = this.sessions.find((entry) => entry.sessionId === target);
    if (!source || !Number.isFinite(throughSeq)) throw new Error(`cannot fork ${target}`);
    const sessionId = `mock-session-${this.sessions.length + 1}`;
    for (const event of this.events.filter((entry) => entry.sessionId === target && entry.seq <= throughSeq)) {
      this.seq += 1;
      const msg =
        event.dir === "in" ? { ...event.msg, params: { ...(event.msg as any).params, sessionId } } : event.msg;
      this.events.push({ ...event, sessionId, seq: this.seq, msg });
    }
    const turns = this.events.filter((entry) => entry.sessionId === sessionId && entry.kind === "turn_result").length;
    const created = {
      ...source,
      sessionId,
      status: "idle",
      unread: false,
      pendingPermissions: 0,
      turnCount: turns,
      updatedAt: Date.now(),
    };
    this.sessions.push(created);
    this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session: created } });
    return { sessionId };
  }

  private async prompt(target: string, prompt: string, promptId?: string): Promise<unknown> {
    // A prompt queued behind a closed daemon never starts.
    if (this.closed) return { stopReason: "cancelled" };
    this.turns += 1;
    // A prompt into a seeded open turn ends that turn first, as a new prompt supersedes it.
    this.closeSeededTurn(target, "cancelled");
    this.touch(target, {
      turnCount: Number(this.sessions.find((entry) => entry.sessionId === target)?.turnCount ?? 0) + 1,
      unread: false,
      status: "running",
    });
    const running = { cancelled: false, target };
    this.running = running;
    const started = Date.now();
    this.emit(target, { mux: "user_message", msg: { text: prompt, promptId } });
    this.emit(target, { mux: "turn_started" });
    const steps: MockScript["steps"] = this.script?.steps ?? mockTurn(prompt, this.turns);
    for (const step of steps) {
      if (!this.script) await this.delay(350);
      if (running.cancelled || this.closed) break;
      this.emit(target, step, step.atMs === undefined ? undefined : started + step.atMs);
    }
    const endAt = this.script?.endAtMs;
    this.emit(
      target,
      { mux: "turn_result", msg: { status: running.cancelled ? "cancelled" : "completed" } },
      endAt !== undefined ? started + endAt : undefined,
    );
    this.running = undefined;
    this.touch(target, { status: "idle" });
    return { stopReason: running.cancelled ? "cancelled" : "end_turn" };
  }

  /// Updates a session's summary and tells the client, as the daemon does.
  private touch(target: string, fields: Record<string, unknown>, moved = true): void {
    const index = this.sessions.findIndex((entry) => entry.sessionId === target);
    if (index < 0) return;
    const changed = { ...this.sessions[index], ...fields, ...(moved ? { updatedAt: Date.now() } : {}) };
    this.sessions[index] = changed;
    this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "updated", session: changed } });
  }

  /// A page of a session's events, as `_acpmux/events` returns it: after `afterSeq`, or the
  /// newest `limit` before `beforeSeq`; `kinds` keeps the commands or the transcript.
  private page(target: string, params: Record<string, any>): { events: EventRecord[]; more: boolean } {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const wanted = (event: EventRecord) =>
      kinds.length === 0 ||
      (event.kind === "available_commands_update" ? kinds.includes(event.kind) : kinds.includes("transcript"));
    const own = this.events.filter((event) => event.sessionId === target && wanted(event));
    if (params.beforeSeq === undefined)
      return { events: own.filter((event) => event.seq > Number(params.afterSeq ?? 0)), more: false };
    const older = own.filter((event) => event.seq < Number(params.beforeSeq));
    const limit = Math.max(1, Number(params.limit ?? older.length));
    return { events: older.slice(-limit), more: older.length > limit };
  }

  private record(target: string, step: Step, at = Date.now()): EventRecord {
    this.seq += 1;
    const event: EventRecord =
      "update" in step
        ? {
            sessionId: target,
            seq: this.seq,
            at,
            dir: "in",
            kind: String(step.update.sessionUpdate),
            msg: { method: "session/update", params: { sessionId: target, update: step.update } },
          }
        : { sessionId: target, seq: this.seq, at, dir: "mux", kind: step.mux, msg: step.msg ?? {} };
    this.events.push(event);
    return event;
  }

  private emit(target: string, step: Step, at?: number): void {
    this.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: this.record(target, step, at) });
  }

  private deliver(message: unknown): void {
    queueMicrotask(() => {
      if (this.readyState === 1) this.onmessage?.({ data: JSON.stringify(message) });
    });
  }
}
