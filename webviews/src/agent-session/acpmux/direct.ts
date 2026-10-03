import type { AcpmuxActivity, AcpmuxFileDiff, AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { mergeModelCatalog } from "./modelCatalog";
import { commandsFromUpdate, type SlashCommand } from "./slashCommands";
import { hostKind, sessionEntry, text, type AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { FORK_OP, servesOperation } from "./operations";
import { postNative } from "./native";
import { readTurnCheckpoint } from "./changes/model";
import { HandoffClient } from "./handoff/client";
import { PermissionGroupClient } from "./permissions/client";
import { supportsPermissionGroups, type PermissionDecision } from "./permissions/protocol";
import { AcpmuxRpcError, supportsHandoff } from "./handoff/protocol";
import { sessionEnforcement } from "./handoff/review";
import type { HandoffReviewInput } from "./handoff/review";
import { acpWire, redactEndpoint, type AcpWireLog } from "./wire";
import { acpmuxPerf } from "./perf";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  transport: "acpmux-websocket";
  endpoint: string;
  token: string;
  sessionId?: string;
  /** A pane opened as a new chat: do not fall back to the most recent session; the first prompt creates one. */
  newSession?: boolean;
  /** A tab a `cmux://session/<id>` link opened: `sessionId` must exist. When the daemon has no such
   * session the pane says so rather than falling back to the most recent one, and marks nothing seen. */
  sessionMustExist?: boolean;
  /** A new chat's working directory, inherited from the tab it was opened from. */
  cwd?: string;
  /** Text the composer starts with. Shown, never sent by itself. */
  draft?: string;
  /** A new chat's first prompt, sent once the client connects (onboarding's first task). */
  prompt?: string;
  /** An outside Claude Code or Codex chat this pane resumes once it connects. */
  adopt?: AcpmuxAdopt;
};

/** A harness's own session for acpmux to adopt (`_meta.acpmux.adopt`). */
export type AcpmuxAdopt = { harness: string; agentSessionId: string };

/** `session/new` params: the host's cwd when it gave one, else acpmux's default. An adopt
 *  sends no cwd: acpmux resumes the chat where its harness recorded it. */
export function newSessionParams(
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt">,
  harness?: string,
): Record<string, unknown> {
  if (host.adopt)
    return { mcpServers: [], _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } } };
  return { ...(host.cwd ? { cwd: host.cwd } : {}), mcpServers: [], _meta: { acpmux: { harness } } };
}

/** True when a `session/new` result resumed `adopt`. A daemon without adopt ignores the request
 *  and starts a fresh chat, whose `agentSessionId` is its own or absent. */
export function adoptedBy(result: any, adopt: AcpmuxAdopt): boolean {
  return result?._meta?.acpmux?.agentSessionId === adopt.agentSessionId;
}

export type EventRecord = {
  sessionId?: string;
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, any>;
};
type Session = Record<string, any> & { sessionId: string };
type Reply = { id: number; result?: any; error?: { message?: string; code?: unknown; data?: unknown } };
type Notification = { method: string; params?: any };
type Listener = (snapshot: AcpmuxSnapshot) => void;

/// The slash commands are not transcript, so the pane asks for their updates by kind.
const COMMANDS_KIND = "available_commands_update";
/// How much of the context window the session has used; not transcript, so attach asks for it by kind.
const USAGE_KIND = "usage_update";

export function permissionFromMessage(message: any, selectedSessionId: string): AcpmuxPermission | undefined {
  const envelope = message ?? {};
  const raw = envelope?.request ?? envelope;
  const sessionId = envelope?.sessionId ?? raw?.sessionId;
  const permissionId = envelope?.permissionId ?? raw?.permissionId;
  if (!permissionId || sessionId !== selectedSessionId) return undefined;
  return {
    permissionId: String(permissionId),
    groupId: typeof envelope.groupId === "string" ? envelope.groupId : undefined,
    turnId: typeof envelope.turnId === "string" ? envelope.turnId : undefined,
    title: raw.toolCall?.title,
    kind: raw.toolCall?.kind,
    pending: true,
    options: (raw.options ?? []).map((option: any) => ({
      id: String(option.optionId ?? option.id),
      name: String(option.name ?? option.optionId),
      allow: String(option.kind ?? "").startsWith("allow"),
    })),
  };
}

export function settleOptimisticPrompt(
  rows: Map<string, AcpmuxRow>,
  promptRows: Map<string, string>,
  message: any,
): void {
  const promptId = typeof message?.promptId === "string" ? message.promptId : undefined;
  if (!promptId) return;
  const rowId = promptRows.get(promptId);
  if (rowId) rows.delete(rowId);
  promptRows.delete(promptId);
}

export function mergeEventRecords(...batches: EventRecord[][]): EventRecord[] {
  const bySequence = new Map<number, EventRecord>();
  for (const event of batches.flat()) bySequence.set(event.seq, event);
  return [...bySequence.values()].sort((left, right) => left.seq - right.seq);
}

export function applySupersededMessage(
  rows: Map<string, AcpmuxRow>,
  messageRows: Map<string, string[]>,
  superseded: Set<string>,
  oldMessageId: string,
): void {
  superseded.add(oldMessageId);
  for (const rowId of messageRows.get(oldMessageId) ?? []) rows.delete(rowId);
  messageRows.delete(oldMessageId);
}

/** The session to attach after connect: the selected one, else the most recent unless the pane is a new chat. */
export function initialSession(
  selected: string | undefined,
  sessions: { sessionId: string }[],
  newSession?: boolean,
): string | undefined {
  if (selected) return selected;
  return newSession ? undefined : sessions[0]?.sessionId;
}

/// The file changes in a tool call's content (ACP `diff` items), placed by the call's locations.
export function toolDiffs(content: any, locations: any): AcpmuxFileDiff[] | undefined {
  if (!Array.isArray(content)) return undefined;
  const lines = new Map<string, number>();
  for (const location of Array.isArray(locations) ? locations : [])
    if (
      typeof location?.path === "string" &&
      Number.isInteger(location.line) &&
      location.line > 0 &&
      !lines.has(location.path)
    )
      lines.set(location.path, location.line);
  const diffs = content
    .filter((item: any) => item?.type === "diff" && typeof item.path === "string" && typeof item.newText === "string")
    .map((item: any): AcpmuxFileDiff => ({
      path: item.path,
      oldText: typeof item.oldText === "string" ? item.oldText : undefined,
      newText: item.newText,
      line: lines.get(item.path),
    }));
  return diffs.length ? diffs : undefined;
}

/// Diffs placed again by an update that brings only locations.
function placeDiffs(diffs: AcpmuxFileDiff[] | undefined, locations: any): AcpmuxFileDiff[] | undefined {
  if (!diffs || !Array.isArray(locations)) return diffs;
  return (
    toolDiffs(
      diffs.map((diff) => ({ type: "diff", ...diff })),
      locations,
    ) ?? diffs
  );
}

