import { stricterTrust, type HarnessTrust, type TrustLevel } from "./folderTrust";
import type { AcpmuxHostConfig, EventRecord } from "./direct";
import { FORK_OP } from "./operations";
import { HANDOFF_OPS } from "./handoff/protocol";
import { MockHandoffs } from "./handoff/mock";
import {
  claudeModels,
  codexModels,
  mockResolvable,
  mockSessions,
  listedSession,
  newSessionSummary,
  sessionHistory,
  sessionSummary,
  workedTurn,
  WORKED_SESSION,
  type SeedStep,
} from "./mockFixture";
import { mockGitCommit, mockGitDiff, mockGitPush, mockGitStatus } from "./mockGit";
import { mockFileSearch } from "./mockFiles";
import { lightTurn, loadTurn, streamedReply, streamedTool } from "./loadFixture";

/** Gallery-only auth data. The mock daemon consumes this; production direct clients do not. */
export type MockSessionAuth = {
  state: "ready" | "signedOut" | "expired" | "routeAuthNeeded" | "routeUnreachable" | "peerUnreachable" | "unknown";
  source: "peerLink" | "routeProbe" | "turn" | "authCheck" | "none";
  evidenceAt: number | null;
  detail?: string;
  harness: string;
  host: string | null;
  routeId: string | null;
  fromSessionId: string | null;
  login?: { kind: "terminal" | "route"; command?: string; host?: string | null; routeId?: string | null };
};
/// Mux records acpmux's "transcript" kind leaves out (paging.rs `TRANSCRIPT_MUX_KINDS`) that the
/// pane asks for by name.
const MOCK_NOT_TRANSCRIPT = new Set(["preset_approval_request", "preset_approval_decision"]);
type MockAuthGlobals = {
  cmuxAcpmuxMockHarnessHealth?: Record<string, { auth: "signedIn" | "signedOut" | "unknown"; login?: string }>;
  cmuxAcpmuxMockNative?: Record<string, unknown>;
  cmuxAcpmuxMockSessionAuth?: MockSessionAuth;
  /** `_acpmux/memory_resolve` fails with this message, as acpmux does when it cannot write the file. */
  cmuxAcpmuxMockMemoryError?: string;
  /** `_acpmux/presets` with `approveMode` fails with this message, as acpmux does when the host or the person check refuses it. */
  cmuxAcpmuxMockPresetError?: string;
  /** Capability ids `initialize` names (`_meta.acpmux.capabilities`); absent names none, as an older daemon. */
  cmuxAcpmuxMockCapabilities?: string[];
  /** Gallery only: `session/new` refuses with `trust.pending` until `acp.trust.set` trusts a folder. */
  cmuxAcpmuxMockTrustPending?: boolean;
  /** `?mock&slowDaemon` fixture: keep the socket open while one RPC answers slowly. */
  cmuxAcpmuxMockSlowMethod?: string;
  /** Delay for `cmuxAcpmuxMockSlowMethod`; tests use a short delay, the gallery uses six seconds. */
  cmuxAcpmuxMockSlowMs?: number;
  /** bench/update-one.bench.ts: that many more listed sessions beside the fixture's, with no history. */
  cmuxAcpmuxMockListSize?: number;
};

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
/// The seeded project's own harness profiles (`<folder>/.cmux/harnesses/<id>.toml`), one in each
/// state a folder profile can be in. Acme waits for the user's Enable.
const MOCK_PROFILE_FOLDER = "~/code/cmux";
/// The runs a mock plan build starts: a Claude one, and a Codex one beside it for a compare.
function mockPlanBuilds(count: number) {
  const runs = [
    {
      harness: "claude",
      added: 142,
      removed: 31,
      files: [
        { path: "src/sync/queue.ts", added: 96, removed: 18 },
        { path: "src/sync/queue.test.ts", added: 46, removed: 13 },
      ],
    },
    {
      harness: "codex",
      added: 88,
      removed: 40,
      files: [
        { path: "src/sync/queue.ts", added: 61, removed: 33 },
        { path: "src/sync/retry.ts", added: 27, removed: 7 },
      ],
    },
  ];
  return runs.slice(0, count).map((run, index) => ({
    sessionId: `mock-plan-build-${index + 1}`,
    name: `build-plan-${run.harness}`,
    harness: run.harness,
    status: "idle",
    archived: false,
    branch: `cmux/build-plan-${run.harness}`,
    base: "main",
    root: `~/.cmux/worktrees/cmux/build-plan-${run.harness}`,
    added: run.added,
    removed: run.removed,
    files: run.files,
  }));
}
const mockFolderProfiles = [
  { id: "acme", displayName: "Acme Agent", state: "needs-enable" },
  { id: "lint-bot", displayName: "Lint Bot", state: "needs-trust" },
  {
    id: "broken",
    displayName: "Broken Agent",
    state: "error",
    diagnostics: [{ message: "command not found: broken-agent" }],
  },
] as const;
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
  // A skill, as acpmux tags Claude's (`_meta.kind`): its `/name` is blue in a sent prompt, with this
  // description as its tooltip (conversation/SkillWord.tsx).
  {
    name: "design-vocabulary",
    description: "The precise design and UI vocabulary, for the exact word for a design idea",
    _meta: { kind: "skill" },
  },
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
type Step = { update: Update; meta?: Record<string, unknown> } | { mux: string; msg?: Record<string, unknown> };
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

