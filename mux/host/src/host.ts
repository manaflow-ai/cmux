import {
  type AcpmuxEvent,
  AcpmuxClient,
  type McpServer,
  type Notification,
  type SessionStatus,
  type SessionSummary,
  eventFromUpdate,
} from "./acpmux-client.ts";
import {
  AGENT_MUX,
  type ConversationChangedEvent,
  type Message,
  messageText,
  type Op,
  type Part,
  type Participant,
  type Summary,
  USER_LOCAL,
} from "./conversation-types.ts";
import { DaemonClient, DaemonError, MissingCapabilityError } from "./daemon-client.ts";
import { takeLock } from "./lock.ts";
import type { MuxPaths } from "./paths.ts";
import { writeSessionDir } from "./session-dir.ts";
import { type ChildRecord, HostState, type OutboxEntry } from "./state.ts";
import {
  childFinishedPrompt,
  childPermissionPrompt,
  excerpt,
  PARENT_TAG,
  turnEnded,
  workStatus,
} from "./supervisor.ts";
import { lastReply, type Turn, TurnFolder, type TurnOutput } from "./turns.ts";
import { wakes } from "./wake.ts";

// The local mux brain host (plans/cmux-next/home.md section 4). A client of
// two owners, listening on nothing:
//   - the cmux daemon's local conversation owner (conversation-* commands and
//     conversation-changed events), and
//   - acpmux, which owns the mux session `mux` and its child agents.
// Every effect is keyed so an owner dedupes a replay: prompts carry promptId =
// the message id (acpmux), replies carry client_msg_id = "turn:<session>:<turn
// seq>" (conversation owner). The host's durable to-dos live in HostState.

export const DEFAULT_CONVERSATION_KEY = "mux-home-default";
export const MUX_SESSION_NAME = "mux";

export interface HostOptions {
  daemonSocket: string;
  acpmuxSocket: string;
  paths: MuxPaths;
  /** The mux's acpmux harness (MUX_HARNESS, default claude-sr). */
  harness: string;
  policy: string;
  /** The Mac user's display name (user_local). */
  displayName: string;
  /** The command that runs this CLI: hooks and the `mux` launcher call it. */
  self: string[];
  /** Env baked into the mux's hooks and tools (MUX_HOME, ACPMUX_SOCKET, ...). */
  sessionEnv: Record<string, string>;
  mcpServers: McpServer[];
  log?: (line: string) => void;
  /** Reconnect backoff after a failed or lost connection. */
  backoff?: { initialMs: number; maxMs: number };
}

type Queue = { run(task: () => Promise<void>): Promise<void> };

/** Tasks run one at a time, in order; a failed task is logged and the queue continues. */
function serialQueue(log: (line: string) => void): Queue {
  let tail = Promise.resolve();
  return {
    run(task) {
      const next = tail.then(task).catch((error) => log(`task failed: ${String(error)}`));
      tail = next;
      return next;
    },
  };
}

export class HostAlreadyRunningError extends Error {}

export class MuxHost {
  private readonly state: HostState;
  private readonly log: (line: string) => void;
  private readonly inbox: Queue;
  private readonly effects: Queue;
  private releaseLock?: () => void;
  private stopped = false;
  private readonly stoppedSignal: Promise<void>;
  private signalStop!: () => void;

  private daemon?: DaemonClient;
  private acpmux?: AcpmuxClient;
  private muxSessionId?: string;
  private folder = new TurnFolder();