/// A tool call folded with an update to it. ACP updates carry only the fields that changed;
/// content, when present, replaces the call's content.
export function mergeToolItem(
  previous: AcpmuxActivity | undefined,
  update: any,
  callId: string,
  output: string,
): AcpmuxActivity {
  const before = previous?.tool;
  const title = update.title ?? update.name;
  return {
    kind: "tool",
    text: String(title ?? previous?.text ?? callId),
    tool: {
      id: callId,
      title: String(update.title ?? before?.title ?? callId),
      kind: update.kind ?? before?.kind,
      status: String(update.status ?? before?.status ?? "in_progress"),
      inputSummary: update.rawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output || formattedOutput(update.rawOutput) || (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      exitCode: exitCode(update.rawOutput) ?? before?.exitCode,
      locations: Array.isArray(update.locations) ? update.locations : before?.locations,
      diffs:
        update.content === undefined
          ? placeDiffs(before?.diffs, update.locations)
          : toolDiffs(update.content, Array.isArray(update.locations) ? update.locations : before?.locations),
    },
  };
}

/// The command line a shell call ran, from `rawInput.command`: a string, or an argv array. An
/// argv that runs a script through a shell (`zsh -lc "cd x && bun test"`) shows the script;
/// otherwise a part with spaces or quotes is single-quoted, so the line reads as typed.
export function shellCommand(rawInput: any): string | undefined {
  const command = rawInput?.command;
  if (typeof command === "string") return command;
  if (!Array.isArray(command) || !command.every((part) => typeof part === "string") || !command.length)
    return undefined;
  const [program, flag, script] = command as string[];
  if (command.length === 3 && /(^|\/)(ba|z|da|fi)?sh$/.test(program!) && /^-l?c$/.test(flag!)) return script;
  return (command as string[])
    .map((part) => (/^[\w@%+=:,./-]+$/.test(part) ? part : `'${part.replace(/'/g, "'\\''")}'`))
    .join(" ");
}

function exitCode(rawOutput: any): number | undefined {
  const code = rawOutput?.exit_code ?? rawOutput?.exitCode;
  return typeof code === "number" ? code : undefined;
}

/// Codex reports a shell call's output in `rawOutput` when the call carries no content.
function formattedOutput(rawOutput: any): string {
  const text = rawOutput?.formatted_output;
  return typeof text === "string" ? text : "";
}

function textFromContent(content: any): string {
  if (typeof content === "string") return content;
  if (content?.type === "text") return String(content.text ?? "");
  // A tool call's content blocks wrap their text: `{ type: "content", content: { type: "text" } }`.
  if (content?.type === "content") return textFromContent(content.content);
  if (Array.isArray(content)) return content.map(textFromContent).join("");
  return "";
}

function sessionUpdate(event: EventRecord): any | undefined {
  return event.dir === "in" && event.msg.method === "session/update" ? event.msg.params?.update : undefined;
}

/// Opens the client's socket; mock mode passes an in-page daemon (mock.ts).
export type OpenSocket = (url: URL) => WebSocket;

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

/** Direct browser client for the authenticated acpmux WebSocket protocol. */
export class AcpmuxDirectClient {
  private socket?: WebSocket;
  private nextRequest = 1;
  private pending = new Map<
    number,
    { resolve: (value: any) => void; reject: (error: Error) => void; timer?: ReturnType<typeof setTimeout> }
  >();
  private events: EventRecord[] = [];
  private rows = new Map<string, AcpmuxRow>();
  private sessions: Session[] = [];
  /// Sidebar entries by acpmux session object. A changed session arrives as a new object, so unchanged rows keep their entry and skip rendering.
  private sessionEntries = new WeakMap<Session, AcpmuxSessionEntry>();
  /// Sessions whose turn ended while another was selected. acpmux does not track what the
  /// user has seen, so the pane keeps this until the session is selected.
  private unseen = new Set<string>();
  private selectedSessionId?: string;
  /** The session a link named that the daemon does not have (`sessionMustExist`). */
  private missingSession?: string;
  private summary: Record<string, any> | undefined;
  private queue: { id: string; prompt: string }[] = [];
  private pendingPermission?: AcpmuxPermission;
  private groupedPermissions = new Map<string, AcpmuxPermission>();
  private commands: SlashCommand[] = [];
  private usage: { used: number; size: number } | undefined;
  /// Set once an update for this session is applied, so an older fetched list cannot replace it.
  private commandsApplied = false;
  private optimisticPromptRows = new Map<string, string>();
  private optimisticPromptTexts = new Map<string, string>();
  private firstSeq?: number;
  private lastSeq = 0;
  private turnOpen = false;
  /// acpmux lists `acp.session.fork` among the operations it serves.
  private canFork = false;
  private handoffSupported = false;
  readonly handoff = new HandoffClient(
    (method, params) => this.request(method, params, 15000),
    () => this.emit(),
  );
  readonly permissions = new PermissionGroupClient(
    (method, params) => this.request(method, params, 15000),
    () => {
      for (const group of this.permissions.state.groups)
        for (const item of group.items) if (item.state !== "pending") this.groupedPermissions.delete(item.permissionId);
      if (!this.permissions.state.supported && !this.pendingPermission)
        this.pendingPermission = [...this.groupedPermissions.values()].at(-1);
      this.emit();
    },
  );
  private forking = false;
  private streamingAssistant?: string;
  private streamingAssistantMessageId?: string;
  private streamingActivity?: string;
  private supersededMessageIds = new Set<string>();
  /// The rows each message streamed into; tool calls split one message into several.
  private messageRows = new Map<string, string[]>();
  /// The activity row each tool call lives in, so a late update lands where the call began.
  private toolRows = new Map<string, string>();
  private readonly listener: Listener;
  private host: AcpmuxHostConfig;
  private reconnectTimer?: number;
  private reconnectDelay = 250;
  /// Called once when an established connection drops. The host then asks Swift
  /// for a fresh handshake, because a restarted daemon has a new port and token.
  private readonly onLost?: () => void;
  private opening = false;
  private hasConnected = false;
  private closed = false;
  private selectionGeneration = 0;
  /// The selection generation whose attach reply has landed; lag resync waits for it.
  private attachedGeneration = -1;
  private historyExhausted = false;

  private constructor(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    private readonly openSocket: OpenSocket = (url) => new WebSocket(url),
    private readonly gitRoute: GitRoute = "native",
    /// Every message on the socket and its lifecycle, for the ACP inspector (wire.ts).
    private readonly wire: AcpWireLog = acpWire,
  ) {
    this.host = host;
    this.listener = listener;
    this.onLost = onLost;
    this.selectedSessionId = host.sessionId;
  }

  static async connect(
    host: AcpmuxHostConfig,
    listener: Listener,
    onLost?: () => void,
    openSocket?: OpenSocket,
    gitRoute?: GitRoute,
    wire?: AcpWireLog,
  ): Promise<AcpmuxDirectClient> {
    const client = new AcpmuxDirectClient(host, listener, onLost, openSocket, gitRoute, wire);
    await client.open();
    return client;
  }

  private async open(): Promise<void> {
    if (this.opening || this.closed) return;
    this.opening = true;
    const url = new URL(this.host.endpoint);
    url.searchParams.set("token", this.host.token);
    this.wire.lifecycle("connecting", {
      endpoint: redactEndpoint(this.host.endpoint),
      sessionId: this.selectedSessionId,
    });
    await new Promise<void>((resolve, reject) => {
      const socket = this.openSocket(url);
      this.socket = socket;
      let opened = false;
      socket.onopen = () => {
        opened = true;
        this.wire.lifecycle("open");
        resolve();
      };
      socket.onerror = () => {
        this.wire.lifecycle("error", { message: opened ? "WebSocket error" : "Unable to connect" });
        this.opening = false;
        reject(new Error("Unable to connect to acpmux WebSocket"));
      };
      socket.onclose = (event?: CloseEvent) => {
        if (this.socket !== socket) return;
        this.wire.lifecycle("close", {
          code: event?.code,
          reason: event?.reason || undefined,
          wasClean: event?.wasClean,
          established: opened,
        });
        if (!opened) {
          this.opening = false;
          reject(new Error("acpmux WebSocket closed before connect"));
          return;
        }
        this.handoff.disconnect();
        this.groupedPermissions.clear();
        this.permissions.disconnected();
        this.rejectPending();
        this.emit("disconnected");
        if (!this.hasConnected || this.closed) return;
        if (this.onLost) {
          this.wire.lifecycle("lost", { message: "asking for a fresh handshake" });
          const onLost = this.onLost;
          this.close();
          onLost();
        } else this.scheduleReconnect();
      };
      socket.onmessage = (message) => this.receive(String(message.data));
    });
    try {
      const initialized = await this.request("initialize", {
        protocolVersion: 1,
        clientInfo: { name: "cmux-react-agent-pane", version: "1" },
        clientCapabilities: {},
      });
      this.canFork = servesOperation(initialized, FORK_OP);
      this.handoffSupported = supportsHandoff(initialized);
      const groupedPermissionsSupported = supportsPermissionGroups(initialized);
      if (!groupedPermissionsSupported) this.groupedPermissions.clear();
      this.permissions.configure(groupedPermissionsSupported);
      const watched = await this.request("_acpmux/watch", { enabled: true });
      this.sessions = this.reread(watched?.sessions);
      if (this.selectedSessionId && !this.sessions.some((session) => session.sessionId === this.selectedSessionId)) {
        // A linked session the daemon lacks is refused, never replaced by the most recent chat.
        if (this.host.sessionMustExist) this.missingSession = this.selectedSessionId;
        this.selectedSessionId = this.host.sessionMustExist ? undefined : this.sessions[0]?.sessionId;
        this.selectionGeneration += 1;
        this.resetSessionState();
      }
      this.selectedSessionId = initialSession(
        this.selectedSessionId,
        this.sessions,
        this.host.newSession || this.missingSession !== undefined,
      );
      if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
      // A reconnect to the same session keeps its transcript; the attach page holds only the newest events.
      const resumeAfter = this.lastSeq;
      const sessionId = this.selectedSessionId;
      const generation = this.selectionGeneration;
      if (sessionId) {
        const page = await this.attach(sessionId, generation);
        const oldest = page.length > 0 ? Math.min(...page.map((event) => event.seq)) : 0;
        if (resumeAfter > 0 && oldest > resumeAfter + 1)
          await this.fetchMissedEvents(sessionId, generation, resumeAfter, false);
      } else if (this.host.adopt) {
        await this.adoptChat(this.host.adopt);
      }
      this.hasConnected = true;
      this.reconnectDelay = 250;
      this.wire.lifecycle("connected", { sessionId: this.selectedSessionId, sessions: this.sessions.length });
      this.emit("connected");
    } catch (error) {
      this.wire.lifecycle("connect failed", { message: error instanceof Error ? error.message : String(error) });
      this.socket?.close();
      throw error;
    } finally {
      this.opening = false;
    }
  }

  /** Drops everything that belongs to the previously selected session, before another one attaches. */
  private resetSessionState(): void {
    this.events = [];
    this.historyExhausted = false;
    this.rows.clear();
    this.firstSeq = undefined;
    this.lastSeq = 0;
    this.summary = undefined;
    this.usage = undefined;
    this.queue = [];
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.optimisticPromptRows.clear();
    this.optimisticPromptTexts.clear();
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.toolRows.clear();
    this.pendingPermission = undefined;
    this.groupedPermissions.clear();
    this.commands = [];
    this.commandsApplied = false;
    this.handoff.select(this.selectedSessionId);
    this.permissions.select(this.selectedSessionId);
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined || this.closed) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(delay * 2, 30_000);
    this.wire.lifecycle("reconnect scheduled", { delayMs: delay });
    this.reconnectTimer = window.setTimeout(() => {
      this.reconnectTimer = undefined;
      void this.open().catch(() => this.scheduleReconnect());
    }, delay);
  }

  private receive(raw: string): void {
    this.wire.received(raw);
    let message: Reply | Notification;
    try {
      message = JSON.parse(raw) as Reply | Notification;
    } catch {
      return;
    }
    if ("id" in message && typeof message.id === "number") {
      const request = this.pending.get(message.id);
      if (!request) return;
      this.pending.delete(message.id);
      if (request.timer) clearTimeout(request.timer);
      // The failure's code (`validation.invalid`, ...) and details ride along for callers that
      // tell failures apart.
      if (message.error) {
        const data = message.error.data as { code?: unknown; details?: unknown } | undefined;
        request.reject(
          Object.assign(new AcpmuxRpcError(message.error), {
            code: data?.code ?? message.error.code,
            ...(data?.details === undefined ? {} : { details: data.details }),
          }),
        );
      } else request.resolve(message.result);
      return;
    }
    const notification = message as Notification;
    if (notification.method === "_acpmux/event") this.apply(notification.params as EventRecord);
    else if (notification.method === "session/update")
      this.apply({
        sessionId: notification.params?.sessionId,
        seq: Number(notification.params?._meta?.acpmux?.seq ?? 0),
        at: Number(notification.params?._meta?.acpmux?.at ?? Date.now()),
        dir: "in",
        kind: String(notification.params?.update?.sessionUpdate ?? ""),
        msg: { method: "session/update", params: { update: notification.params?.update } },
      });
    else if (notification.method === "_acpmux/session_changed") this.sessionChanged(notification.params);
    else if (notification.method === "_acpmux/permission_pending") this.applyPermission(notification.params);
    else if (notification.method === "_acpmux/lagged") this.resyncAfterLag(notification.params);
  }

  /// The daemon dropped events for this client. Fetch what came after the last
  /// one seen and merge it in, keeping the transcript on screen meanwhile.
  /// agent-gui daemons send {sessionIds, watch, dropped}; older ones send only
  /// {dropped}, so a notice without sessionIds resyncs the selected session.
  private resyncAfterLag(params: any): void {
    if (params?.watch === true) void this.refreshSessions().catch(() => undefined);
    const sessionId = this.selectedSessionId;
    // Before the attach reply lands there is no cursor; the reply carries the latest events.
    if (!sessionId || this.attachedGeneration !== this.selectionGeneration) return;
    if (Array.isArray(params?.sessionIds) && !params.sessionIds.map(String).includes(sessionId)) return;
    this.emit("resyncing");
    void this.permissions.refresh().catch(() => {});
    const generation = this.selectionGeneration;
    void this.fetchMissedEvents(sessionId, generation, this.lastSeq).catch(() => {
      if (!this.closed && generation === this.selectionGeneration)
        this.emit(this.socket?.readyState === WebSocket.OPEN ? "failed" : "disconnected");
    });
  }

  /// Pages from its own cursor: live events keep advancing lastSeq meanwhile.
  /// The live summary, queue and permission survive the rebuild; after a lag the
  /// missed events are replayed onto them, while a fresh attach is already current.
  private async fetchMissedEvents(
    sessionId: string,
    generation: number,
    afterSeq: number,
    replayLiveState = true,
  ): Promise<void> {
    for (let cursor = afterSeq; ;) {
      const result = await this.request("_acpmux/events", { sessionId, afterSeq: cursor, limit: 5_000 });
      if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
      const missed: EventRecord[] = result?.events ?? [];
      this.events = mergeEventRecords(this.events, missed);
      this.rebuildKeepingLiveState(replayLiveState ? cursor : undefined);
      if (result?.more !== true || missed.length === 0) break;
      cursor = Math.max(cursor, ...missed.map((event) => event.seq));
    }
    this.emit("resynced");
  }

  /// session_changed notices dropped by a watch lag: reread the whole list.
  /// A selection made while the request was out is newer than the list.
  private async refreshSessions(): Promise<void> {
    const generation = this.selectionGeneration;
    const watched = await this.request("_acpmux/watch", { enabled: true });
    this.sessions = this.reread(watched?.sessions);
    const missing =
      this.selectedSessionId !== undefined &&
      !this.sessions.some((session) => session.sessionId === this.selectedSessionId);
    if (missing && generation === this.selectionGeneration) this.selectFallbackSession("session changed");
    else this.emit("session changed");
  }

  /// The selected session is gone: show the most recent remaining one, or none.
  private selectFallbackSession(reason: string): void {
    this.selectedSessionId = this.sessions[0]?.sessionId;
    if (this.selectedSessionId) this.markSeen(this.selectedSessionId);
    const generation = ++this.selectionGeneration;
    this.resetSessionState();
    this.emit(reason);
    if (this.selectedSessionId) void this.attach(this.selectedSessionId, generation).catch(() => undefined);
  }

  /// A full session list from `_acpmux/watch`. A turn whose end the reread is the first to show
  /// (its notice lost to a lag or a reconnect) counts as unseen too; sessions gone from the list
  /// leave the set.
  private reread(sessions: Session[] | undefined): Session[] {
    const next = (sessions ?? []).filter((session) => session.sessionId);
    const ids = new Set(next.map((session) => session.sessionId));
    const running = new Set(this.sessions.filter((session) => session.status === "running").map((s) => s.sessionId));
    for (const id of this.unseen) if (!ids.has(id)) this.unseen.delete(id);
    for (const session of next)
      if (
        running.has(session.sessionId) &&
        session.status !== "running" &&
        session.sessionId !== this.selectedSessionId
      )
        this.unseen.add(session.sessionId);
    return next.map(this.withUnseen);
  }

  /// The session with its unseen flag; a new object, so its sidebar entry is rebuilt.
  private withUnseen = (session: Session): Session =>
    this.unseen.has(session.sessionId) && session.unread !== true ? { ...session, unread: true } : session;

  /// Selecting a session is seeing it, including an unread flag acpmux sent.
  private markSeen(sessionId: string): void {
    this.unseen.delete(sessionId);
    this.sessions = this.sessions.map((session) =>
      session.sessionId === sessionId && session.unread === true ? { ...session, unread: false } : session,
    );
  }

  /// Whether the user trusts `cwd` (folderTrust.ts).
  trustGet(cwd: string): Promise<unknown> {
    return this.request("acp.trust.get", { cwd });
  }

  /// Records the user's trust in `cwd` in acpmux's own record, never the agents' config files (folderTrust.ts).
  trustSet(cwd: string, level: string): Promise<unknown> {
    return this.request("acp.trust.set", { cwd, level });
  }

  /// Files under `path` (else the selected session's folder) whose path matches `query`, best
  /// first (fileSearchModel.ts). acpmux serves no file search: the native host runs it on the
  /// session host as `git.files.search`, and mock mode's in-page daemon answers it.
  fileSearch(path: string | undefined, query: string, limit: number): Promise<unknown> {
    if (this.gitRoute === "daemon") return this.request("file.search", { ...(path ? { path } : {}), query, limit });
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = path ?? text(summary?.cwd) ?? text(entry?.cwd);
    if (!cwd) return Promise.reject(new Error("This chat has no working folder to search"));
    if (hostKind(summary?.hostKind) === "cloud" || entry?.hostKind === "cloud")
      return Promise.reject(new Error("This chat runs on another machine, so its files can't be searched here yet"));
    return postNative("file.search", { cwd, query, limit });
  }

  /// The selected session's repository changes in one git scope (changes/model.ts).
  gitDiff(scope: string): Promise<unknown> {
    return this.git("git.diff", { scope, include_patch: true });
  }

  /// The selected session's branch, upstream and how far it is ahead and behind.
  gitStatus(): Promise<unknown> {
    return this.git("git.status", {});
  }

  /// One turn's repository changes: checkpoint `from` against `to`, or the working tree.
  gitCheckpointDiff(from: string, to?: string): Promise<unknown> {
    return this.git("git.checkpoint.diff", { from, ...(to ? { to } : {}), include_patch: true });
  }

  /// Commits in the selected session's repository (`git.commit`; changes/gitWrite.ts builds
  /// the params and the idempotency key).
  gitCommit(params: Record<string, unknown>): Promise<unknown> {
    return this.git("git.commit", params);
  }

  /// Pushes the selected session's branch (`git.push`); never forced.
  gitPush(params: Record<string, unknown>): Promise<unknown> {
    return this.git("git.push", params);
  }

  /// acpmux serves no git methods: the native host runs them on the session host in the selected
  /// session's folder, and mock mode's in-page daemon answers them by session.
  private git(
    method: "git.diff" | "git.status" | "git.checkpoint.diff" | "git.commit" | "git.push",
    params: Record<string, unknown>,
  ): Promise<unknown> {
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = text(summary?.cwd) ?? text(entry?.cwd);
    if (!sessionId || !cwd) return Promise.reject(new Error("This chat has no working folder to read changes from"));
    // The native host reads folders on this Mac; a cloud session's folder is on its machine.
    if (hostKind(summary?.hostKind) === "cloud" || entry?.hostKind === "cloud")
      return Promise.reject(new Error("This chat runs on another machine, so its changes can't be read here yet"));
    const asked =
      this.gitRoute === "daemon"
        ? this.request(method, { sessionId, cwd, ...params })
        : postNative(method, { cwd, ...params });
    // A status read names the session it read, so a commit or push built on it says which
    // session's repository the reader saw; the host refuses one for another session.
    return method === "git.status"
      ? asked.then((value) =>
          value && typeof value === "object" ? { ...(value as object), session_id: sessionId } : value,
        )
      : asked;
  }

  private request(method: string, params: Record<string, unknown>, deadline?: number): Promise<any> {
    if (this.socket?.readyState !== WebSocket.OPEN)
      return Promise.reject(
        Object.assign(new Error("acpmux WebSocket is not open"), { code: "native.not_connected", origin: "native" }),
      );
    const id = this.nextRequest++;
    return new Promise((resolve, reject) => {
      const timer = deadline
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(
              Object.assign(new Error("The agent request timed out. Read its saved state before retrying."), {
                code: "native.timed_out",
                origin: "native",
              }),
            );
          }, deadline)
        : undefined;
      this.pending.set(id, { resolve, reject, timer });
      const text = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      this.wire.sent(text, method, id);
      this.socket!.send(text);
    });
  }

  /// Returns the attach page's events, or none when the selection moved on.
  private async attach(sessionId: string, generation = this.selectionGeneration): Promise<EventRecord[]> {
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const result = await this.request("_acpmux/attach", {
      sessionId,
      limit: 400,
      kinds: ["transcript", COMMANDS_KIND, USAGE_KIND],
      eventStream: true,
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    const page: EventRecord[] = result?.events ?? [];
    // An agent usually lists its commands once, at start, which is older than the page.
    if (
      !page.some((event) => event.kind === COMMANDS_KIND) &&
      typeof result?.lastSeq === "number" &&
      result.lastSeq > 0
    )
      void this.fetchCommands(sessionId, generation, result.lastSeq).catch(() => {});
    const detail = result?.session ?? {};
    this.summary = detail;
    this.queue = (detail.queue ?? []).map((entry: any) => ({
      id: String(entry.promptId),
      prompt: String(entry.prompt ?? ""),
    }));
    this.events = mergeEventRecords(page, this.events);
    this.rebuild();
    this.attachedGeneration = generation;
    this.permissions.select(sessionId);
    await this.permissions.refresh().catch(() => {});
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return [];
    if (Array.isArray(detail.pending)) {
      const groupedIds = new Set(
        this.permissions.state.supported
          ? this.permissions.state.groups.flatMap((group) => group.items.map((item) => item.permissionId))
          : [],
      );
      this.pendingPermission = detail.pending
        .map((item: any) => permissionFromMessage({ ...item, sessionId }, sessionId))
        .find(
          (item: AcpmuxPermission | undefined) =>
            item && (!this.permissions.state.supported || (!item.groupId && !groupedIds.has(item.permissionId))),
        );
    }
    if (this.handoffSupported) {
      this.handoff.select(sessionId);
      try {
        await this.handoff.refresh();
      } catch {
        /* No mutation until a recovery read succeeds. */
      }
    }
    if (generation !== this.selectionGeneration) return [];
    this.emit("attached");
    return page;
  }

  /// The newest command list at or before `lastSeq`, unless a live update already arrived.
  private async fetchCommands(sessionId: string, generation: number, lastSeq: number): Promise<void> {
    const result = await this.request("_acpmux/events", {
      sessionId,
      beforeSeq: lastSeq + 1,
      limit: 1,
      kinds: [COMMANDS_KIND],
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId || this.commandsApplied) return;
    const event: EventRecord | undefined = result?.events?.at(-1);
    const commands = event ? commandsFromUpdate(sessionUpdate(event)) : undefined;
    if (!commands) return;
    this.commands = commands;
    this.emit("commands");
  }

  private sessionChanged(params: any): void {
    const session = params?.session;
    if (params?.kind === "purged" && session?.sessionId) {
      this.sessions = this.sessions.filter((item) => item.sessionId !== session.sessionId);
      this.unseen.delete(session.sessionId);
      if (session.sessionId === this.selectedSessionId && this.handoff.state.busy !== "discarding")
        this.selectFallbackSession("session purged");
      else this.emit("session purged");
      return;
    }
    if (!session?.sessionId) return;
    const before = this.sessions.find((item) => item.sessionId === session.sessionId);
    // A turn that ends in the background is news the user hasn't seen.
    if (session.sessionId !== this.selectedSessionId && before?.status === "running" && session.status !== "running")
      this.unseen.add(session.sessionId);
    this.sessions = [...this.sessions.filter((item) => item.sessionId !== session.sessionId), this.withUnseen(session)];
    if (session.sessionId === this.selectedSessionId) {
      this.summary = { ...this.summary, ...session };
      // A change that doesn't carry the queue keeps the one already mapped.
      if (session.queue)
        this.queue = session.queue.map((entry: any) => ({
          id: String(entry.promptId),
          prompt: String(entry.prompt ?? entry.preview ?? ""),
        }));
    }
    // The picker lists every session, so a change elsewhere still needs a snapshot.
    this.emit("session changed");
  }

  private applyPermission(message: any): void {
    const permission = permissionFromMessage(message, this.selectedSessionId ?? "");
    if (!permission) return;
    if (permission.groupId && this.permissions.state.supported) {
      this.groupedPermissions.set(permission.permissionId, permission);
      return;
    }
    this.pendingPermission = permission;
    this.emit("permission");
  }

  private apply(event: EventRecord): void {
    if (!event?.seq || event.sessionId !== this.selectedSessionId || event.seq <= this.lastSeq) return;
    this.events.push(event);
    this.lastSeq = event.seq;
    this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
    this.reduce(event);
    this.emit(event.kind);
  }

  private rebuild(): void {
    // A prompt still in flight keeps its optimistic row until an event settles it; a failed one stays to show it was not sent.
    const inFlight = new Set(this.optimisticPromptRows.values());
    const local = [...this.rows.values()].filter((row) => row.failed || inFlight.has(row.id));
    this.rows.clear();
    for (const row of local) this.rows.set(row.id, row);
    this.firstSeq = undefined;
    this.lastSeq = 0;
    this.turnOpen = false;
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
    this.streamingActivity = undefined;
    this.supersededMessageIds.clear();
    this.messageRows.clear();
    this.toolRows.clear();
    this.pendingPermission = undefined;
    const events = [...this.events].sort((a, b) => a.seq - b.seq);
    for (const event of events) {
      this.lastSeq = Math.max(this.lastSeq, event.seq);
      this.firstSeq = this.firstSeq === undefined ? event.seq : Math.min(this.firstSeq, event.seq);
      this.reduce(event);
    }
  }

  /// rebuild() replays a partial event window, so keep the live summary, queue and
  /// permission; events after replayAfterSeq are then reapplied on top of them.
  private rebuildKeepingLiveState(replayAfterSeq?: number): void {
    const summary = this.summary;
    const queue = this.queue;
    const permission = this.pendingPermission;
    this.rebuild();
    this.summary = summary;
    this.queue = queue;
    this.pendingPermission = permission;
    if (replayAfterSeq !== undefined)
      for (const event of this.events)
        if (event.seq > replayAfterSeq && event.dir === "mux") this.reduceLiveState(event);
  }

  /// Mux events that move the live summary, queue or permission.
  private reduceLiveState(event: EventRecord): void {
    const msg = event.msg ?? {};
    if (event.kind === "queued" || event.kind === "queue_updated") {
      const id = String(msg.promptId ?? "");
      if (id) this.queue = [...this.queue.filter((entry) => entry.id !== id), { id, prompt: String(msg.text ?? "") }];
    } else if (event.kind === "queue_removed" || event.kind === "dequeued")
      this.queue = this.queue.filter((entry) => entry.id !== String(msg.promptId ?? ""));
    else if (event.kind === "permission_request") this.applyPermission({ ...msg, sessionId: event.sessionId });
    else if (event.kind === "permission_decision") {
      if (msg.permissionId) this.groupedPermissions.delete(String(msg.permissionId));
      else this.groupedPermissions.clear();
      if (!msg.permissionId || this.pendingPermission?.permissionId === msg.permissionId)
        this.pendingPermission = this.permissions.state.supported
          ? undefined
          : [...this.groupedPermissions.values()].at(-1);
    } else if (event.kind === "permission_group" || event.kind === "permission_chat_allowance")
      void this.permissions.refresh().catch(() => {});
    else if (event.kind === "status") this.summary = { ...this.summary, status: msg.status };
  }

  private reduce(event: EventRecord): void {
    const msg = event.msg ?? {};
    const update = sessionUpdate(event);
    if (update?.sessionUpdate === USAGE_KIND) {
      const used = Number(update.used);
      const size = Number(update.size);
      if (Number.isFinite(used) && Number.isFinite(size) && size > 0) this.usage = { used, size };
      return;
    }
    if (event.dir === "mux") {
      if (event.kind === "user_message") {
        const promptId = typeof msg.promptId === "string" ? msg.promptId : undefined;
        const text = typeof msg.text === "string" ? msg.text : undefined;
        const fallbackPromptId =
          promptId ??
          (text ? [...this.optimisticPromptTexts.entries()].find(([, value]) => value === text)?.[0] : undefined);
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, { ...msg, promptId: fallbackPromptId });
        if (fallbackPromptId) this.optimisticPromptTexts.delete(fallbackPromptId);
        this.endAssistantSegment();
        this.streamingActivity = undefined;
        this.rows.set(`user-${event.seq}`, {
          id: `user-${event.seq}`,
          version: 1,
          at: event.at,
          kind: "user",
          text: String(msg.text ?? ""),
        });
        this.turnOpen = true;
      } else if (event.kind === "turn_started") {
        this.turnOpen = true;
        this.rows.set("typing", { id: "typing", version: 1, at: event.at, kind: "typing" });
      } else if (event.kind === "message_superseded") {
        const oldMessageId = typeof msg.oldMessageId === "string" ? msg.oldMessageId : undefined;
        if (oldMessageId) {
          applySupersededMessage(this.rows, this.messageRows, this.supersededMessageIds, oldMessageId);
          if (this.streamingAssistantMessageId === oldMessageId) {
            this.streamingAssistant = undefined;
            this.streamingAssistantMessageId = undefined;
          }
        }
      } else if (event.kind === "turn_end" || event.kind === "turn_result") {
        this.turnOpen = false;
        this.pendingPermission = undefined;
        this.groupedPermissions.clear();
        if (this.streamingAssistant) {
          const row = this.rows.get(this.streamingAssistant);
          if (row) {
            row.streaming = false;
            row.version += 1;
          }
        }
        this.rows.delete("typing");
        const checkpoint = event.kind === "turn_result" ? readTurnCheckpoint(msg) : undefined;
        if (event.kind === "turn_result")
          this.rows.set(`summary-${event.seq}`, {
            id: `summary-${event.seq}`,
            version: 1,
            at: event.at,
            kind: "turnSummary",
            seq: event.seq,
            ...this.turnTotals(event.at),
            status: String(msg.status ?? "completed"),
            error: msg.errorText,
            ...(checkpoint ? { checkpoint } : {}),
          });
        this.streamingAssistant = undefined;
        this.streamingAssistantMessageId = undefined;
        this.streamingActivity = undefined;
      } else this.reduceLiveState(event);
      return;
    }
    if (!update) return;
    const commands = commandsFromUpdate(update);
    if (commands) {
      this.commands = commands;
      this.commandsApplied = true;
      return;
    }
    const text = textFromContent(update.content);
    if (event.kind === "agent_message_chunk" && text) {
      acpmuxPerf.markAgent("firstToken");
      const messageId = typeof update.messageId === "string" ? update.messageId : undefined;
      if (messageId && this.supersededMessageIds.has(messageId)) return;
      const sameMessage = Boolean(
        this.streamingAssistant &&
        (!messageId || !this.streamingAssistantMessageId || this.streamingAssistantMessageId === messageId),
      );
      const id = sameMessage ? this.streamingAssistant! : `assistant-${event.seq}`;
      const existing = this.rows.get(id);
      // Text after tool calls is a new segment; the next tool call opens a new fold.
      this.streamingActivity = undefined;
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "assistant",
        text: `${existing?.text ?? ""}${text}`,
        streaming: true,
      });
      this.streamingAssistant = id;
      this.streamingAssistantMessageId = messageId;
      if (messageId) {
        const ids = this.messageRows.get(messageId) ?? [];
        if (!ids.includes(id)) this.messageRows.set(messageId, [...ids, id]);
      }
      this.rows.delete("typing");
    } else if (event.kind === "agent_thought_chunk" && text) {
      this.endAssistantSegment();
      const id = this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: existing?.toolCount ?? 0,
        items: [...(existing?.items ?? []), { kind: "thought", text }],
      });
      this.streamingActivity = id;
    } else if (event.kind === "tool_call" || event.kind === "tool_call_update") {
      const callId = String(update.toolCallId ?? `tool-${event.seq}`);
      // An update to a call already shown stays in its fold; a new call ends the text segment.
      const known = this.toolRows.get(callId);
      const knownRow = known && this.rows.has(known) ? known : undefined;
      if (!knownRow) this.endAssistantSegment();
      const id = knownRow ?? this.streamingActivity ?? `activity-${event.seq}`;
      const existing = this.rows.get(id);
      const items = [...(existing?.items ?? [])];
      const itemIndex = items.findIndex((item) => item.tool?.id === callId);
      const item = mergeToolItem(itemIndex >= 0 ? items[itemIndex] : undefined, update, callId, text);
      if (itemIndex >= 0) items[itemIndex] = item;
      else items.push(item);
      this.rows.set(id, {
        id,
        version: (existing?.version ?? 0) + 1,
        at: existing?.at ?? event.at,
        kind: "activity",
        toolCount: items.filter((entry) => entry.kind === "tool").length,
        items,
      });
      this.toolRows.set(callId, id);
      if (!knownRow) this.streamingActivity = id;
    } else if (event.kind === "plan")
      this.rows.set(`plan-${event.seq}`, {
        id: `plan-${event.seq}`,
        version: 1,
        at: event.at,
        kind: "plan",
        text: text || JSON.stringify(update.entries ?? update.content ?? ""),
      });
  }

  /// The tool calls and time since the turn's user message. A prompt still sending (queued
  /// behind this turn) or one that failed to send did not start a turn.
  private turnTotals(endedAt: number): { durationMs?: number; toolCount: number } {
    const rows = [...this.rows.values()].filter((row) => !row.pending && !row.failed).sort((a, b) => a.at - b.at);
    let start = rows.length;
    while (start > 0 && rows[start - 1]!.kind !== "user") start -= 1;
    const user = rows[start - 1];
    const toolCount = rows
      .slice(start)
      .reduce((sum, row) => sum + (row.kind === "activity" ? (row.toolCount ?? 0) : 0), 0);
    return { durationMs: user ? Math.max(0, endedAt - user.at) : undefined, toolCount };
  }

  /// Closes the assistant text being streamed, so later text starts a new row below.
  private endAssistantSegment(): void {
    if (!this.streamingAssistant) return;
    const row = this.rows.get(this.streamingAssistant);
    if (row) this.rows.set(row.id, { ...row, version: row.version + 1, streaming: false });
    this.streamingAssistant = undefined;
    this.streamingAssistantMessageId = undefined;
  }

  private emit(connection = "connected"): void {
    const summary = this.summary;
    const effort = (summary?.configOptions ?? []).find(
      (option: any) => option.category === "thought_level" || option.id === "reasoning_effort",
    );
    this.listener({
      type: "snapshot",
      protocolVersion: 1,
      rows: [...this.rows.values()].sort((a, b) => a.at - b.at),
      sessions: this.sessions.map((session) => {
        let entry = this.sessionEntries.get(session);
        if (!entry) {
          entry = sessionEntry(session);
          this.sessionEntries.set(session, entry);
        }
        return entry;
      }),
      summary: summary
        ? {
            sessionId: summary.sessionId,
            cwd: summary.cwd,
            turnCount: summary.turnCount,
            usage: this.usage,
            host: text(summary.host),
            hostKind: hostKind(summary.hostKind),
            branch: text(summary.branch),
            worktree: text(summary.worktree),
            title: summary.title,
            name: summary.name,
            harness: summary.harness,
            model: summary.model,
            effort: effort?.currentValue,
            status: summary.status,
            enforcement: sessionEnforcement(summary.enforcement),
            modes: summary.modes,
            configOptions: summary.configOptions,
          }
        : undefined,
      connection,
      sessionId: this.selectedSessionId,
      isWorking: this.turnOpen || summary?.status === "running",
      canFork: this.canFork,
      canHandoff: this.handoffSupported,
      handoff: this.handoff.state,
      permissionGroups: this.permissions.state,
      queue: this.queue,
      permission: this.pendingPermission,
      catalog: [],
      commands: this.commands,
      canLoadOlder: !this.historyExhausted && (this.firstSeq ?? 1) > 1,
      missingSession: this.selectedSessionId ? undefined : this.missingSession,
    });
  }

  snapshot(): void {
    this.emit();
  }
  /** The session this pane shows, if any. */
  get selectedSession(): string | undefined {
    return this.selectedSessionId;
  }
  /** A `session/new` in flight, so a Send during the first prompt's start joins it. */
  private creating?: Promise<string | undefined>;
  async ensureSession(): Promise<string | undefined> {
    if (!this.selectedSessionId) {
      this.creating ??= this.create().finally(() => (this.creating = undefined));
      await this.creating;
    }
    return this.selectedSessionId;
  }

  /// Starts one live agent child for each of the most recent project sessions.
  /// Old daemons simply reject this extension, so warming never blocks chat.
  async warmRecentProjects(limit = 3): Promise<void> {
    const ids: string[] = [];
    const seen = new Set<string>();
    for (const session of [...this.sessions].sort((a, b) => Number(b.updatedAt ?? 0) - Number(a.updatedAt ?? 0))) {
      const cwd = typeof session.cwd === "string" ? session.cwd : "";
      if (!cwd || seen.has(cwd)) continue;
      seen.add(cwd);
      ids.push(session.sessionId);
      if (ids.length >= limit) break;
    }
    if (!ids.length) return;
    await this.request("_acpmux/warm", { sessionIds: ids, limit }).catch(() => undefined);
  }
  async send(text: string): Promise<string | undefined> {
    const record = this.handoff.state.record;
    if (
      this.handoffSupported &&
      this.selectedSessionId &&
      (!this.handoff.state.ready ||
        (record?.target.sessionId === this.selectedSessionId &&
          record.state !== "started" &&
          record.state !== "discarded" &&
          !this.handoff.state.receipt))
    )
      throw new Error("Review the continuation before sending a prompt.");
    const sessionId = await this.ensureSession();
    if (!sessionId) return undefined;
    const promptId = crypto.randomUUID();
    const rowId = `local-${promptId}`;
    const at = Date.now();
    this.optimisticPromptRows.set(promptId, rowId);
    this.optimisticPromptTexts.set(promptId, text);
    this.rows.set(rowId, { id: rowId, version: 1, at, kind: "user", text, pending: true });
    this.emit();
    try {
      await this.request("session/prompt", {
        sessionId,
        prompt: [{ type: "text", text }],
        _meta: { acpmux: { promptId } },
      });
    } catch (error) {
      const row = this.rows.get(rowId);
      if (row) {
        row.pending = false;
        row.failed = true;
        row.version += 1;
      }
      this.optimisticPromptRows.delete(promptId);
      this.optimisticPromptTexts.delete(promptId);
      this.emit("failed");
      throw error;
    }
    return sessionId;
  }
  async continueIn(harness: string): Promise<string | undefined> {
    if (!this.handoffSupported || this.turnOpen || this.summary?.status === "running" || this.queue.length > 0) return;
    const generation = this.selectionGeneration;
    const record = await this.handoff.prepare(harness);
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.target.sessionId);
  }
  saveHandoff(review: HandoffReviewInput) {
    return this.handoff.save(review);
  }
  startHandoff(review: HandoffReviewInput) {
    return this.handoff.start(review);
  }
  async discardHandoff(): Promise<string | undefined> {
    const generation = this.selectionGeneration;
    const record = await this.handoff.discard();
    if (!record || generation !== this.selectionGeneration) return;
    return this.select(record.source.sessionId);
  }
  refreshHandoff() {
    return this.handoff.refresh();
  }
  async cancel(): Promise<void> {
    if (!this.selectedSessionId || !this.socket) return;
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "session/cancel",
      params: { sessionId: this.selectedSessionId },
    });
    this.wire.sent(text, "session/cancel");
    this.socket.send(text);
  }
  async permission(permissionId: string, optionId: string): Promise<void> {
    if (this.selectedSessionId)
      await this.request("_acpmux/permission_respond", { sessionId: this.selectedSessionId, permissionId, optionId });
  }
  async permissionGroup(groupId: string, revision: number, decision: PermissionDecision): Promise<void> {
    await this.permissions.respond(groupId, revision, decision);
  }
  async select(sessionId: string): Promise<string | undefined> {
    const previousSessionId = this.selectedSessionId;
    const generation = ++this.selectionGeneration;
    this.selectedSessionId = sessionId;
    this.missingSession = undefined;
    this.markSeen(sessionId);
    this.resetSessionState();
    if (previousSessionId) await this.request("_acpmux/detach", { sessionId: previousSessionId });
    await this.attach(sessionId, generation);
    return generation === this.selectionGeneration && this.selectedSessionId === sessionId ? sessionId : undefined;
  }
  /// A new session, in `cwd` when given; otherwise in the inherited cwd, then where acpmux defaults.
  async create(harness?: string, cwd?: string): Promise<string | undefined> {
    const result = await this.request("session/new", newSessionParams(cwd ? { cwd } : this.host, harness));
    // The inherited cwd is the first default chat's; later ones start where acpmux defaults.
    if (result?.sessionId && !cwd) this.host = { ...this.host, cwd: undefined };
    if (result?.sessionId) return this.select(String(result.sessionId));
    return undefined;
  }
  /** The session an adopt on connect resumed, for the host to keep as the tab's session. */
  adopted?: string;
  /// Resumes the outside chat the host named, once. A session that didn't adopt it (an acpmux
  /// without adopt starts a fresh one) is removed, and the pane says so instead of posing as it.
  /// A socket that drops meanwhile fails the connect, so the host reconnects and adopts again
  /// (acpmux maps one chat to one session).
  private async adoptChat(adopt: AcpmuxAdopt): Promise<void> {
    this.host = { ...this.host, adopt: undefined };
    let result: any;
    try {
      result = await this.request("session/new", newSessionParams({ adopt }));
    } catch (error) {
      if (this.socket?.readyState !== WebSocket.OPEN) throw error;
      this.adoptFailed(error instanceof Error && error.message ? `: ${error.message}` : "");
      return;
    }
    const sessionId = result?.sessionId ? String(result.sessionId) : undefined;
    if (sessionId && adoptedBy(result, adopt)) {
      this.adopted = sessionId;
      await this.select(sessionId);
      return;
    }
    if (sessionId) await this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
    this.adoptFailed(": this acpmux can't resume chats");
  }
  private adoptFailed(reason: string): void {
    const at = Date.now();
    this.rows.set(`notice-adopt-${at}`, {
      id: `notice-adopt-${at}`,
      version: 1,
      at,
      kind: "notice",
      text: `Couldn't resume this chat${reason}`,
    });
    this.emit();
  }
  /// Forks the open session through the turn whose summary is `throughSeq`, and opens the fork.
  /// One fork at a time; a second click while acpmux forks does nothing. A failure says so in the
  /// transcript; a reader who opened another session meanwhile stays there.
  async fork(throughSeq: number): Promise<string | undefined> {
    if (!this.canFork || !this.selectedSessionId || this.forking) return undefined;
    this.forking = true;
    const generation = this.selectionGeneration;
    try {
      const result = await this.request(FORK_OP, { sessionId: this.selectedSessionId, throughSeq });
      if (!result?.sessionId || generation !== this.selectionGeneration) return undefined;
      return await this.select(String(result.sessionId));
    } catch (error) {
      if (generation === this.selectionGeneration) {
        const at = Date.now();
        const reason = error instanceof Error && error.message ? `: ${error.message}` : "";
        this.rows.set(`notice-fork-${at}`, {
          id: `notice-fork-${at}`,
          version: 1,
          at,
          kind: "notice",
          text: `Couldn't fork this chat${reason}`,
        });
        this.emit("fork failed");
      }
      return undefined;
    } finally {
      this.forking = false;
    }
  }
  async setModel(modelId: string): Promise<void> {
    if (this.selectedSessionId) await this.request("session/set_model", { sessionId: this.selectedSessionId, modelId });
  }
  async setMode(modeId: string): Promise<void> {
    if (this.selectedSessionId) await this.request("session/set_mode", { sessionId: this.selectedSessionId, modeId });
  }
  async setConfig(configId: string, value: string): Promise<void> {
    if (this.selectedSessionId)
      await this.request("session/set_config_option", { sessionId: this.selectedSessionId, configId, value });
  }
  /** The harness and model catalog. Server state the pane caches with TanStack Query (catalog.ts), so connect does not wait on it. */
  async harnesses(): Promise<AcpmuxSnapshot["catalog"]> {
    // The harness list carries no models; acpmux serves the probed ones apart (modelCatalog.ts).
    const [names, probed] = await Promise.all([
      this.request("_acpmux/harnesses", {}),
      this.request("_acpmux/models", {}).catch(() => undefined),
    ]);
    return mergeModelCatalog(names, probed);
  }
  /// Pages older transcript events in without reattaching, so the live summary,
  /// queue and permission stay as they are. A page that lands after the
  /// selection changed belongs to another session and is dropped.
  async loadOlder(): Promise<void> {
    if (!this.selectedSessionId || !this.firstSeq || this.firstSeq <= 1 || this.historyExhausted) return;
    const sessionId = this.selectedSessionId;
    const generation = this.selectionGeneration;
    const result = await this.request("_acpmux/events", {
      sessionId,
      beforeSeq: this.firstSeq,
      limit: 400,
      kinds: ["transcript"],
    });
    if (generation !== this.selectionGeneration || this.selectedSessionId !== sessionId) return;
    const older: EventRecord[] = result?.events ?? [];
    this.events = mergeEventRecords(older, this.events);
    this.rebuildKeepingLiveState();
    this.historyExhausted = result?.more === false || older.length === 0 || (this.firstSeq ?? 1) <= 1;
    this.emit("history");
  }
  /// The socket's own onclose ignores a socket close() already let go of, so settle requests here.
  close(): void {
    this.closed = true;
    if (this.reconnectTimer !== undefined) window.clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.permissions.disconnected();
    this.socket?.close();
    this.socket = undefined;
    this.rejectPending();
  }
  private rejectPending(): void {
    for (const request of this.pending.values()) {
      if (request.timer) clearTimeout(request.timer);
      request.reject(
        Object.assign(new Error("The agent connection was interrupted. Read its saved state before retrying."), {
          code: "native.timed_out",
          origin: "native",
        }),
      );
    }
    this.pending.clear();
  }
}

export function normalizeCatalog(value: any): AcpmuxSnapshot["catalog"] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  return (
    Array.isArray(harnesses) ? harnesses : Object.entries(harnesses).map(([id, data]) => ({ id, ...(data as any) }))
  ).map((harness: any) => ({
    id: String(harness.id ?? harness.name),
    name: agentName(String(harness.id ?? harness.name), harness.name == null ? undefined : String(harness.name)),
    models: (harness.models ?? []).map((model: any) => ({ id: String(model.id ?? model.modelId), name: model.name })),
  }));
}
