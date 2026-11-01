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
import { mockGitCommit, mockGitDiff, mockGitPush, mockGitStatus } from "./mockGit";
import { mockFileSearch } from "./mockFiles";
import { loadTurn, streamedReply, streamedTool } from "./loadFixture";

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
type MockAuthGlobals = {
  cmuxAcpmuxMockHarnessHealth?: Record<string, { auth: "signedIn" | "signedOut" | "unknown"; login?: string }>;
  cmuxAcpmuxMockNative?: Record<string, unknown>;
  cmuxAcpmuxMockSessionAuth?: MockSessionAuth;
  /** Capability ids `initialize` names (`_meta.acpmux.capabilities`); absent names none, as an older daemon. */
  cmuxAcpmuxMockCapabilities?: string[];
  /** Gallery only: `session/new` refuses with `trust.pending` until `acp.trust.set` trusts a folder. */
  cmuxAcpmuxMockTrustPending?: boolean;
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

/// How a load run streams its turn: text deltas of `chunkChars` every `chunkMs`, and a large
/// tool call (a log or an edit) after every `toolEvery` deltas.
export type LoadStreamOptions = { seconds: number; chunkChars: number; chunkMs: number; toolEvery: number };

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
  seedLoadSession(turns: number): string {
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
      for (const step of loadTurn(turn)) this.record(id, step, at);
    }
    this.sessions.push(created);
    this.deliver({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { kind: "created", session: created } });
    return id;
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
              features: ["queueApproval", "queueGet"],
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
        const text = (Array.isArray(params.prompt) ? params.prompt : [])
          .filter(
            (block: Record<string, any>) =>
              block?.type === "text" && typeof block.text === "string" && block._meta?.cmux?.pasted !== true,
          )
          .map((block: Record<string, string>) => block.text)
          .join("");
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
            return this.prompt(target, text, promptId, images);
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
      msg: { text: prompt, promptId, ...(images.length > 0 ? { images } : {}) },
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
  /// `maxBytes` and always holds one. `kinds` keeps the commands, other exact kinds, or the transcript.
  private page(
    target: string,
    params: Record<string, any>,
    attach = false,
  ): { events: EventRecord[]; hasMore: boolean } {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const wanted = (event: EventRecord) =>
      kinds.length === 0 ||
      kinds.includes(event.kind) ||
      (event.kind !== "available_commands_update" && kinds.includes("transcript"));
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const limit = params.limit === undefined ? (attach ? 2000 : Infinity) : Math.max(1, Number(params.limit));
    const maxBytes = params.maxBytes === undefined ? Infinity : Number(params.maxBytes);
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