  /** Conversation summaries the host has seen (refreshed on each daemon connect). */
  private readonly summaries = new Map<string, Summary>();
  /** Highest message seq the inbox handled per conversation (>= the agent_mux read cursor). */
  private readonly handled = new Map<string, number>();
  /** Message id -> author, for the reply-to-mux wake rule. */
  private readonly authors = new Map<string, string>();
  /** promptId -> resolvers waiting for acpmux to accept it. */
  private readonly acceptWaiters = new Map<string, () => void>();
  /** Conversation where the mux is typing (its running turn's). */
  private typingIn?: string;
  /** Every acpmux session's last status and, for running children, the seq their turn started after. */
  private readonly sessionStatus = new Map<string, SessionStatus>();
  private readonly sessionInfo = new Map<string, SessionSummary>();
  /** Per child: the event seq when its previous turn ended (its next turn's events come after it). */
  private readonly childTurnFloor = new Map<string, number>();

  private readyResolve!: () => void;
  /** Resolves once both owners are connected and the first catch-up ran. */
  readonly ready: Promise<void>;
  private fail!: (error: Error) => void;
  /** Rejects when the host cannot run at all (the daemon lacks local conversations). */
  readonly fatal: Promise<never>;

  constructor(private readonly options: HostOptions) {
    this.log = options.log ?? ((line) => console.error(`${new Date().toISOString()} mux host: ${line}`));
    this.state = new HostState(options.paths.hostState);
    this.inbox = serialQueue(this.log);
    this.effects = serialQueue(this.log);
    this.ready = new Promise((resolve) => (this.readyResolve = resolve));
    this.stoppedSignal = new Promise((resolve) => (this.signalStop = resolve));
    this.fatal = new Promise<never>((_, reject) => (this.fail = reject));
    this.fatal.catch(() => {});
  }

  /** Resolves when stop() ran. */
  get stoppedPromise(): Promise<void> {
    return this.stoppedSignal;
  }

