import type { AcpmuxActivity, AcpmuxFileDiff, AcpmuxPermission, AcpmuxRow, AcpmuxSnapshot } from "./model";
import { mergeModelCatalog } from "./modelCatalog";
import { commandsFromUpdate, type SlashCommand } from "./slashCommands";
import { promptBlocks, promptText, type ComposerAttachment } from "./attachments";
import { hostKind, sessionEntry, text, type AcpmuxSessionEntry } from "./sessionList";
import { agentName } from "./agents";
import { FORK_OP, servesOperation } from "./operations";
import { postNative } from "./native";
import { readSummaryCheckpoint } from "./changes/turnCheckpointSource";
import { HandoffClient } from "./handoff/client";
import { PermissionGroupClient } from "./permissions/client";
import { supportsPermissionGroups, type PermissionDecision } from "./permissions/protocol";
import { AcpmuxRpcError, supportsHandoff } from "./handoff/protocol";
import { sessionEnforcement } from "./handoff/review";
import type { HandoffReviewInput } from "./handoff/review";
import { acpWire, redactEndpoint, type AcpWireLog } from "./wire";
import { acpmuxPerf } from "./perf";
import { translate } from "./i18n";
import { errorMessage } from "./transportErrors";

export type AcpmuxHostConfig = {
  protocolVersion: number;
  /// `acpmux-bridge`: the app's host owns the socket and its tokens (bridgeSocket.ts); this page
  /// gets neither endpoint nor token. `acpmux-websocket`: a real socket, only for the browser dev
  /// slot (devHost.ts) and mock mode.
  transport: "acpmux-websocket" | "acpmux-bridge";
  endpoint?: string;
  token?: string;
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
  host: Pick<AcpmuxHostConfig, "cwd" | "adopt"> & { peer?: string },
  harness?: string,
): Record<string, unknown> {
  if (host.adopt)
    return {
      mcpServers: [],
      _meta: { acpmux: { harness: harness ?? host.adopt.harness, adopt: host.adopt } },
    };
  return {
    ...(host.cwd ? { cwd: host.cwd } : {}),
    mcpServers: [],
    _meta: { acpmux: { harness, ...(host.peer ? { peer: host.peer } : {}) } },
  };
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
type Reply = {
  id: number;
  result?: any;
  error?: { message?: string; code?: unknown; data?: unknown };
};
type Notification = { method: string; params?: any };
type Listener = (snapshot: AcpmuxSnapshot) => void;

/// A hint that a harness is likely next, so acpmux can warm its adapter (cmux-tui acpmux lane).
export const PREWARM_METHOD = "_acpmux/prewarm";

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
/// content, when present, replaces the call's content. `at` is the event's time: the call
/// starts at its first event and ends at the first that reports it completed or failed.
export function mergeToolItem(
  previous: AcpmuxActivity | undefined,
  update: any,
  callId: string,
  output: string,
  at?: number,
): AcpmuxActivity {
  const before = previous?.tool;
  const title = update.title ?? update.name;
  const status = String(update.status ?? before?.status ?? "in_progress");
  const ended = status === "completed" || status === "failed";
  return {
    kind: "tool",
    text: String(title ?? previous?.text ?? callId),
    tool: {
      id: callId,
      title: String(update.title ?? before?.title ?? callId),
      kind: update.kind ?? before?.kind,
      status,
      inputSummary: update.rawInput ? JSON.stringify(update.rawInput) : before?.inputSummary,
      output:
        output || formattedOutput(update.rawOutput) || (update.content === undefined ? before?.output : undefined),
      command: shellCommand(update.rawInput) ?? before?.command,
      exitCode: exitCode(update.rawOutput) ?? before?.exitCode,
      startedAt: before?.startedAt ?? at,
      endedAt: before?.endedAt ?? (ended ? at : undefined),
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

/// Opens the client's socket; mock mode passes an in-page daemon (mock.ts), the app the host
/// bridge (bridgeSocket.ts).
export type OpenSocket = (url: URL) => WebSocket;

/// The placeholder URL of a bridge connection (never dialed).
export const BRIDGE_URL = "cmux-bridge://acpmux/";

/// Where git reads go: the native host, or in mock mode the daemon the socket reaches.
export type GitRoute = "native" | "daemon";

/// Runs `run` once before the next display frame, or after 50 ms when the page draws no frames
/// (a hidden pane), so a hidden transcript still keeps up.
export const nextFrame = (run: () => void) => {
  let ran = false;
  const once = () => {
    if (ran) return;
    ran = true;
    run();
  };
  requestAnimationFrame(once);
  setTimeout(once, 50);
};

/// A thought chunk continues the thought it follows: a thought streams into one growing item,
/// not one row per chunk.
export function appendThought(items: AcpmuxActivity[], text: string): AcpmuxActivity[] {
  const last = items.at(-1);
  if (last?.kind === "thought" && !last.tool) return [...items.slice(0, -1), { ...last, text: last.text + text }];
  return [...items, { kind: "thought", text }];
}

/// Notices made in one millisecond each keep their row: the id carries a counter, not the time.
let notices = 0;
const noticeId = (kind: string) => `${kind}-${(notices += 1)}`;

/// Transcript rows in the daemon's event order: each row keeps the sequence number of the event
/// that created it, so two wall clocks (or one millisecond) never put a prompt under its reply.
/// A row made without an event (a prompt sending or failed, a notice, the typing row) orders after
/// the events seen when it was made, so later turns go below it; after a lag rebuild, which
/// replays events older than it, it moves after them again.
export class OrderedRows extends Map<string, AcpmuxRow> {
  private readonly order = new Map<string, number>();
  private readonly local = new Set<string>();
  private made = 0;
  /// The sequence number of the event being reduced.
  current: number | undefined;
  /// The newest event reduced so far.
  private latest = 0;

  override set(id: string, row: AcpmuxRow): this {
    if (!this.order.has(id)) {
      if (this.current !== undefined) {
        this.order.set(id, this.current);
        this.latest = Math.max(this.latest, this.current);
      } else {
        this.order.set(id, this.latest + 0.5 + (this.made += 1e-6));
        this.local.add(id);
      }
    } else if (this.current !== undefined) this.latest = Math.max(this.latest, this.current);
    return super.set(id, row);
  }

  /// An event was reduced (it may have made no row).
  saw(seq: number): void {
    this.latest = Math.max(this.latest, seq);
  }

  override delete(id: string): boolean {
    this.order.delete(id);
    this.local.delete(id);
    return super.delete(id);
  }

  override clear(): void {
    this.order.clear();
    this.local.clear();
    this.latest = 0;
    super.clear();
  }

  /// Drops every row but those `keep` accepts; the event order starts over (a lag rebuild
  /// replays the events), and the rows kept go after the replayed events (``placeLocalLast()``).
  retain(keep: (row: AcpmuxRow) => boolean): void {
    // A Map visits the entries left after a delete, so deleting while iterating is safe.
    for (const row of this.values()) if (!keep(row)) this.delete(row.id);
    this.latest = 0;
  }

  /// Moves the rows made without an event after every event, keeping their order: what a lag
  /// rebuild replayed happened before them.
  placeLocalLast(): void {
    const local = [...this.local].sort((a, b) => (this.order.get(a) ?? 0) - (this.order.get(b) ?? 0));
    local.forEach((id, index) => this.order.set(id, this.latest + 0.5 + (index + 1) * 1e-6));
  }

  /// The rows in event order (wall-clock time breaks a tie).
  sorted(): AcpmuxRow[] {
    return [...this.values()].sort((a, b) => (this.order.get(a.id) ?? 0) - (this.order.get(b.id) ?? 0) || a.at - b.at);
  }
}

/** Direct browser client for the authenticated acpmux WebSocket protocol. */
export class AcpmuxDirectClient {
  /// Coalesces the snapshots of acpmux events that land within one display frame: a fast stream
  /// sends several deltas per frame, and each snapshot re-renders the transcript. The page that
  /// draws the transcript sets it (main.tsx: ``nextFrame``); unset, each event snapshots at once.
  static scheduleFrame: ((run: () => void) => void) | undefined;
  /// The connection state of the snapshot waiting for the next frame.
  private frameSnapshot?: string;
  private socket?: WebSocket;
  private nextRequest = 1;
  private pending = new Map<
    number,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
      timer?: ReturnType<typeof setTimeout>;
    }
  >();
  private events: EventRecord[] = [];
  private rows = new OrderedRows();
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
  /// A prompt that was not sent, by its row: what Retry sends again.
  private failedPrompts = new Map<string, { input: string; attachments: ComposerAttachment[] }>();
  private firstSeq?: number;
  private lastSeq = 0;
  private turnOpen = false;
  /// acpmux lists `acp.session.fork` among the operations it serves.
  private canFork = false;
  private handoffSupported = false;
  /// The `_acpmux/*` methods acpmux's `initialize` lists (`_meta.acpmux.extensions`).
  private extensions: readonly string[] = [];
  /// acpmux calls this connection local (`_meta.acpmux.origin: "local"`). Without that, a
  /// WebSocket connection is remote-origin to acpmux, which never pools for it.
  private localOrigin = false;
  /// The origin acpmux names for this connection; `unknown` until (or unless) it names one.
  private origin: NonNullable<AcpmuxSnapshot["origin"]> = "unknown";
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
  private peers: string[] = [];
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
    // Over the bridge the URL names nothing: the host knows its daemon.
    const url = new URL(this.host.endpoint ?? BRIDGE_URL);
    if (this.host.token) url.searchParams.set("token", this.host.token);
    this.wire.lifecycle("connecting", {
      endpoint: this.host.endpoint ? redactEndpoint(this.host.endpoint) : BRIDGE_URL,
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
        reject(new Error(translate("error.connectFailed")));
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
          reject(new Error(translate("error.closedBeforeConnect")));
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
      const extensions = initialized?._meta?.acpmux?.extensions;
      this.extensions = Array.isArray(extensions) ? extensions.map(String) : [];
      this.localOrigin = initialized?._meta?.acpmux?.origin === "local";
      const origin = initialized?._meta?.acpmux?.origin;
      this.origin = origin === "local" || origin === "remote" || origin === "peer" ? origin : "unknown";
      this.handoffSupported = supportsHandoff(initialized);
      const groupedPermissionsSupported = supportsPermissionGroups(initialized);
      if (!groupedPermissionsSupported) this.groupedPermissions.clear();
      this.permissions.configure(groupedPermissionsSupported);
      const status = await this.request("_acpmux/status", {}).catch(() => undefined);
      this.peers = Array.isArray(status?.peers)
        ? status.peers
            .map((peer: any) => (typeof peer?.name === "string" ? peer.name : undefined))
            .filter((peer: string | undefined): peer is string => Boolean(peer))
        : [];
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
      this.wire.lifecycle("connected", {
        sessionId: this.selectedSessionId,
        sessions: this.sessions.length,
      });
      this.emit("connected");
    } catch (error) {
      this.wire.lifecycle("connect failed", {
        message: error instanceof Error ? error.message : String(error),
      });
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
    this.failedPrompts.clear();
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
      const result = await this.request("_acpmux/events", {
        sessionId,
        afterSeq: cursor,
        limit: 5_000,
      });
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
    if (!cwd) return Promise.reject(new Error(translate("error.noFolderSearch")));
    if (hostKind(summary?.hostKind) === "cloud" || entry?.hostKind === "cloud")
      return Promise.reject(new Error(translate("error.remoteSearch")));
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

  /// acpmux serves no git methods: the native host runs them on the session host in the selected
  /// session's folder, and mock mode's in-page daemon answers them by session.
  /// One turn's repository changes: checkpoint `from` against checkpoint `to`.
  gitCheckpointDiff(from: string, to: string): Promise<unknown> {
    return this.git("git.checkpoint.diff", { from, to, include_patch: true });
  }

  private git(
    method: "git.diff" | "git.status" | "git.checkpoint.diff",
    params: Record<string, unknown>,
  ): Promise<unknown> {
    const sessionId = this.selectedSessionId;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const entry = this.sessions.find((session) => session.sessionId === sessionId);
    const cwd = text(summary?.cwd) ?? text(entry?.cwd);
    if (!sessionId || !cwd) return Promise.reject(new Error(translate("error.noFolderChanges")));
    // The native host reads folders on this Mac; a cloud session's folder is on its machine.
    if (hostKind(summary?.hostKind) === "cloud" || entry?.hostKind === "cloud")
      return Promise.reject(new Error(translate("error.remoteChanges")));
    return this.gitRoute === "daemon"
      ? this.request(method, { sessionId, cwd, ...params })
      : postNative(method, { cwd, ...params });
  }

  private request(method: string, params: Record<string, unknown>, deadline?: number): Promise<any> {
    if (this.socket?.readyState !== WebSocket.OPEN)
      return Promise.reject(
        Object.assign(new Error(translate("error.notOpen")), {
          code: "native.not_connected",
          origin: "native",
        }),
      );
    const id = this.nextRequest++;
    return new Promise((resolve, reject) => {
      const timer = deadline
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(
              Object.assign(new Error(translate("error.timedOut")), {
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
    this.emitInFrame(event.kind);
  }

  /// Snapshots before the next display frame, once for every event that lands before it.
  private emitInFrame(connection: string): void {
    const schedule = AcpmuxDirectClient.scheduleFrame;
    if (!schedule) return this.emit(connection);
    const scheduled = this.frameSnapshot !== undefined;
    this.frameSnapshot = connection;
    if (scheduled) return;
    schedule(() => {
      const pending = this.frameSnapshot;
      if (pending !== undefined && !this.closed) this.emit(pending);
    });
  }

  private rebuild(): void {
    // A prompt still in flight keeps its optimistic row until an event settles it; a failed one stays to show it was not sent.
    const inFlight = new Set(this.optimisticPromptRows.values());
    // Those rows keep their place in the order.
    this.rows.retain((row) => row.failed === true || inFlight.has(row.id));
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
    // Rows kept from before (a prompt that failed or still sends) are newer than every replayed event.
    this.rows.placeLocalLast();
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
    this.rows.current = event.seq;
    try {
      this.reduceEvent(event);
    } finally {
      this.rows.current = undefined;
      if (event.seq) this.rows.saw(event.seq);
    }
  }

  private reduceEvent(event: EventRecord): void {
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
        settleOptimisticPrompt(this.rows, this.optimisticPromptRows, {
          ...msg,
          promptId: fallbackPromptId,
        });
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
        const checkpoint = event.kind === "turn_result" ? readSummaryCheckpoint(msg) : undefined;
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
        items: appendThought(existing?.items ?? [], text),
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
      const item = mergeToolItem(itemIndex >= 0 ? items[itemIndex] : undefined, update, callId, text, event.at);
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
    const rows = this.rows.sorted().filter((row) => !row.pending && !row.failed);
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
    // This snapshot carries every event so far, so a snapshot waiting for the frame has nothing left.
    this.frameSnapshot = undefined;
    const summary = this.summary;
    const effort = (summary?.configOptions ?? []).find(
      (option: any) => option.category === "thought_level" || option.id === "reasoning_effort",
    );
    this.listener({
      type: "snapshot",
      protocolVersion: 1,
      rows: this.rows.sorted(),
      sessions: this.sessions.map((session) => {
        let entry = this.sessionEntries.get(session);
        if (!entry) {
          entry = sessionEntry(session);
          this.sessionEntries.set(session, entry);
        }
        return entry;
      }),
      peers: this.peers,
      summary: summary
        ? {
            sessionId: summary.sessionId,
            cwd: summary.cwd,
            turnCount: summary.turnCount,
            usage: this.usage,
            host: text(summary.host),
            peer: text(summary.peer),
            hostKind: hostKind(summary.hostKind),
            branch: text(summary.branch),
            worktree: text(summary.worktree),
            title: summary.title,
            name: summary.name,
            harness: summary.harness,
            family: typeof summary.family === "string" ? summary.family : undefined,
            model: summary.model,
            effort: effort?.currentValue,
            promptCapabilities: summary.agentCapabilities?.promptCapabilities,
            status: summary.status,
            enforcement: sessionEnforcement(summary.enforcement),
            modes: summary.modes,
            configOptions: summary.configOptions,
          }
        : undefined,
      connection,
      origin: this.origin,
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
  /** A new chat starting (`create`): a Send meanwhile waits for it and goes to the new chat, not to
   *  the session still on screen (a harness pick), and a Send with no session joins it. */
  private creating?: Promise<string | undefined>;
  async ensureSession(): Promise<string | undefined> {
    // A failed start leaves the selection as it was; the prompt then goes where the pane is.
    if (this.creating) await this.creating.catch(() => undefined);
    if (!this.selectedSessionId) await this.create();
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
  /// Sends a prompt. `promptId` keys its optimistic row (`local-<promptId>`), so a prompt the
  /// pane drew while a harness started keeps its row once it goes out (harnessSwitch.ts).
  async send(
    input: string,
    attachments: ComposerAttachment[] = [],
    promptId: string = crypto.randomUUID(),
  ): Promise<string | undefined> {
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
      throw new Error(translate("error.reviewContinuation"));
    // A shown session takes the prompt in this task, so its row draws in the frame of the send;
    // while a new chat starts, the prompt waits for it (ensureSession).
    const shown = this.creating ? undefined : this.selectedSessionId;
    const sessionId = shown ?? (await this.ensureSession());
    if (!sessionId) return undefined;
    const text = promptText(input, attachments);
    const rowId = `local-${promptId}`;
    const at = Date.now();
    this.optimisticPromptRows.set(promptId, rowId);
    this.optimisticPromptTexts.set(promptId, text);
    this.rows.set(rowId, { id: rowId, version: 1, at, kind: "user", text, pending: true });
    this.emit();
    try {
      await this.request("session/prompt", {
        sessionId,
        prompt: promptBlocks(input, attachments),
        _meta: { acpmux: { promptId } },
      });
    } catch (error) {
      const code = (error as { code?: unknown } | null)?.code;
      const refused = typeof code === "string" && code.startsWith("transport.");
      const row = this.rows.get(rowId);
      if (row) {
        // A new row object: the transcript's rows are memoized on identity and version. The
        // bubble says why it got no reply; a refusal for want of a gesture asks for Retry.
        this.rows.set(rowId, {
          ...row,
          pending: false,
          failed: true,
          error:
            code === "transport.gesture_required"
              ? translate("prompt.notSentGesture")
              : translate("prompt.notSent", { reason: errorMessage(error) }),
          version: row.version + 1,
        });
        this.failedPrompts.set(rowId, { input, attachments });
      }
      this.optimisticPromptRows.delete(promptId);
      this.optimisticPromptTexts.delete(promptId);
      // The host refused one frame and answered it: the connection is as it was.
      this.emit(refused ? undefined : "failed");
      throw error;
    }
    return sessionId;
  }

  /// Retry on a prompt that was not sent: its bubble goes and the same prompt is sent again.
  async retryPrompt(rowId: string): Promise<string | undefined> {
    const failed = this.failedPrompts.get(rowId);
    if (!failed) return undefined;
    this.failedPrompts.delete(rowId);
    this.rows.delete(rowId);
    this.emit();
    return this.send(failed.input, failed.attachments);
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
      await this.request("_acpmux/permission_respond", {
        sessionId: this.selectedSessionId,
        permissionId,
        optionId,
      });
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
  create(harness?: string, cwd?: string, peer?: string): Promise<string | undefined> {
    const started = (async () => {
      const sessionId = await this.startSession(harness, cwd, peer);
      return sessionId ? this.select(sessionId) : undefined;
    })();
    const tracked = started.finally(() => {
      if (this.creating === tracked) this.creating = undefined;
    });
    // A rejection is the caller's to handle; the tracked copy only orders sends behind it.
    tracked.catch(() => undefined);
    this.creating = tracked;
    return started;
  }
  /// `session/new` without showing it: a harness switch starts the session behind the pane's
  /// new chat and shows it once it is ready (harnessSwitch.ts).
  async startSession(harness?: string, cwd?: string, peer?: string): Promise<string | undefined> {
    const result = await this.request(
      "session/new",
      newSessionParams(cwd ? { cwd, peer } : { ...this.host, peer }, harness),
    );
    // The inherited cwd is the first default chat's; later ones start where acpmux defaults.
    if (result?.sessionId && !cwd) this.host = { ...this.host, cwd: undefined };
    return result?.sessionId ? String(result.sessionId) : undefined;
  }
  /// The shown session, for a harness switch: whether it has nothing in it yet (a pick back to
  /// its harness reuses it), its harness, and its folder when it runs on this machine (the new
  /// chat starts there; a cloud or peer session's folder is not one acpmux can start in here).
  shownSession(): { sessionId: string; harness?: string; empty: boolean; cwd?: string } | undefined {
    const sessionId = this.selectedSessionId;
    if (!sessionId) return undefined;
    const summary = this.summary?.sessionId === sessionId ? this.summary : undefined;
    const turns = Number(summary?.turnCount ?? 0);
    const local = hostKind(summary?.hostKind) !== "cloud" && !text(summary?.host);
    return {
      sessionId,
      harness: typeof summary?.harness === "string" ? summary.harness : undefined,
      empty: this.rows.size === 0 && this.queue.length === 0 && turns === 0 && !this.turnOpen,
      ...(local && typeof summary?.cwd === "string" && summary.cwd ? { cwd: summary.cwd } : {}),
    };
  }
  /// A turn is running in the shown session.
  turnRunning(): boolean {
    return this.turnOpen || this.summary?.status === "running";
  }
  /// Stops showing the selected session: a harness switch draws its new chat meanwhile. The
  /// session keeps running in acpmux; only this client's attach ends.
  leave(): void {
    const previous = this.selectedSessionId;
    if (!previous) return;
    this.selectedSessionId = undefined;
    this.selectionGeneration += 1;
    this.resetSessionState();
    this.emit();
    void this.request("_acpmux/detach", { sessionId: previous }).catch(() => undefined);
  }
  /// Ends a session a superseded harness switch started and nobody used.
  discard(sessionId: string): void {
    if (sessionId === this.selectedSessionId) return;
    void this.request("_acpmux/kill", { sessionId, purge: true }).catch(() => undefined);
  }
  /// acpmux serves `_acpmux/prewarm` to this connection: it lists the method and calls the
  /// connection local. A remote-origin connection is never asked (acpmux refuses it).
  get prewarmSupported(): boolean {
    return this.localOrigin && this.extensions.includes(PREWARM_METHOD);
  }
  /// Hints acpmux's session pool that `harness` is likely next, in `cwd` when known. Never
  /// awaited; a refusal (the pool is off, a failed start) is ignored.
  prewarm(harness: string, cwd?: string): void {
    if (!this.prewarmSupported) return;
    void this.request(PREWARM_METHOD, cwd ? { harness, cwd } : { harness }).catch(() => undefined);
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
  /// A line in the shown transcript (a pick the agent refused).
  notice(text: string): void {
    const at = Date.now();
    const id = noticeId("notice");
    this.rows.set(id, { id, version: 1, at, kind: "notice", text });
    this.emit();
  }
  private adoptFailed(reason: string): void {
    const at = Date.now();
    const id = noticeId("notice-adopt");
    this.rows.set(id, {
      id,
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
        const id = noticeId("notice-fork");
        this.rows.set(id, {
          id,
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
  /// Forks the open session through `throughSeq` and stays on it: New side chat's copy, which the
  /// host opens beside this chat. One fork at a time, as `fork`.
  async forkAside(throughSeq: number): Promise<string | undefined> {
    if (!this.canFork || !this.selectedSessionId || this.forking) return undefined;
    this.forking = true;
    try {
      const result = await this.request(FORK_OP, { sessionId: this.selectedSessionId, throughSeq });
      return result?.sessionId ? String(result.sessionId) : undefined;
    } finally {
      this.forking = false;
    }
  }
  async setModel(modelId: string): Promise<void> {
    if (this.selectedSessionId) await this.request("session/set_model", { sessionId: this.selectedSessionId, modelId });
  }
  /// `ticket`: a gesture ticket a held pick took (pane-native transport, `transport.gesture`); it
  /// rides as `_meta.cmuxGesture`, and the host strips it before acpmux.
  async setMode(modeId: string, ticket?: string): Promise<void> {
    if (this.selectedSessionId)
      await this.request("session/set_mode", { sessionId: this.selectedSessionId, modeId, ...gestureMeta(ticket) });
  }
  async setConfig(configId: string, value: string, ticket?: string): Promise<void> {
    if (this.selectedSessionId)
      await this.request("session/set_config_option", {
        sessionId: this.selectedSessionId,
        configId,
        value,
        ...gestureMeta(ticket),
      });
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
        Object.assign(new Error(translate("error.interrupted")), {
          code: "native.timed_out",
          origin: "native",
        }),
      );
    }
    this.pending.clear();
  }
}

/// The params field that carries a pick's gesture ticket, or nothing without one.
const gestureMeta = (ticket?: string) => (ticket ? { _meta: { cmuxGesture: ticket } } : {});

/// Why acpmux says a harness will not start: its launcher check, else its failed model probe.
export function harnessRefusal(entry: { unavailable?: unknown; probeError?: unknown } | undefined): string | undefined {
  for (const reason of [entry?.unavailable, entry?.probeError]) if (typeof reason === "string" && reason) return reason;
  return undefined;
}

export function normalizeCatalog(value: any): AcpmuxSnapshot["catalog"] {
  const harnesses = value?.harnesses ?? value?.items ?? value ?? [];
  return (
    Array.isArray(harnesses) ? harnesses : Object.entries(harnesses).map(([id, data]) => ({ id, ...(data as any) }))
  ).map((harness: any) => ({
    id: String(harness.id ?? harness.name),
    name: agentName(String(harness.id ?? harness.name), harness.name == null ? undefined : String(harness.name)),
    models: (harness.models ?? []).map((model: any) => ({
      id: String(model.id ?? model.modelId),
      name: model.name,
    })),
    // Why acpmux will not start it, when it says: its launcher check (`unavailable`), else its
    // failed model probe (`probeError`).
    ...(harnessRefusal(harness) ? { unavailable: harnessRefusal(harness) } : {}),
  }));
}