/// How a load run streams its turn: text deltas of `chunkChars` every `chunkMs`, and a large
/// tool call (a log or an edit) after every `toolEvery` deltas.
export type LoadStreamOptions = { seconds: number; chunkChars: number; chunkMs: number; toolEvery: number };

/// Whether `event` is subagent `id`'s own record (hub/paging.rs `subagent_owns`): an agent update
/// acpmux tagged with it (`_meta.acpmux.subagent`) or one that starts or changes it (`subagents[].id`).
function subagentOwns(event: EventRecord, id: string): boolean {
  if (event.dir !== "in" || event.msg?.method !== "session/update") return false;
  const mux = event.msg.params?._meta?.acpmux;
  return (
    mux?.subagent === id ||
    (Array.isArray(mux?.subagents) && mux.subagents.some((change: { id?: unknown }) => change?.id === id))
  );
}

/// An in-page acpmux daemon behind the WebSocket interface the client uses.
export class MockAcpmuxSocket {
  /// The mock daemon the page connected to last, for `debug.agent_pane load_seed` (loadDebug.ts).
  static live: MockAcpmuxSocket | undefined;
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
  /// `cmuxAcpmuxMockTrustPending`: whether a folder has been trusted since the page loaded.
  private trustGranted = false;
  /// Folder profiles the user enabled (`_acpmux/harness_enable`), by id.
  private enabledProfiles = new Set<string>();
  private bookmarks = new Map<string, Set<number>>();
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
  /// Light load sessions (`seedLoadSession` `light`): attach answers their whole log.
  private openWhole = new Set<string>();
  private seq = 0;
  /// The images prompts sent, by id, as acpmux keeps them (`_acpmux/attachment`).
  private promptImages = new Map<string, { mimeType: string; data: string }>();
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
    MockAcpmuxSocket.live = this;
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
    const listSize = Number((globalThis as MockAuthGlobals).cmuxAcpmuxMockListSize ?? 0);
    for (let index = 0; index < listSize; index += 1) this.sessions.push(listedSession(index, now));
  }

  /// One field change of one session (a status dot, unread, a rename, a cost), told the client the way
  /// the daemon tells it: one `session_changed` with that session's summary. The row keeps its place.
  /// `fields` may read the session's current summary (an unread toggle flips what it is).
  changeSession(
    target: string,
    fields: Record<string, unknown> | ((current: Record<string, any>) => Record<string, unknown>),
  ): void {
    const current = this.sessions.find((entry) => entry.sessionId === target);
    if (current) this.touch(target, typeof fields === "function" ? fields(current) : fields, false);
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
    this.touch(target, { status: "idle", pendingPermissions: 0, indicator: status === "completed" ? "done" : null });
  }

  /// A new session holding `turns` finished heavy turns (loadFixture.ts), recorded without
  /// delivery; the client reads them when it attaches. Returns the session id.
  ///
  /// `light` turns are a prompt and a one-line reply each (two rows), and the session opens whole
  /// (attach ignores its page caps), so a bench can open a chat of an exact length in rows.
  seedLoadSession(turns: number, light = false): string {
    const now = Date.now();
    const id = `load-session-${this.sessions.length + 1}`;
    const created = {
      ...newSessionSummary(id, "~/code/cmux", now),
      title: `Load: ${turns} turns`,
      turnCount: turns,
      status: "idle",
    };
    for (let turn = 0; turn < turns; turn += 1) {
      const at = now - (turns - turn) * 60_000;
      for (const step of light ? lightTurn(turn) : loadTurn(turn)) this.record(id, step, at);
    }
    if (light) this.openWhole.add(id);
    this.sessions.push(created);
    this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session: created } });
    return id;
  }

  /// Records `updates` into `target`'s log in place of subagent `id`'s own records there, without
  /// delivery: `_acpmux/events {subagent}` reads them as acpmux's log would (`debug.agent_pane
  /// seed_rows` `subagent-report`, whose capped report card's Show more reads that subagent's reply).
  seedSubagentLog(target: string, id: string, updates: { update: Update; meta: Record<string, unknown> }[]): void {
    this.events = this.events.filter((event) => event.sessionId !== target || !subagentOwns(event, id));
    for (const step of updates) this.record(target, step);
  }

  /// Streams one turn into `target` as fast as `options` say, as a busy agent does: text deltas
  /// on a timer (not on frames, as a socket's arrive) with large tool calls between them.
  async streamLoadTurn(
    target: string,
    options: LoadStreamOptions,
  ): Promise<{ deltas: number; chars: number; tools: number }> {
    const turn = Number(this.sessions.find((entry) => entry.sessionId === target)?.turnCount ?? 0) + 1;
    this.touch(target, { turnCount: turn, status: "running", indicator: "working" });
    this.emit(target, { mux: "user_message", msg: { text: `Turn ${turn}: stream a long answer` } });
    this.emit(target, { mux: "turn_started" });
    const reply = streamedReply(turn, 400);
    const end = performance.now() + options.seconds * 1000;
    let at = 0;
    let deltas = 0;
    let tools = 0;
    while (performance.now() < end && !this.closed) {
      await this.delay(options.chunkMs);
      const chunk = reply.slice(at % reply.length, (at % reply.length) + options.chunkChars);
      at += options.chunkChars;
      this.emit(target, { update: text(chunk) });
      deltas += 1;
      if (options.toolEvery > 0 && deltas % options.toolEvery === 0) {
        this.emit(target, { update: streamedTool(turn, tools) });
        tools += 1;
      }
    }
    this.emit(target, { mux: "turn_result", msg: { status: "completed" } });
    this.touch(target, { status: "idle", indicator: "done" });
    return { deltas, chars: at, tools };
  }

  /// Runs one long tool call in `target` for `options.seconds`, as a busy agent's command does: its
  /// output grows every `tickMs` (the running row and the live line tick), and every `sidebarMs`
  /// another chat in the list changes (its indicator and time), as a sidebar does while it works.
  /// No reply text streams, so whatever the transcript draws past the running turn is waste.
  async tickLoadTurn(
    target: string,
    options: { seconds: number; tickMs: number; sidebarMs: number; lineSuffix?: string; backgroundCommands?: number },
  ): Promise<{ ticks: number; sidebar: number }> {
    const turn = Number(this.sessions.find((entry) => entry.sessionId === target)?.turnCount ?? 0) + 1;
    this.touch(target, { turnCount: turn, status: "running", indicator: "working" });
    this.emit(target, { mux: "user_message", msg: { text: `Turn ${turn}: run the long check` } });
    this.emit(target, { mux: "turn_started" });
    // Shells sent to the background first, as Claude's Bash `run_in_background` does: each call ends at
    // once and its shell keeps running, so the composer's hat (SubagentTray.tsx) shows it with its
    // time ticking for the whole run. They are left running when the turn ends.
    for (let index = 0; index < (options.backgroundCommands ?? 0); index += 1) {
      const shell = `load-tick-${turn}-background-${index}`;
      const command = `bun run dev --port ${4300 + index}`;
      this.emit(target, {
        update: tool(shell, "execute", command, "in_progress", {
          rawInput: { command, run_in_background: true },
        }),
      });
      this.emit(target, {
        update: done(shell, {
          content: [
            { type: "content", content: { type: "text", text: `Command running in background with ID: ${shell}` } },
          ],
        }),
      });
    }
    const call = `load-tick-${turn}`;
    this.emit(target, {
      update: tool(call, "execute", "Run bun test --watch", "in_progress", {
        rawInput: { command: "bun test --watch" },
      }),
    });
    const other = this.sessions.find((entry) => entry.sessionId !== target)?.sessionId;
    const start = performance.now();
    const end = start + options.seconds * 1000;
    let ticks = 0;
    let sidebar = 0;
    let output = "";
    let nextSidebar = start + options.sidebarMs;
    while (performance.now() < end && !this.closed) {
      await this.delay(options.tickMs);
      ticks += 1;
      output += `pass ${ticks}${options.lineSuffix ?? ""}\n`;
      this.emit(target, {
        update: {
          sessionUpdate: "tool_call_update",
          toolCallId: call,
          status: "in_progress",
          content: [{ type: "content", content: { type: "text", text: output } }],
        },
      });
      if (other && options.sidebarMs > 0 && performance.now() >= nextSidebar) {
        nextSidebar += options.sidebarMs;
        sidebar += 1;
        this.touch(other, { indicator: sidebar % 2 ? "working" : "done", status: sidebar % 2 ? "running" : "idle" });
      }
    }
    this.emit(target, { update: done(call) });
    this.emit(target, { mux: "turn_result", msg: { status: "completed" } });
    this.touch(target, { status: "idle", indicator: "done" });
    if (other) this.touch(other, { indicator: null, status: "idle" });
    return { ticks, sidebar };
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
    // The gallery's call log (gallery/frame/main.ts) also lists the requests the page sent here.
    (globalThis as { cmuxGalleryLog?: { method: string; params?: unknown }[] }).cmuxGalleryLog?.push({
      method: `acpmux ${method}`,
      params,
    });
    const { cmuxAcpmuxMockSlowMethod: slowMethod, cmuxAcpmuxMockSlowMs: slowMs } = globalThis as MockAuthGlobals;
    if (slowMethod === method) await this.delay(typeof slowMs === "number" ? slowMs : 6_000);
    if (Object.values(HANDOFF_OPS).includes(method as any)) return this.handoffs.answer(method, params);
    switch (method) {
      // The mock serves forks, so the pane's fork action can be tried before acpmux ships it.
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            // The mock stands in for the local daemon, which names the app's connection local.
            acpmux: {
              origin: "local",
              operations: [FORK_OP, ...Object.values(HANDOFF_OPS)],
              // The memory inbox (`memory_offer` records, `_acpmux/memory_resolve`).
              // The prompt coach (`coach_offer` and `coach` records, `_acpmux/prompt_coach`).
              features: ["queueApproval", "queueGet", "memory-inbox-v1", "prompt-coach-v1"],
              handoff: { maxCapsuleBytes: 65536 },
              ...((globalThis as MockAuthGlobals).cmuxAcpmuxMockSessionAuth ? { features: ["sessionAuth"] } : {}),
              ...((globalThis as MockAuthGlobals).cmuxAcpmuxMockCapabilities
                ? { capabilities: (globalThis as MockAuthGlobals).cmuxAcpmuxMockCapabilities }
                : {}),
            },
          },
        };
      case FORK_OP:
        return this.fork(target, Number(params.throughSeq));
      case "_acpmux/watch":
        return { sessions: this.sessions };
      // A session this daemon lists (mockFixture.ts `mockResolvable`), by link, id or HOST/NAME.
      case "_acpmux/resolve": {
        const query = String(params.query ?? "").trim();
        const session = query.startsWith("https://")
          ? undefined
          : (mockResolvable[query] ?? mockResolvable[query.replace(/^cmux:\/\/agent\/[^/]+\//, "").split("?")[0]!]);
        if (!session)
          throw Object.assign(new Error(`no session named or with the id ${JSON.stringify(query)}`), { code: -32001 });
        return { session: { ...session, qualifiedSessionId: null }, matches: [session], link: null };
      }
      case "_acpmux/harnesses":
        return {
          // A gallery state can stand for a Mac with no agent CLI (`mockHarnesses`).
          harnesses: this.script
            ? scriptHarnesses
            : ((globalThis as { cmuxAcpmuxMockHarnesses?: unknown[] }).cmuxAcpmuxMockHarnesses ?? harnesses),
          ...(typeof params.cwd === "string" && this.profileFolder(params.cwd)
            ? { folderProfiles: this.folderProfiles() }
            : {}),
        };
      // The host confirms with the user and adds the hash; the pane never sends one.
      case "_acpmux/harness_enable": {
        const profile = mockFolderProfiles.find((entry) => entry.id === params.id);
        if (params.sha256 !== undefined || params.folder !== MOCK_PROFILE_FOLDER || profile?.state !== "needs-enable")
          throw Object.assign(new Error("enable refused"), { code: "transport.harness_not_confirmed" });
        this.enabledProfiles.add(profile.id);
        return { enabled: { id: profile.id, folder: MOCK_PROFILE_FOLDER } };
      }
      case "_acpmux/attach": {
        this.attached = target;
        const page = this.page(target, params, true);
        // A chat whose last turn left a suggestion: acpmux sends it live, never in a page.
        const suggestion = mockSessions.find((entry) => entry.sessionId === target)?.suggestion;
        if (suggestion)
          setTimeout(() => {
            if (this.attached === target)
              this.emit(target, { update: { sessionUpdate: "prompt_suggestion", suggestion } });
          }, 0);
        // Opening a session reads it; it keeps its place in the list.
        if (this.sessions.find((entry) => entry.sessionId === target)?.unread)
          this.touch(target, { unread: false }, false);
        return {
          session: {
            ...this.sessions.find((entry) => entry.sessionId === target),
            enforcement: { policy: "default", label: "native_policy", isolation: "unverified", detail: null },
            // The newest command list, as acpmux keeps it in the session.
            ...this.availableCommands(target),
          },
          // The newest page, as acpmux pages an attach (hub/paging.rs): at most `limit` records
          // and `maxBytes` of them, `hasMore` when older ones remain. Answering the whole log made
          // a long mock chat open as slowly as its history is long (perf100).
          ...page,
          lastSeq: this.lastSeqOf(target),
          // The prompt of the turn the page starts inside, read with it as acpmux does
          // (server/requests/turn_opener.rs).
          turnOpener: this.turnOpener(target, page),
        };
      }
      case "_acpmux/archive": {
        const entry = this.sessions.find((session) => session.sessionId === target);
        if (!entry) throw Object.assign(new Error("no such session"), { code: -32001 });
        const tags: Record<string, string> = { ...(entry.tags && !Array.isArray(entry.tags) ? entry.tags : {}) };
        if (params.archived === true) tags.archived = String(Date.now());
        else delete tags.archived;
        this.touch(target, { tags, archived: undefined }, false);
        return this.sessions.find((session) => session.sessionId === target);
      }
      case "_acpmux/side": {
        if (
          !this.sessions.some((session) => session.sessionId === target) ||
          !this.sessions.some((session) => session.sessionId === params.chat) ||
          params.chat === target
        )
          throw Object.assign(new Error("not a side chat"), { code: -32602 });
        const entry = this.sessions.find((session) => session.sessionId === target)!;
        this.touch(
          target,
          { tags: { ...(entry.tags && !Array.isArray(entry.tags) ? entry.tags : {}), side: String(params.chat) } },
          false,
        );
        return this.sessions.find((session) => session.sessionId === target);
      }
      // Gallery data may override this mock daemon's health, never the real direct client.
      case "_acpmux/harness/health": {
        const fixture = globalThis as MockAuthGlobals;
        const native = fixture.cmuxAcpmuxMockNative?.["harness.health"] as
          | { health?: { id?: string; auth?: "signedIn" | "signedOut" | "expired" | "unknown"; login?: string } }
          | undefined;
        const fromNative = native?.health;
        const overrides = fixture.cmuxAcpmuxMockHarnessHealth;
        const resolved = {
          harnesses: harnesses.map((harness) => ({
            id: harness.id,
            auth:
              overrides?.[harness.id]?.auth ??
              (fromNative?.id === harness.id ? fromNative.auth : undefined) ??
              "signedIn",
            ...(overrides?.[harness.id]?.login
              ? { login: overrides[harness.id]!.login }
              : fromNative?.id === harness.id && fromNative.login
                ? { login: fromNative.login }
                : {}),
          })),
        };
        (globalThis as { cmuxGalleryLog?: { method: string; params?: unknown }[] }).cmuxGalleryLog?.push({
          method: "acpmux health resolved",
          params: resolved,
        });
        return resolved;
      }
      // A session-scoped auth reply remains distinct from host-wide CLI health. The fixture's
      // "expired" state never turns a harness-wide signedOut bit on.
      case "_acpmux/session/auth":
        return (
          (globalThis as MockAuthGlobals).cmuxAcpmuxMockSessionAuth ?? {
            state: "unknown",
            source: "none",
            evidenceAt: null,
            harness: String(
              params.target?.harness ?? this.sessions.find((session) => session.sessionId === target)?.harness ?? "",
            ),
            host: null,
            routeId: null,
            fromSessionId: params.target ? null : target,
          }
        );
      case "_acpmux/markUnread":
        if (!this.sessions.some((session) => session.sessionId === target))
          throw Object.assign(new Error("no such session"), { code: -32001 });
        this.touch(target, { unread: true }, false);
        return {};
      // Prompt bookmarks, as acpmux keeps them (hub/bookmarks.rs), without its seq check.
      case "_acpmux/bookmark_get":
      case "_acpmux/bookmark_set": {
        const marks = this.bookmarks.get(target) ?? new Set<number>();
        if (method === "_acpmux/bookmark_set")
          if (params.bookmarked === true) marks.add(Number(params.seq));
          else marks.delete(Number(params.seq));
        this.bookmarks.set(target, marks);
        return { sessionId: target, bookmarks: [...marks].sort((a, b) => a - b) };
      }
      // The memory inbox's Accept and Dismiss (acpmux hub/memory.rs): writes nothing here, and logs
      // the `memory_resolved` record the daemon would, with only the offer's facts still open.
      case "_acpmux/memory_resolve": {
        const failure = (globalThis as MockAuthGlobals).cmuxAcpmuxMockMemoryError;
        if (failure) throw Object.assign(new Error(failure), { code: -32000 });
        const offerId = String(params.offerId ?? "");
        const offer = this.events.find(
          (event) => event.sessionId === target && event.kind === "memory_offer" && event.msg?.offerId === offerId,
        );
        if (!offer) throw Object.assign(new Error(`no memory offer ${offerId}`), { code: -32001 });
        const settled = new Set(
          this.events
            .filter((event) => event.kind === "memory_resolved" && event.msg?.offerId === offerId)
            .flatMap((event) => [...(event.msg?.accepted ?? []), ...(event.msg?.dismissed ?? [])]),
        );
        const open = (value: unknown) =>
          (Array.isArray(value) ? value.map(String) : []).filter(
            (fact) => (offer.msg?.facts ?? []).includes(fact) && !settled.has(fact),
          );
        const accepted = open(params.accept);
        const dismissed = open(params.dismiss).filter((fact) => !accepted.includes(fact));
        const file = String(offer.msg?.file ?? params.file ?? "");
        if (accepted.length || dismissed.length)
          this.emit(target, { mux: "memory_resolved", msg: { offerId, file, accepted, dismissed } });
        return { file, accepted, dismissed, wrote: accepted.length > 0 };
      }
      // The prompt coach's rewrite (acpmux prompt_coach.rs): no model call here; it logs the `coach`
      // record the daemon would, the chat's first prompt with what the person said later, once.
      case "_acpmux/prompt_coach": {
        const coachId = String(params.coachId ?? "");
        const own = this.events.filter((event) => event.sessionId === target);
        const offer = own.find((event) => event.kind === "coach_offer" && event.msg?.coachId === coachId);
        if (!offer || own.some((event) => event.kind === "coach" && event.msg?.coachId === coachId))
          return { made: false };
        const said = own
          .filter((event) => event.kind === "user_message" && typeof event.msg?.text === "string")
          .map((event) => String(event.msg?.text));
        const firstPrompt = said[0] ?? "";
        const rewrite = [firstPrompt, ...said.slice(1).map((text) => `- ${text}`)].join("\n");
        this.emit(target, {
          mux: "coach",
          msg: { coachId, firstPrompt, rewrite, corrections: Number(offer.msg?.corrections ?? said.length - 1) },
        });
        return { made: true };
      }
      // A preset approval card's answer (hub/unattended_presets.rs): it counts only for the digest
      // the chat's latest request for that preset names, and records the decision in that chat.
      case "_acpmux/presets": {
        if (params.approveMode === undefined) return { presets: {} };
        const failure = (globalThis as MockAuthGlobals).cmuxAcpmuxMockPresetError;
        if (failure) throw Object.assign(new Error(failure), { code: -32000 });
        const name = String(params.name ?? "");
        const chat = String(params.sessionId ?? "");
        const asked = this.events
          .filter(
            (event) =>
              event.sessionId === chat && event.kind === "preset_approval_request" && event.msg?.preset === name,
          )
          .at(-1);
        if (!asked || asked.msg?.digest !== params.approveDigest)
          throw Object.assign(new Error(`preset ${name} changed since its card was shown`), { code: -32602 });
        const outcome = params.approveMode === true ? "approved" : "declined";
        this.emit(chat, { mux: "preset_approval_decision", msg: { preset: name, digest: asked.msg.digest, outcome } });
        return { name };
      }
      case "_acpmux/events":
        return this.page(target, params);
      case "_acpmux/attachment": {
        // Only an image the session's own log names, as acpmux reads it.
        const id = String(params.id ?? "");
        const named = this.events.some(
          (event) =>
            event.sessionId === target &&
            ["user_message", "queued", "queue_updated"].includes(event.kind) &&
            Array.isArray(event.msg?.images) &&
            event.msg.images.some((image: { id?: string }) => image.id === id),
        );
        const image = named ? this.promptImages.get(id) : undefined;
        if (!image) throw Object.assign(new Error(`no image ${id} in this chat`), { code: -32001 });
        return image;
      }
      // A guest's held prompt: acpmux records the owner's answer (design/chat-multiplayer.md 4.1).
      case "_acpmux/queue_approve":
      case "_acpmux/queue_decline":
        this.emit(target, {
          mux: method === "_acpmux/queue_approve" ? "queue_approved" : "queue_declined",
          msg: { promptId: params.promptId, revision: params.revision ?? 0 },
        });
        if (method === "_acpmux/queue_decline")
          this.emit(target, { mux: "queue_removed", msg: { promptId: params.promptId, reason: "declined" } });
        return {};
      // A queued prompt read whole for the owner (acpmux hub/queue_get.rs): its newest record.
      case "_acpmux/queue_get": {
        for (let index = this.events.length - 1; index >= 0; index -= 1) {
          const event = this.events[index]!;
          if (event.sessionId !== target || (event.kind !== "queued" && event.kind !== "queue_updated")) continue;
          const msg = event.msg as Record<string, unknown>;
          if (msg.promptId !== params.promptId) continue;
          return { sessionId: target, promptId: params.promptId, revision: 0, ...msg };
        }
        throw Object.assign(new Error("no prompt waits under that id"), { data: { reason: "queue.not_found" } });
      }
      case "_acpmux/permission_respond":
        this.closeSeededTurn(target, "completed", String(params.optionId ?? "").startsWith("allow"));
        return {};
      // A plan build (`_acpmux/plan/build`): here approves; a worktree or a compare answers the ask
      // with a deny and records the runs it started on the chat, as acpmux does.
      case "_acpmux/plan/build": {
        const where = String(params.target ?? "");
        if (where === "here") {
          this.closeSeededTurn(target, "completed", true);
          return { target: "here", buildId: null, builds: [] };
        }
        const buildId = `mock-build-${this.events.length}`;
        const builds = mockPlanBuilds(where === "compare" ? 2 : 1);
        this.closeSeededTurn(target, "completed", false);
        this.emit(target, {
          mux: "plan_build",
          msg: {
            event: "started",
            buildId,
            target: where,
            permissionId: params.permissionId,
            builds: builds.map(({ sessionId, name, harness, branch, root, base }) => ({
              sessionId,
              name,
              harness,
              branch,
              root,
              base,
            })),
          },
        });
        return {
          target: where,
          buildId,
          builds: builds.map(({ sessionId, name, harness, branch, root, base }) => ({
            sessionId,
            name,
            harness,
            worktree: { root, branch, base },
          })),
        };
      }
      case "_acpmux/plan/compare":
        return { buildId: params.buildId, target: "compare", keptSessionId: null, builds: mockPlanBuilds(2) };
      case "_acpmux/plan/keep": {
        const keep = String(params.keep ?? "");
        const builds = mockPlanBuilds(2).map((build) => ({ ...build, archived: build.sessionId !== keep }));
        this.emit(target, {
          mux: "plan_build",
          msg: {
            event: "kept",
            buildId: params.buildId,
            keptSessionId: keep,
            archived: builds.filter((build) => build.archived).map((build) => build.sessionId),
          },
        });
        return { buildId: params.buildId, target: "compare", keptSessionId: keep, builds };
      }
      case "session/new": {
        // A gallery state whose folder is not trusted yet: the start waits on the Trust question.
        if ((globalThis as MockAuthGlobals).cmuxAcpmuxMockTrustPending && !this.trustGranted)
          throw Object.assign(new Error("trust.pending: answer the trust question for the folder first"), {
            data: { reason: "trust.pending", cwd: String(params.cwd ?? "~/code/cmux") },
          });
        // A gallery state can stand for an agent slow to start, or one that fails to (`mockStart`).
        const start = (
          globalThis as { cmuxAcpmuxMockStart?: { delayMs?: number; error?: string; startMode?: boolean } }
        ).cmuxAcpmuxMockStart;
        if (start?.delayMs) await this.delay(start.delayMs);
        if (start?.error) throw Object.assign(new Error(start.error), { code: -32603 });
        // A new chat opens in the project of the session it was started from.
        const from = this.sessions.find((entry) => entry.sessionId === this.attached) ?? this.sessions[0];
        const profile = mockFolderProfiles.find((entry) => entry.id === params._meta?.acpmux?.harness);
        if (profile && !this.enabledProfiles.has(profile.id))
          throw Object.assign(new Error(`${profile.displayName} is not enabled in this folder`), {
            data: {
              reason: profile.state === "needs-trust" ? "harness.needs_trust" : "harness.needs_enable",
              harness: profile.id,
              folder: MOCK_PROFILE_FOLDER,
            },
          });
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
        // Its words: every text block but a pasted block's (attachments.ts promptBlocks marks those,
        // and the prompt's text never carries them), in order. Attachments the composer placed in
        // the text split the words into blocks around them, so words after an attachment stay.
        const blocks = (Array.isArray(params.prompt) ? params.prompt : []).filter(
          (block: Record<string, any>) => block?.type === "text" && typeof block.text === "string",
        );
        const text = blocks
          .filter((block: Record<string, any>) => block._meta?.cmux?.pasted !== true)
          .map((block: Record<string, string>) => block.text)
          .join("");
        // What acpmux records when something was pasted (hub/session.rs prompt_text_parts): every
        // text block, pasted ones too, one per line, and each paste's range in UTF-16 units, so the
        // sent row draws them as acpmux's echo does.
        const recorded = { text: "", pasted: [] as { start: number; end: number }[] };
        blocks.forEach((block: Record<string, any>, index: number) => {
          if (index > 0) recorded.text += "\n";
          const start = recorded.text.length;
          recorded.text += block.text;
          if (block._meta?.cmux?.pasted === true) recorded.pasted.push({ start, end: recorded.text.length });
        });
        const promptId = params._meta?.acpmux?.promptId;
        // acpmux keeps each image once and names it in the prompt's user_message.
        const images = (Array.isArray(params.prompt) ? params.prompt : [])
          .filter((block: Record<string, unknown>) => block?.type === "image" && typeof block.data === "string")
          .map((block: Record<string, string>) => {
            const id = `image-${this.promptImages.size + 1}`;
            this.promptImages.set(id, { mimeType: block.mimeType ?? "image/png", data: block.data! });
            return { id, mimeType: block.mimeType ?? "image/png", ...(block.name ? { name: block.name } : {}) };
          });
        const queued = this.pending > 0 && promptId !== undefined;
        // A queued prompt's record names its images too, so its row shows them (ComposerQueue.tsx).
        if (queued) this.emit(target, { mux: "queued", msg: { promptId, text, ...(images.length && { images }) } });
        this.pending += 1;
        const turn = this.queue
          .then(() => {
            if (queued) this.emit(target, { mux: "dequeued", msg: { promptId } });
            return this.prompt(target, text, promptId, images, recorded.pasted.length ? recorded : undefined);
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
      // The Access chip's mode, as an agent that offers it reports the switch.
      case "session/set_mode": {
        const session = this.sessions.find((entry) => entry.sessionId === target);
        const modes = session?.modes as { availableModes: { id: string }[]; currentModeId?: string } | undefined;
        const modeId = String(params.modeId);
        if (!modes?.availableModes.some((mode) => mode.id === modeId)) throw new Error(`no mode ${modeId}`);
        this.touch(target, { modes: { ...modes, currentModeId: modeId } }, false);
        return {};
      }
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
        if (level === "trusted") this.trustGranted = true;
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
        return mockGitDiff(target, params.scope, params.include_patch === true, {
          paths: Array.isArray(params.paths) ? params.paths.map(String) : undefined,
          context: typeof params.context_lines === "number" ? params.context_lines : undefined,
        });
      case "git.status":
        return mockGitStatus(target);
      case "git.commit":
        return mockGitCommit(target, params);
      case "git.push":
        return mockGitPush(target, params);
      // A gallery state can stand for acpmux naming the mode a new chat starts in, the one its
      // session then reports (`mockStart.startMode`); without it the mock names none.
      case "_acpmux/start_mode": {
        const start = (globalThis as { cmuxAcpmuxMockStart?: { startMode?: boolean } }).cmuxAcpmuxMockStart;
        if (!start?.startMode) return {};
        const harness = params.harness === "codex" ? "codex" : "claude";
        const modes = newSessionSummary("", "", 0, harness).modes as {
          availableModes: { id: string; name: string }[];
          currentModeId: string;
        };
        const mode = modes.availableModes.find((choice) => choice.id === modes.currentModeId)!;
        return { harness, modeId: mode.id, name: mode.name };
      }
      default:
        return {};
    }
  }

  /// Whether `cwd` is the seeded project's folder or inside it (its profiles apply there).
  private profileFolder(cwd: string): boolean {
    return cwd === MOCK_PROFILE_FOLDER || cwd.startsWith(`${MOCK_PROFILE_FOLDER}/`);
  }

  private folderProfiles() {
    return mockFolderProfiles.map((profile) => ({
      ...profile,
      folder: MOCK_PROFILE_FOLDER,
      path: `${MOCK_PROFILE_FOLDER}/.cmux/harnesses/${profile.id}.toml`,
      state: this.enabledProfiles.has(profile.id) ? "enabled" : profile.state,
    }));
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

  private async prompt(
    target: string,
    prompt: string,
    promptId?: string,
    images: { id: string; mimeType: string; name?: string }[] = [],
    recorded?: { text: string; pasted: { start: number; end: number }[] },
  ): Promise<unknown> {
    // A prompt queued behind a closed daemon never starts.
    if (this.closed) return { stopReason: "cancelled" };
    this.turns += 1;
    // A prompt into a seeded open turn ends that turn first, as a new prompt supersedes it.
    this.closeSeededTurn(target, "cancelled");
    this.touch(target, {
      turnCount: Number(this.sessions.find((entry) => entry.sessionId === target)?.turnCount ?? 0) + 1,
      unread: false,
      status: "running",
      indicator: "working",
    });
    const running = { cancelled: false, target };
    this.running = running;
    const started = Date.now();
    this.emit(target, {
      mux: "user_message",
      msg: { ...(recorded ?? { text: prompt }), promptId, ...(images.length > 0 ? { images } : {}) },
    });
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
    this.touch(target, { status: "idle", indicator: running.cancelled ? null : "done" });
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

  /// `{availableCommands}`: the newest command list `target`'s agent sent, as acpmux keeps it.
  private availableCommands(target: string): { availableCommands?: unknown } {
    for (let index = this.events.length - 1; index >= 0; index -= 1) {
      const event = this.events[index]!;
      if (event.sessionId === target && event.kind === "available_commands_update")
        return { availableCommands: (event.msg as any)?.params?.update };
    }
    return {};
  }

  /// The newest record's seq in `target`'s log, 0 when it has none.
  private lastSeqOf(target: string): number {
    for (let index = this.events.length - 1; index >= 0; index -= 1)
      if (this.events[index]!.sessionId === target) return this.events[index]!.seq;
    return 0;
  }

  /// A page of a session's events, as acpmux's `_acpmux/events` and `_acpmux/attach` return it
  /// (hub/paging.rs): after `afterSeq` oldest first, or (`beforeSeq`, or an attach without
  /// `afterSeq`) the newest `limit` before `beforeSeq`; a page also ends before its records pass
  /// `maxBytes` and always holds one. `kinds` keeps the commands, other exact kinds, or the transcript;
  /// `subagent` only that subagent's own records (`EventFilter::of_subagent`).
  private page(
    target: string,
    params: Record<string, any>,
    attach = false,
  ): { events: EventRecord[]; hasMore: boolean } {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const subagent = typeof params.subagent === "string" && params.subagent ? params.subagent : undefined;
    const wanted = (event: EventRecord) =>
      (subagent === undefined || subagentOwns(event, subagent)) &&
      (kinds.length === 0 ||
        kinds.includes(event.kind) ||
        (event.kind !== "available_commands_update" &&
          event.kind !== "prompt_suggestion" &&
          // As acpmux's paging.rs: the preset approval records are not transcript; a read asks by name.
          !MOCK_NOT_TRANSCRIPT.has(event.kind) &&
          kinds.includes("transcript")));
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const whole = attach && this.openWhole.has(target);
    const limit = whole
      ? Infinity
      : params.limit === undefined
        ? attach
          ? 2000
          : Infinity
        : Math.max(1, Number(params.limit));
    const maxBytes = params.maxBytes === undefined || whole ? Infinity : Number(params.maxBytes);
    const events: EventRecord[] = [];
    let bytes = 0;
    let hasMore = false;
    const take = (event: EventRecord) => {
      if (event.sessionId !== target || event.seq <= after || event.seq >= before || !wanted(event)) return true;
      if (events.length >= limit) return !(hasMore = true);
      bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
      if (events.length > 0 && bytes > maxBytes) return !(hasMore = true);
      events.push(event);
      return true;
    };
    if (newest) {
      for (let index = this.events.length - 1; index >= 0 && take(this.events[index]!); index -= 1);
      events.reverse();
    } else for (let index = 0; index < this.events.length && take(this.events[index]!); index += 1);
    return { events, hasMore };
  }

  /// The newest turn-starting prompt among the 16 user messages before a page that starts inside a
  /// turn with older records before it, as acpmux reads it (server/requests/turn_opener.rs).
  private turnOpener(target: string, page: { events: EventRecord[]; hasMore: boolean }): EventRecord | null {
    const first = page.events[0];
    const opens = (event: EventRecord) =>
      event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;
    if (!page.hasMore || !first || first.seq <= 1 || opens(first)) return null;
    const prompts = this.page(target, { beforeSeq: first.seq, limit: 16, kinds: ["user_message"] }).events;
    return [...prompts].reverse().find(opens) ?? null;
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
            msg: {
              method: "session/update",
              params: { sessionId: target, update: step.update, ...(step.meta && { _meta: step.meta }) },
            },
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