  /** Takes the MUX_HOME lock, writes the session dir, and starts both connection loops. */
  start(): void {
    const release = takeLock(this.options.paths.hostLock);
    if (!release) throw new HostAlreadyRunningError(`another mux host holds ${this.options.paths.hostLock}`);
    this.releaseLock = release;
    writeSessionDir(this.options.paths, this.options.self, this.options.sessionEnv, {
      mcp: this.options.mcpServers.length > 0,
    });
    void this.loop("daemon", () => this.runDaemon());
    void this.loop("acpmux", () => this.runAcpmux());
  }


  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.signalStop();
    this.daemon?.close();
    this.acpmux?.close();
    this.releaseLock?.();
  }

  /** Runs one connection until it ends; reconnects with backoff only after a failure or loss. */
  private async loop(name: string, run: () => Promise<void>): Promise<void> {
    const { initialMs, maxMs } = this.options.backoff ?? { initialMs: 500, maxMs: 30_000 };
    let delay = initialMs;
    while (!this.stopped) {
      const startedAt = Date.now();
      try {
        await run();
        this.log(`${name} connection closed`);
      } catch (error) {
        if (error instanceof MissingCapabilityError) {
          this.log(String(error.message));
          await this.stop();
          this.fail(error);
          return;
        }
        this.log(`${name}: ${String(error)}`);
      }
      if (this.stopped) return;
      // A connection that lived a while resets the backoff.
      if (Date.now() - startedAt > maxMs) delay = initialMs;
      await Promise.race([new Promise((resolve) => setTimeout(resolve, delay)), this.stoppedSignal]);
      delay = Math.min(delay * 2, maxMs);
    }
  }

  // MARK: daemon

  private async runDaemon(): Promise<void> {
    const daemon = await DaemonClient.connect(this.options.daemonSocket, {
      subscribe: true,
      onEvent: (event) => this.onDaemonEvent(daemon, event),
    });
    const closed = new Promise<void>((resolve) => daemon.onClose(() => resolve()));
    this.summaries.clear();
    try {
      const { conversation } = await daemon.create({
        idempotency_key: DEFAULT_CONVERSATION_KEY,
        actor: USER_LOCAL,
        title: "mux",
        participants: this.defaultParticipants(),
      });
      this.remember(conversation);
      if (this.state.data.defaultConversation !== conversation.id) {
        this.state.data.defaultConversation = conversation.id;
        this.state.save();
      }
      this.daemon = daemon;
      this.log(`daemon connected (${daemon.identity.app ?? "?"} ${daemon.identity.version ?? ""}); conversation ${conversation.id}`);
      await this.effects.run(() => this.flushOutbox());
      if (this.acpmux) await this.inbox.run(() => this.catchUp());
    } catch (error) {
      daemon.close();
      throw error;
    }
    await Promise.race([closed, this.stoppedSignal]);
    if (this.daemon === daemon) this.daemon = undefined;
  }

  private defaultParticipants(): Participant[] {
    return [
      { id: USER_LOCAL, kind: "human", display_name: this.options.displayName },
      { id: AGENT_MUX, kind: "agent", display_name: "mux", agent_class: "mux", acp_session: MUX_SESSION_NAME },
    ];
  }

  private onDaemonEvent(daemon: DaemonClient, event: Record<string, unknown>): void {
    if (event.event === "overflow") {
      // The subscription fell behind: drop it; the reconnect catches up from the read cursors.
      this.log("daemon subscription overflow; resubscribing");
      daemon.close();
      return;
    }
    if (event.event !== "conversation-changed") return;
    const changed = event as unknown as ConversationChangedEvent;
    const change = changed.change;
    if (change.kind === "conversation") {
      this.remember(change.conversation);
      return;
    }
    if (change.kind === "read-cursor") {
      const summary = this.summaries.get(changed.conversation);
      if (summary) summary.read_cursors[change.participant] = Math.max(summary.read_cursors[change.participant] ?? 0, change.seq);
      return;
    }
    if (change.kind === "message") {
      this.authors.set(change.message.id, change.message.author);
      const message = change.message;
      void this.inbox.run(() => this.onMessage(message));
    }
  }

  private remember(summary: Summary): void {
    this.summaries.set(summary.id, summary);
    if (!this.handled.has(summary.id)) this.handled.set(summary.id, summary.read_cursors[AGENT_MUX] ?? 0);
    if (summary.last_message) this.authors.set(summary.last_message.id, summary.last_message.author);
  }

  private async summary(conversation: string): Promise<Summary | undefined> {
    const cached = this.summaries.get(conversation);
    if (cached) return cached;
    const daemon = this.daemon;
    if (!daemon) return undefined;
    const { conversation: summary } = await daemon.snapshot(conversation, 1);
    this.remember(summary);
    return summary;
  }

  // MARK: inbox

  /** A live message: handle it in seq order, or catch the conversation up when the host missed some. */
  private async onMessage(message: Message): Promise<void> {
    if (!this.daemon || !this.acpmux) return; // The catch-up after both connect covers it.
    const summary = await this.summary(message.conversation);
    if (!summary || !summary.participants.some((p) => p.id === AGENT_MUX)) return;
    const handled = this.handled.get(summary.id) ?? 0;
    if (message.seq <= handled) return;
    if (message.seq > handled + 1) return this.catchUpConversation(summary);
    summary.last_seq = Math.max(summary.last_seq, message.seq);
    await this.handleMessage(summary, message);
  }

  /** Every conversation with the mux, from its agent_mux read cursor. */
  private async catchUp(): Promise<void> {
    const daemon = this.daemon;
    if (!daemon || !this.acpmux) return;
    for (const summary of await daemon.list()) {
      this.remember(summary);
      if (summary.participants.some((p) => p.id === AGENT_MUX)) await this.catchUpConversation(summary);
    }
    this.readyResolve();
  }

  private async catchUpConversation(known: Summary): Promise<void> {
    const daemon = this.daemon;
    if (!daemon) return;
    const { conversation: summary, messages } = await daemon.snapshot(known.id, 500);
    this.summaries.set(summary.id, summary);
    const from = Math.max(this.handled.get(summary.id) ?? 0, summary.read_cursors[AGENT_MUX] ?? 0);
    this.handled.set(summary.id, from);
    let pending = messages.filter((m) => m.seq > from);
    // Page back until the first missing message is in hand.
    while (pending.length > 0 && pending[0].seq > from + 1) {
      const older = await daemon.history(summary.id, pending[0].seq, 500);
      if (older.length === 0) break;
      pending = [...older.filter((m) => m.seq > from), ...pending];
    }
    for (const message of messages) this.authors.set(message.id, message.author);
    for (const message of pending) {
      this.authors.set(message.id, message.author);
      await this.handleMessage(summary, message);
    }
  }

  /** Prompts the mux when the message wakes it, then moves agent_mux's read cursor past it. */
  private async handleMessage(summary: Summary, message: Message): Promise<void> {
    if (message.seq <= (this.handled.get(summary.id) ?? 0)) return;
    if (!this.state.isAnswered(message.id) && wakes(summary, message, (id) => this.authors.get(id) === AGENT_MUX)) {
      const author = summary.participants.find((p) => p.id === message.author);
      const text = `[conversation ${summary.id} from ${author?.display_name ?? message.author}] ${messageText(message)}`;
      this.state.data.prompts[message.id] = { conversation: summary.id, text, seq: message.seq };
      this.state.save();
      await this.sendPrompt(message.id, { awaitAccepted: true });
    }
    this.handled.set(summary.id, message.seq);
    await this.setReadCursor(summary, message.seq);
  }

  private async setReadCursor(summary: Summary, seq: number): Promise<void> {
    const daemon = this.daemon;
    if (!daemon || seq <= (summary.read_cursors[AGENT_MUX] ?? 0)) return;
    try {
      await daemon.op({
        conversation: summary.id,
        idempotency_key: `cursor:${AGENT_MUX}:${seq}`,
        actor: AGENT_MUX,
        op: { kind: "read_cursor.set", seq },
      });
      summary.read_cursors[AGENT_MUX] = seq;
    } catch (error) {
      if (error instanceof DaemonError && error.message.includes("cursor_regression")) return;
      throw error;
    }
  }

  /**
   * Sends an outstanding prompt (state.prompts) to the mux as its own turn.
   * With `awaitAccepted`, settles once acpmux recorded it (user_message or
   * queued) or answered the request (a promptId it already had).
   */
  private async sendPrompt(promptId: string, options: { awaitAccepted: boolean }): Promise<void> {
    const entry = this.state.data.prompts[promptId];
    const acpmux = this.acpmux;
    const session = this.muxSessionId;
    if (!entry || !acpmux || !session) return;
    let accepted: Promise<void> = Promise.resolve();
    if (options.awaitAccepted) accepted = new Promise((resolve) => this.acceptWaiters.set(promptId, resolve));
    acpmux
      .prompt(session, entry.text, { promptId, delivery: "turn" })
      .catch((error) => this.log(`prompt ${promptId} failed: ${String(error)}; resent on the next acpmux connect`))
      .finally(() => this.accept(promptId));
    await accepted;
  }

  private accept(promptId: string): void {
    const resolve = this.acceptWaiters.get(promptId);
    if (!resolve) return;
    this.acceptWaiters.delete(promptId);
    resolve();
  }

  // MARK: acpmux

  private async runAcpmux(): Promise<void> {
    const acpmux = await AcpmuxClient.connect(this.options.acpmuxSocket, "mux-host");
    const closed = new Promise<void>((resolve) => acpmux.onClose(() => resolve()));
    try {
      const sessionId = await this.ensureMuxSession(acpmux);
      if (this.state.data.muxSessionId !== sessionId) {
        this.state.data.muxSessionId = sessionId;
        this.state.data.acpmuxSeq = 0;
        this.state.save();
      }
      this.muxSessionId = sessionId;
      // Notifications that arrive while attach replays are held, then applied after it.
      let held: Notification[] | undefined = [];
      acpmux.onNotification((n) => {
        if (held) held.push(n);
        else this.onAcpmuxNotification(n);
      });
      for (const session of await acpmux.sessions()) {
        this.sessionStatus.set(session.sessionId, session.status);
        this.sessionInfo.set(session.sessionId, session);
      }
      await acpmux.watch(true);
      const attached = await this.attach(acpmux, sessionId);
      this.folder = new TurnFolder(this.state.data.acpmuxSeq);
      for (const event of attached) this.applyMuxEvent(event);
      const queued = held;
      held = undefined;
      for (const n of queued) this.onAcpmuxNotification(n);
      this.acpmux = acpmux;
      this.log(`acpmux connected; mux session ${sessionId} (${attached.length} events replayed)`);
      // Prompts acpmux may have dropped with an old connection; it dedupes the rest by promptId.
      for (const promptId of Object.keys(this.state.data.prompts)) await this.sendPrompt(promptId, { awaitAccepted: false });
      await this.effects.run(() => this.reconcileChildren());
      if (this.daemon) await this.inbox.run(() => this.catchUp());
    } catch (error) {
      acpmux.close();
      throw error;
    }
    await Promise.race([closed, this.stoppedSignal]);
    if (this.acpmux === acpmux) this.acpmux = undefined;
    for (const promptId of [...this.acceptWaiters.keys()]) this.accept(promptId);
    if (this.typingIn) void this.setTyping(this.typingIn, false);
  }

  private async attach(acpmux: AcpmuxClient, sessionId: string): Promise<AcpmuxEvent[]> {
    try {
      return (await acpmux.attach(sessionId, this.state.data.acpmuxSeq)).events;
    } catch (error) {
      // The log is shorter than the saved cursor (a re-imported session): replay it all; the owner dedupes replies.
      if (!String(error).includes("cursor_future")) throw error;
      this.state.data.acpmuxSeq = 0;
      return (await acpmux.attach(sessionId, 0)).events;
    }
  }

  /** The `mux` acpmux session, created with the mux's cwd, harness and policy when missing. */
  private async ensureMuxSession(acpmux: AcpmuxClient): Promise<string> {
    const existing = (await acpmux.sessions()).find((s) => s.name === MUX_SESSION_NAME);
    if (existing) return existing.sessionId;
    const { sessionId } = await acpmux.newSession({
      cwd: this.options.paths.session,
      name: MUX_SESSION_NAME,
      harness: this.options.harness,
      policy: this.options.policy,
      mcpServers: this.options.mcpServers,
    });
    this.log(`created acpmux session ${MUX_SESSION_NAME} (${this.options.harness})`);
    return sessionId;
  }

  private onAcpmuxNotification(n: Notification): void {
    if (n.params.sessionId === this.muxSessionId) {
      if (n.method === "_acpmux/event") this.applyMuxEvent(n.params as unknown as AcpmuxEvent);
      else if (n.method === "session/update") this.applyMuxEvent(eventFromUpdate(n.params));
    }
    if (n.method === "_acpmux/session_changed") {
      const session = n.params.session as SessionSummary | undefined;
      if (session) void this.effects.run(() => this.onSessionChanged(session));
    } else if (n.method === "_acpmux/permission_pending") {
      const params = n.params as { sessionId: string; permissionId: string; request?: Record<string, unknown> };
      void this.effects.run(() => this.onPermission(params.sessionId, params.permissionId, params.request ?? {}));
    }
  }

  /** Folds one mux event; accepts resolve now, turn effects run in order on the effects queue. */
  private applyMuxEvent(event: AcpmuxEvent): void {
    for (const output of this.folder.apply(event)) {
      if (output.type === "accepted") this.accept(output.promptId);
      else void this.effects.run(() => this.onTurn(output));
    }
  }

  private conversationFor(promptId: string | undefined): string | undefined {
    return (promptId && this.state.data.prompts[promptId]?.conversation) || this.state.data.defaultConversation;
  }

  private async onTurn(output: Exclude<TurnOutput, { type: "accepted" }>): Promise<void> {
    const conversation = this.conversationFor(output.turn.promptId);
    if (output.type === "started") {
      if (conversation) await this.setTyping(conversation, true);
      return;
    }
    const text = output.turn.text.trim() || (output.error ? `(turn failed: ${output.error})` : "");
    if (conversation && text) {
      const key = turnKey(this.muxSessionId ?? "", output.turn);
      const parts: Part[] = [{ type: "text", text }];
      this.state.data.outbox.push({
        conversation,
        idempotency_key: key,
        op: { kind: "message.send", client_msg_id: key, parts },
      });
    }
    if (output.turn.promptId) this.state.markAnswered(output.turn.promptId);
    this.state.data.acpmuxSeq = Math.max(this.state.data.acpmuxSeq, output.seq);
    this.state.save();
    await this.flushOutbox();
    if (conversation) await this.setTyping(conversation, false);
  }

  private async setTyping(conversation: string, on: boolean): Promise<void> {
    this.typingIn = on ? conversation : undefined;
    try {
      await this.daemon?.typing(conversation, AGENT_MUX, on);
    } catch (error) {
      this.log(`typing ${on ? "on" : "off"} failed: ${String(error)}`);
    }
  }

  // MARK: outbox

  /** Sends queued conversation ops in order; stops at a connection failure, drops owner rejects. */
  private async flushOutbox(): Promise<void> {
    const daemon = this.daemon;
    if (!daemon) return;
    const outbox = this.state.data.outbox;
    while (outbox.length > 0) {
      const entry = outbox[0];
      const op = this.resolveOp(entry);
      if (op) {
        try {
          const result = await daemon.op({
            conversation: entry.conversation,
            idempotency_key: entry.idempotency_key,
            actor: AGENT_MUX,
            op,
          });
          if (entry.child && op.kind === "message.send" && result.change?.kind === "message") {
            const child = this.state.data.children[entry.child];
            if (child) child.messageId = result.change.message.id;
          }
        } catch (error) {
          if (!(error instanceof DaemonError)) return; // Connection lost: retried on the next connect.
          this.log(`dropping rejected op ${entry.idempotency_key}: ${error.message}`);
        }
      }
      outbox.shift();
      this.state.save();
    }
  }

  private resolveOp(entry: OutboxEntry): Op | undefined {
    if (!entry.child || entry.op.kind !== "message.edit") return entry.op;
    const messageId = this.state.data.children[entry.child]?.messageId;
    return messageId ? { ...entry.op, message_id: messageId } : undefined;
  }

  // MARK: children (sessions tagged mux.parent=mux)

  private isChild(session: SessionSummary): boolean {
    return session.tags?.[PARENT_TAG] === MUX_SESSION_NAME && session.sessionId !== this.muxSessionId;
  }

  private async onSessionChanged(session: SessionSummary): Promise<void> {
    const before = this.sessionStatus.get(session.sessionId);
    this.sessionStatus.set(session.sessionId, session.status);
    this.sessionInfo.set(session.sessionId, session);
    if (!this.isChild(session)) return;
    const child = this.state.data.children[session.sessionId] ?? this.registerChild(session);
    if (turnEnded(before, session.status)) await this.childFinished(session, child);
    else if (session.status === "running" && child.status !== "running") this.editWork(session, child, "running");
    else if ((session.status === "closed" || session.status === "disconnected") && child.status === "running")
      this.editWork(session, child, "failed");
    await this.flushOutbox();
  }

  /** A new child: a work-part message in the conversation the mux is answering. */
  private registerChild(session: SessionSummary): ChildRecord {
    const conversation = this.conversationFor(this.folder.running?.promptId) ?? "";
    const child: ChildRecord = { conversation, name: session.name, status: "running", edits: 0 };
    this.state.data.children[session.sessionId] = child;
    if (conversation) {
      const key = `work:${session.sessionId}`;
      this.state.data.outbox.push({
        conversation,
        idempotency_key: key,
        child: session.sessionId,
        op: { kind: "message.send", client_msg_id: key, parts: [workPart(session, "running", session.lastPrompt)] },
      });
    }
    this.state.save();
    this.log(`child ${session.name} started (${session.sessionId})`);
    return child;
  }

  private editWork(session: SessionSummary, child: ChildRecord, status: ChildRecord["status"], preview?: string): void {
    child.status = status;
    child.edits += 1;
    if (child.conversation)
      this.state.data.outbox.push({
        conversation: child.conversation,
        idempotency_key: `work:${session.sessionId}:${child.edits}`,
        child: session.sessionId,
        op: { kind: "message.edit", message_id: "", parts: [workPart(session, status, preview ?? session.preview)] },
      });
    this.state.save();
  }

  private async childFinished(session: SessionSummary, child: ChildRecord): Promise<void> {
    const acpmux = this.acpmux;
    let reply = "";
    if (acpmux) {
      const after = this.childTurnFloor.get(session.sessionId) ?? 0;
      reply = lastReply(await acpmux.events(session.sessionId, after).catch(() => [] as AcpmuxEvent[]));
    }
    this.childTurnFloor.set(session.sessionId, session.lastSeq ?? 0);
    this.editWork(session, child, workStatus(session.status), excerpt(reply, 200) || undefined);
    const promptId = `child:${session.sessionId}:${session.turnCount ?? session.stateSeq}`;
    this.state.data.prompts[promptId] = {
      conversation: child.conversation || (this.state.data.defaultConversation ?? ""),
      text: childFinishedPrompt(session, reply),
    };
    this.state.save();
    this.log(`child ${session.name} finished; telling the mux`);
    await this.sendPrompt(promptId, { awaitAccepted: false });
  }

  private async onPermission(sessionId: string, permissionId: string, request: Record<string, unknown>): Promise<void> {
    let session = this.sessionInfo.get(sessionId);
    if (!session?.tags?.[PARENT_TAG] && this.acpmux)
      session = (await this.acpmux.sessions()).find((s) => s.sessionId === sessionId);
    if (!session || !this.isChild(session)) return;
    const child = this.state.data.children[sessionId] ?? this.registerChild(session);
    this.editWork(session, child, "waiting");
    const promptId = `perm:${sessionId}:${permissionId}`;
    this.state.data.prompts[promptId] = {
      conversation: child.conversation || (this.state.data.defaultConversation ?? ""),
      text: childPermissionPrompt(session, request),
    };
    this.state.save();
    await this.flushOutbox();
    await this.sendPrompt(promptId, { awaitAccepted: false });
  }

  /** After a reconnect: children whose turn ended while the host was away. */
  private async reconcileChildren(): Promise<void> {
    for (const [sessionId, child] of Object.entries(this.state.data.children)) {
      const session = this.sessionInfo.get(sessionId);
      if (!session) {
        if (child.status === "running" || child.status === "waiting")
          this.editWork({ sessionId, name: child.name } as SessionSummary, child, "failed");
        continue;
      }
      if (child.status === "running" && (session.status === "ready" || session.status === "idle"))
        await this.childFinished(session, child);
    }
    await this.flushOutbox();
  }
}

/** The owner-side idempotency key (and client_msg_id) of a mux turn's reply. */
export function turnKey(sessionId: string, turn: Turn): string {
  return `turn:${sessionId}:${turn.turnSeq}`;
}

function workPart(session: SessionSummary, status: ChildRecord["status"], preview?: string | null): Part {
  return {
    type: "work",
    session: session.name,
    status,
    ...(preview ? { preview: excerpt(preview, 200) } : {}),
  };
}
