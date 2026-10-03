import { type AcpmuxEvent, isCount, lastReply, type SessionStatus, type SessionSummary, TurnFolder, validEvent } from "./acp.ts";
import { AGENT_MUX, type Change, type Message, type Op, type Summary, type WorkStatus } from "./conversation.ts";
import {
  AGENT_GAP_RETRY_MS,
  AGENT_GAP_TIMER_SLACK_MS,
  childFinishedPrompt,
  childPermissionPrompt,
  excerpt,
  inboxPrompt,
  MUX_SESSION_NAME,
  PAGE,
  PARENT_TAG,
  turnEnded,
  turnKey,
  wakes,
  workPart,
  workStatus,
} from "./rules.ts";
import { type ChildRecord, type HostStateData, isAnswered, loadState, markAnswered, plainState } from "./state.ts";
import { compareCodePoints as compare, plain } from "./text.ts";

// The sans-I/O brain host (plans/cmux-next/chief-mac.md section 3):
// `core.step(input, nowMs) -> effects`. The single behavior source for the
// Chief: mux/host is a thin I/O shell around it, the cloud MuxDO will be
// another, and the Rust port (cmux-chief core.rs) must pass the corpus that
// conformance/generate.ts writes from it.
//
// The shell does every read, write and timer the effects name and reports
// results back as inputs. When a step changed the durable state, its first
// effect is `persist`: the shell writes it before it runs the other effects
// (write-ahead), so a crash only replays keyed effects that an owner dedupes.
// Wire shapes are snake_case `kind` tags; the state is host.json (camelCase).
//
// Shell contract: a daemon read (list, snapshot, history) that the owner
// refuses is reported as `fetch_refused` (no reconnect); one that fails with
// the connection, or times out, is `disconnected {daemon}` (the shell drops
// that connection and connects again). A failed session list answers with
// `sessions {failed: true}`; failed child events answer with an empty
// `child_events`. A `*_connected` input while that port is up counts as a
// disconnect first: the core drops what it held for the old connection.

/** The timer key of the one-shot outbox retry. */
export const OUTBOX_TIMER = "outbox";

export type Port = "daemon" | "acpmux";

/** What the shell reports to the core. */
export type Input =
  /** The daemon port is up: the default conversation exists and writes are stamped agent_mux. */
  | { kind: "daemon_connected"; conversation: Summary }
  | { kind: "conversations_listed"; conversations: Summary[] }
  | { kind: "snapshot"; conversation: Summary; messages: Message[] }
  | { kind: "history"; conversation: string; messages: Message[] }
  /**
   * The owner refused a read (a reject with a reason, not a lost connection):
   * the list when `conversation` is absent, else that conversation's snapshot
   * or history page. The core skips that read; the shell does not reconnect.
   */
  | { kind: "fetch_refused"; conversation?: string; reason: string }
  | { kind: "conversation_changed"; conversation: string; change: Change }
  /** The owner answered a `conversation_op`: `reason` is set on a reject. */
  | { kind: "op_result"; idempotency_key: string; reason?: string; change?: Change }
  /**
   * The acpmux port is up: the mux session exists and `events` is the attach
   * replay. `cursor_reset`: acpmux refused the saved cursor (`cursor_future`,
   * a re-imported session), so the replay starts at 0.
   */
  | {
      kind: "acpmux_connected";
      session_id: string;
      sessions: SessionSummary[];
      events: AcpmuxEvent[];
      cursor_reset?: boolean;
      /** The log's identity: the `at` of its seq 1 event (absent for an empty log). */
      log_id?: number;
      /** The shell created the session on this connect: its log is new, nothing can reuse its keys. */
      created?: boolean;
    }
  | { kind: "acpmux_event"; event: AcpmuxEvent }
  | { kind: "session_changed"; session: SessionSummary }
  | { kind: "permission_pending"; session_id: string; permission_id: string; request: Record<string, unknown> }
  /**
   * The answer to `fetch_sessions`. `failed`: the request failed (sessions is
   * empty); pending permissions stay for the next list or acpmux connect.
   */
  | { kind: "sessions"; sessions: SessionSummary[]; failed?: boolean }
  /** The answer to `fetch_child_events` (an empty list when the request failed). */
  | { kind: "child_events"; session_id: string; events: AcpmuxEvent[] }
  /** A `prompt` request returned (accepted or failed; a failed one is sent again on the next acpmux connect). */
  | { kind: "prompt_settled"; prompt_id: string }
  | { kind: "timer"; key: string }
  | { kind: "disconnected"; port: Port };

/** What the core asks the shell to do, in order. */
export type Effect =
  /** Write the durable state (always the first effect of its step). */
  | { kind: "persist"; state: HostStateData }
  /** Send as agent_mux; answer with `op_result`. */
  | { kind: "conversation_op"; conversation: string; idempotency_key: string; op: Op }
  | { kind: "typing"; conversation: string; on: boolean }
  /** Prompt the mux session (delivery "turn", promptId = prompt_id); answer with `prompt_settled`. */
  | { kind: "prompt"; prompt_id: string; text: string }
  | { kind: "list_conversations" }
  | { kind: "fetch_snapshot"; conversation: string; tail: number }
  | { kind: "fetch_history"; conversation: string; before_seq: number; limit: number }
  | { kind: "fetch_sessions" }
  | { kind: "fetch_child_events"; session_id: string; after: number }
  /** Close the port's connection; the shell reconnects with backoff. */
  | { kind: "reconnect"; port: Port }
  | { kind: "arm_timer"; key: string; at: number }
  /** Both ports are up and a catch-up ran. */
  | { kind: "ready" }
  | { kind: "log"; line: string };

/**
 * Inbox work, one item at a time. `catch_up` and `ready` continue a running
 * catch-up: they need only the daemon (a catch-up that started goes on when
 * acpmux drops, as the old host's did; its prompts stay outstanding).
 */
type InboxItem =
  | { type: "live"; message: Message }
  | { type: "catch_up_all" }
  | { type: "catch_up"; conversation: string }
  | { type: "ready" };

type Task =
  | { type: "idle" }
  | { type: "listing" }
  /** A live message in a conversation the core has no summary for: its tail-1 snapshot. */
  | { type: "summary"; message: Message }
  | { type: "snapshot"; conversation: string }
  | { type: "history"; summary: Summary; from: number; pending: Message[] }
  | { type: "handling"; summary: Summary; queue: Message[]; waiting?: { promptId: string; seq: number } };

const IDLE: Task = { type: "idle" };

/** The brain host's core. `state` is durable; the rest is rebuilt on connect. */
export class Core {
  state: HostStateData;
  private now = 0;
  private dirty = false;
  private effects: Effect[] = [];
  private daemonUp = false;
  private acpmuxUp = false;
  private muxSession?: string;
  private readonly summaries = new Map<string, Summary>();
  /** Highest message seq the inbox handled per conversation (>= the agent_mux read cursor). */
  private readonly handled = new Map<string, number>();
  /** Message id -> author, for the reply-to-mux wake rule. */
  private readonly authors = new Map<string, string>();
  private folder = new TurnFolder();
  /** Conversation where the mux is typing (its running turn's). */
  private typingIn?: string;
  private readonly sessionStatus = new Map<string, SessionStatus>();
  private readonly sessionInfo = new Map<string, SessionSummary>();
  /** Per child: the event seq when its previous turn ended (its next turn's events come after it). */
  private readonly childTurnFloor = new Map<string, number>();
  /** Children whose turn ended, waiting for `child_events`. */
  private readonly pendingChildren = new Map<string, SessionSummary>();
  /** Later `session_changed` inputs of a child with a pending finish, in order (replayed after it). */
  private readonly heldChanges = new Map<string, SessionSummary[]>();
  /** Permission requests from sessions not known as children yet, waiting for `sessions`. */
  private pendingPermissions: { sessionId: string; permissionId: string; request: Record<string, unknown> }[] = [];
  private inbox: InboxItem[] = [];
  private task: Task = IDLE;
  /** The outbox head's idempotency key while the owner has not answered it. */
  private outboxInflight?: string;
  /** When the armed outbox timer fires (cleared when it fires). */
  private outboxTimerAt?: number;
  /** True while acpmux_connected folds the replay of a reset log: its promptless turns are history. */
  private resetReplay = false;

  constructor(state: Partial<HostStateData> = {}) {
    this.state = plainState(loadState(state));
  }

  step(input: Input, nowMs: number): Effect[] {
    this.now = nowMs;
    switch (input.kind) {
      case "daemon_connected":
        this.daemonConnected(input.conversation);
        break;
      case "conversations_listed":
        this.listed(input.conversations);
        break;
      case "snapshot":
        this.snapshot(input.conversation, input.messages);
        break;
      case "history":
        this.history(input.conversation, input.messages);
        break;
      case "fetch_refused":
        this.fetchRefused(input.conversation, input.reason);
        break;
      case "conversation_changed":
        this.changed(input.conversation, input.change);
        break;
      case "op_result":
        this.opResult(input.idempotency_key, input.reason, input.change);
        break;
      case "acpmux_connected":
        this.acpmuxConnected(
          input.session_id,
          input.sessions,
          input.events,
          input.cursor_reset === true,
          input.log_id,
          input.created === true,
        );
        break;
      case "acpmux_event":
        if (input.event.sessionId !== undefined && input.event.sessionId === this.muxSession)
          this.applyMuxEvent(input.event);
        break;
      case "session_changed":
        this.sessionChanged(input.session);
        break;
      case "permission_pending":
        this.permission(input.session_id, input.permission_id, input.request ?? {});
        break;
      case "sessions":
        if (input.failed === true) {
          if (this.pendingPermissions.length > 0) this.log("session list failed; pending permissions wait for the next one");
        } else this.sessions(input.sessions);
        break;
      case "child_events": {
        const session = this.pendingChildren.get(input.session_id);
        if (session) {
          this.pendingChildren.delete(input.session_id);
          this.finishChild(session, lastReply(input.events));
          this.replayHeld(input.session_id);
          this.flushOutbox();
        }
        break;
      }
      case "prompt_settled":
        this.accept(input.prompt_id);
        break;
      case "timer":
        if (input.key === OUTBOX_TIMER) {
          this.outboxTimerAt = undefined;
          this.flushOutbox();
        }
        break;
      case "disconnected":
        this.disconnected(input.port);
        break;
    }
    this.drive();
    const effects = this.effects;
    this.effects = [];
    if (this.dirty) {
      this.dirty = false;
      effects.unshift({ kind: "persist", state: plainState(this.state) });
    }
    return effects;
  }

  private emit(effect: Effect): void {
    this.effects.push(effect);
  }

  private log(line: string): void {
    this.emit({ kind: "log", line });
  }

  // MARK: daemon

  private daemonConnected(conversation: Summary): void {
    if (this.daemonUp) this.disconnected("daemon");
    this.summaries.clear();
    if (this.state.defaultConversation !== conversation.id) {
      this.state.defaultConversation = conversation.id;
      this.dirty = true;
    }
    this.remember(conversation);
    this.daemonUp = true;
    this.flushOutbox();
    if (this.acpmuxUp) this.inbox.push({ type: "catch_up_all" });
  }

  private remember(summary: Summary): void {
    this.summaries.set(summary.id, summary);
    if (!this.handled.has(summary.id)) this.handled.set(summary.id, summary.read_cursors[AGENT_MUX] ?? 0);
    if (summary.last_message) this.authors.set(summary.last_message.id, summary.last_message.author);
  }

  private changed(conversation: string, change: Change): void {
    if (change.kind === "conversation") {
      this.remember(change.conversation);
    } else if (change.kind === "read-cursor") {
      const summary = this.summaries.get(conversation);
      if (summary)
        summary.read_cursors[change.participant] = Math.max(summary.read_cursors[change.participant] ?? 0, change.seq);
    } else if (change.kind === "message") {
      this.authors.set(change.message.id, change.message.author);
      if (this.daemonUp && this.acpmuxUp) this.inbox.push({ type: "live", message: change.message });
    }
  }

  private disconnected(port: Port): void {
    if (port === "daemon") {
      this.daemonUp = false;
      this.outboxInflight = undefined;
      this.inbox = [];
      // Every daemon read fails with the connection; a prompt-only handling task goes on.
      if (this.task.type !== "handling") this.task = IDLE;
      return;
    }
    this.acpmuxUp = false;
    this.inbox = this.inbox.filter((item) => item.type === "catch_up" || item.type === "ready");
    // Pending permissions stay: the session list of the next acpmux connect answers them.
    if (this.typingIn) this.setTyping(this.typingIn, false);
    // The old host settled every prompt waiter when acpmux closed: the inbox moves on and
    // the prompt stays outstanding, resent on the next acpmux connect.
    if (this.task.type === "handling" && this.task.waiting) this.accept(this.task.waiting.promptId);
    // A child whose events fetch dies with the connection finishes with no reply text.
    const children = [...this.pendingChildren.values()].sort((a, b) => compare(a.sessionId, b.sessionId));
    this.pendingChildren.clear();
    for (const session of children) {
      this.finishChild(session, "");
      this.replayHeld(session.sessionId);
    }
    if (children.length > 0) this.flushOutbox();
  }

  // MARK: inbox

  /** Starts inbox work, one item at a time, while the ports it needs are up. */
  private drive(): void {
    while (this.task.type === "idle") {
      const item = this.inbox[0];
      if (!item) return;
      const continuation = item.type === "catch_up" || item.type === "ready";
      if (!this.daemonUp || (!continuation && !this.acpmuxUp)) return;
      this.inbox.shift();
      switch (item.type) {
        case "live":
          this.live(item.message);
          break;
        case "catch_up_all":
          this.emit({ kind: "list_conversations" });
          this.task = { type: "listing" };
          break;
        case "catch_up":
          this.catchUp(item.conversation);
          break;
        case "ready":
          this.emit({ kind: "ready" });
          break;
      }
    }
  }

  private catchUp(conversation: string): void {
    this.emit({ kind: "fetch_snapshot", conversation, tail: PAGE });
    this.task = { type: "snapshot", conversation };
  }

  /** A live message: handle it in seq order, or catch the conversation up when the core missed some. */
  private live(message: Message): void {
    const summary = this.summaries.get(message.conversation);
    if (!summary) {
      this.emit({ kind: "fetch_snapshot", conversation: message.conversation, tail: 1 });
      this.task = { type: "summary", message };
      return;
    }
    this.liveWith(summary, message);
  }

  private liveWith(summary: Summary, message: Message): void {
    if (!summary.participants.some((p) => p.id === AGENT_MUX)) return;
    const handled = this.handled.get(summary.id) ?? 0;
    if (message.seq <= handled) return;
    if (message.seq > handled + 1) return this.catchUp(summary.id);
    this.task = { type: "handling", summary: plain(summary), queue: [message] };
    this.process();
  }

  private listed(conversations: Summary[]): void {
    if (this.task.type !== "listing") return;
    const front: InboxItem[] = [];
    for (const summary of conversations) {
      this.remember(summary);
      if (summary.participants.some((p) => p.id === AGENT_MUX))
        front.push({ type: "catch_up", conversation: summary.id });
    }
    front.push({ type: "ready" });
    this.inbox.unshift(...front);
    this.task = IDLE;
  }

  private snapshot(summary: Summary, messages: Message[]): void {
    const task = this.task;
    if (task.type === "summary") {
      if (task.message.conversation !== summary.id) return;
      this.task = IDLE;
      this.remember(summary);
      this.liveWith(summary, task.message);
      return;
    }
    if (task.type !== "snapshot" || task.conversation !== summary.id) return;
    this.summaries.set(summary.id, summary);
    const from = Math.max(this.handled.get(summary.id) ?? 0, summary.read_cursors[AGENT_MUX] ?? 0);
    this.handled.set(summary.id, from);
    for (const message of messages) this.authors.set(message.id, message.author);
    // The paging task keeps its own copy: later summary events change only the cache.
    this.page(
      plain(summary),
      from,
      messages.filter((m) => m.seq > from),
    );
  }

  private history(conversation: string, older: Message[]): void {
    const task = this.task;
    if (task.type !== "history" || task.summary.id !== conversation) return;
    if (older.length === 0) return this.handleAll(task.summary, task.pending);
    this.page(task.summary, task.from, [...older.filter((m) => m.seq > task.from), ...task.pending]);
  }

  /** A refused read: its task is dropped and the inbox goes on (a refused list still ends in ready). */
  private fetchRefused(conversation: string | undefined, reason: string): void {
    const task = this.task;
    const matches =
      conversation === undefined
        ? task.type === "listing"
        : (task.type === "snapshot" && task.conversation === conversation) ||
          (task.type === "summary" && task.message.conversation === conversation) ||
          (task.type === "history" && task.summary.id === conversation);
    if (!matches) return;
    this.log(`the owner refused ${conversation === undefined ? "the conversation list" : `reading ${conversation}`}: ${reason}; skipped`);
    this.task = IDLE;
    if (conversation === undefined) this.inbox.unshift({ type: "ready" });
  }

  /** Pages back until the first missing message is in hand, then handles. */
  private page(summary: Summary, from: number, pending: Message[]): void {
    const first = pending[0];
    if (first && first.seq > from + 1) {
      this.emit({ kind: "fetch_history", conversation: summary.id, before_seq: first.seq, limit: PAGE });
      this.task = { type: "history", summary, from, pending };
      return;
    }
    this.handleAll(summary, pending);
  }

  /** Handles `pending` in order with a copy of the summary taken now (later summary events do not change it). */
  private handleAll(summary: Summary, pending: Message[]): void {
    this.task = { type: "handling", summary: plain(summary), queue: [...pending] };
    this.process();
  }

  /** Handles queued messages in order; stops while a prompt waits for acpmux. */
  private process(): void {
    for (;;) {
      const task = this.task;
      if (task.type !== "handling" || task.waiting) return;
      const message = task.queue.shift();
      if (!message) {
        this.task = IDLE;
        return;
      }
      const summary = task.summary;
      this.authors.set(message.id, message.author);
      if (message.seq <= (this.handled.get(summary.id) ?? 0)) continue;
      const wake =
        !isAnswered(this.state, message.id) &&
        wakes(summary, message, (id) => this.authors.get(id) === AGENT_MUX);
      if (wake) {
        this.recordPrompt(message.id, { conversation: summary.id, text: inboxPrompt(summary, message), seq: message.seq });
        this.dirty = true;
        task.waiting = { promptId: message.id, seq: message.seq };
        // Without a session the prompt stays outstanding (sent on the next acpmux connect).
        if (!this.sendPrompt(message.id)) this.accept(message.id);
        return;
      }
      this.finishMessage(summary, message.seq);
    }
  }

  /** The message is handled: agent_mux's read cursor moves past it. */
  private finishMessage(summary: Summary, seq: number): void {
    this.handled.set(summary.id, seq);
    if (!this.daemonUp || seq <= (summary.read_cursors[AGENT_MUX] ?? 0)) return;
    this.emit({
      kind: "conversation_op",
      conversation: summary.id,
      idempotency_key: `cursor:${AGENT_MUX}:${seq}`,
      op: { kind: "read_cursor.set", seq },
    });
  }

  /** Records an outstanding prompt with the next order (one more than any outstanding one); one already outstanding keeps its order. */
  private recordPrompt(promptId: string, entry: { conversation: string; text: string; seq?: number }): void {
    // An outstanding prompt recorded again keeps its place.
    const kept = this.state.prompts[promptId]?.order;
    const last = Math.max(0, ...Object.values(this.state.prompts).map((p) => p.order ?? 0));
    this.state.prompts[promptId] = { ...entry, order: kept ?? last + 1 };
  }

  /** Emits the prompt for an outstanding entry; false without a session. */
  private sendPrompt(promptId: string): boolean {
    const entry = this.state.prompts[promptId];
    if (!entry || !this.acpmuxUp || !this.muxSession) return false;
    this.emit({ kind: "prompt", prompt_id: promptId, text: entry.text });
    return true;
  }

  /** acpmux holds the prompt (or answered its request): the inbox moves on. */
  private accept(promptId: string): void {
    const task = this.task;
    if (task.type !== "handling" || task.waiting?.promptId !== promptId) return;
    const { seq } = task.waiting;
    task.waiting = undefined;
    this.finishMessage(task.summary, seq);
    this.process();
  }

  // MARK: acpmux

  /**
   * Reply keys and the log identity. The log identity is the `at` of the log's
   * seq 1 event (`log_id`, else a replayed seq 1 event). A reset is a log whose
   * turn seqs may repeat keys already used:
   * - same session: `cursor_reset` (acpmux refused the saved cursor) or a known
   *   identity that differs from host.json's `acpmuxLog` (a host.json without
   *   one, from before it existed, adopts the identity with no reset); the epoch becomes
   *   max(identity + 1, else now; previous epoch + 1), so a repeated import of the
   *   same bundle still gets a new epoch, and no epoch an older core used repeats;
   * - a session host.json does not know (a lost or replaced host.json) with a
   *   non-empty log, unless the shell created it on this connect (`created`:
   *   a new log, whose only event is acpmux's created event): earlier epochs
   *   are unknown, so the epoch is now.
   * Keys are `turn:<session>:<seq>` while no reset happened (the identity
   * equals host.json's), else `turn:<session>:<epoch>:<seq>`. The replay of a
   * reset posts no promptless turn; turns of prompts the core no longer holds
   * never post (turnConversation).
   */
  private acpmuxConnected(
    sessionId: string,
    sessions: SessionSummary[],
    events: AcpmuxEvent[],
    cursorReset: boolean,
    logId: number | undefined,
    created: boolean,
  ): void {
    if (this.acpmuxUp) this.disconnected("acpmux");
    // A log_id that is not a non-negative safe integer is unknown (as the Rust core reads it).
    if (logId !== undefined && !isCount(logId)) {
      this.log(`ignoring log_id ${String(logId)}: not a non-negative integer`);
      logId = undefined;
    }
    const first = events[0];
    const identity = logId ?? (first && validEvent(first) && first.seq === 1 && typeof first.at === "number" ? first.at : undefined);
    let reset = false;
    if (this.state.muxSessionId !== sessionId) {
      this.state.muxSessionId = sessionId;
      this.state.acpmuxSeq = 0;
      delete this.state.acpmuxEpoch;
      delete this.state.acpmuxLog;
      if (identity !== undefined && !created) {
        reset = true;
        this.state.acpmuxEpoch = this.now;
      }
      this.dirty = true;
    } else if (
      cursorReset ||
      // A legacy host.json (no acpmuxLog) adopts the identity below without a reset.
      (identity !== undefined && this.state.acpmuxLog !== undefined && identity !== this.state.acpmuxLog)
    ) {
      reset = true;
      this.state.acpmuxSeq = 0;
      // identity + 1: an older core used the identity itself as the first epoch (downgrade-safe).
      const candidate = identity !== undefined ? identity + 1 : this.now;
      const previous = this.state.acpmuxEpoch;
      this.state.acpmuxEpoch = previous === undefined ? candidate : Math.max(candidate, previous + 1);
      this.dirty = true;
    }
    if (identity !== undefined && identity !== this.state.acpmuxLog) {
      this.state.acpmuxLog = identity;
      this.dirty = true;
    }
    this.muxSession = sessionId;
    for (const session of sessions) {
      this.sessionStatus.set(session.sessionId, session.status);
      this.sessionInfo.set(session.sessionId, session);
    }
    this.folder = new TurnFolder(this.state.acpmuxSeq);
    this.resetReplay = reset;
    for (const event of events) this.applyMuxEvent(event);
    this.resetReplay = false;
    this.acpmuxUp = true;
    // A permission prompt whose session is not waiting in this list was answered meanwhile
    // (or the session is gone): dropped, not resent. (The `sessions` reply path keeps its
    // rule: acpmux's event order there is not confirmed.)
    for (const promptId of Object.keys(this.state.prompts).sort(compare)) {
      if (!promptId.startsWith("perm:")) continue;
      if (sessions.some((s) => s.status === "waiting" && promptId.startsWith(`perm:${s.sessionId}:`))) continue;
      delete this.state.prompts[promptId];
      this.dirty = true;
      this.log(`dropping permission prompt ${promptId}: its session is not waiting`);
    }
    // Prompts acpmux may have dropped with an old connection, in recorded order; it dedupes the rest by promptId.
    const order = (id: string) => this.state.prompts[id].order ?? 0;
    for (const promptId of Object.keys(this.state.prompts).sort((a, b) => order(a) - order(b) || compare(a, b)))
      this.sendPrompt(promptId);
    // Permissions that waited for a session list (a failed fetch, or the last connection's loss).
    // One whose session is no longer waiting was answered meanwhile: dropped.
    if (this.pendingPermissions.length > 0) this.sessions(sessions.filter((s) => s.status === "waiting"));
    this.reconcileChildren();
    if (this.daemonUp) this.inbox.push({ type: "catch_up_all" });
  }

  private applyMuxEvent(event: AcpmuxEvent): void {
    if (!validEvent(event)) {
      this.log(`dropping acpmux event ${String(event.kind)}: seq and at must be non-negative integers`);
      return;
    }
    // A new log's first event names it (acpmuxLog), so a later connect can compare.
    if (event.seq === 1 && typeof event.at === "number" && this.state.acpmuxLog === undefined) {
      this.state.acpmuxLog = event.at;
      this.dirty = true;
    }
    for (const output of this.folder.apply(event)) {
      if (output.type === "accepted") {
        this.accept(output.promptId);
        continue;
      }
      const conversation = this.turnConversation(output.turn.promptId);
      if (output.type === "started") {
        if (conversation) this.setTyping(conversation, true);
        continue;
      }
      const text = output.turn.text.trim() || (output.error ? `(turn failed: ${output.error})` : "");
      if (!conversation && !output.turn.promptId && this.resetReplay)
        this.log(`turn ${output.turn.turnSeq} replayed after a reset has no prompt; reply not posted`);
      if (!conversation && output.turn.promptId)
        this.log(`turn ${output.turn.turnSeq} answers prompt ${output.turn.promptId}, which is answered or lost; reply not posted`);
      if (conversation && text) {
        const key = turnKey(this.muxSession ?? "", output.turn.turnSeq, this.state.acpmuxEpoch);
        this.state.outbox.push({
          conversation,
          idempotency_key: key,
          op: { kind: "message.send", client_msg_id: key, parts: [{ type: "text", text }] },
        });
      }
      if (output.turn.promptId) markAnswered(this.state, output.turn.promptId);
      this.state.acpmuxSeq = Math.max(this.state.acpmuxSeq, output.seq);
      this.dirty = true;
      this.flushOutbox();
      if (conversation) this.setTyping(conversation, false);
    }
  }

  /**
   * Where a turn's typing and reply go: its prompt's conversation, the default
   * one for a turn without a prompt (none while replaying a reset log), and
   * none for a prompt the core no longer holds (answered, or lost): a replayed
   * old turn posts nothing.
   */
  private turnConversation(promptId: string | undefined): string | undefined {
    // A promptless turn in the replay of a reset log was posted (or not) by the log's past.
    if (!promptId) return this.resetReplay ? undefined : this.state.defaultConversation || undefined;
    const entry = this.state.prompts[promptId];
    // An answered prompt's turn was posted already (a reset replay meets it again).
    if (!entry || isAnswered(this.state, promptId)) return undefined;
    return entry.conversation || this.state.defaultConversation || undefined;
  }

  private conversationFor(promptId: string | undefined): string | undefined {
    return (promptId && this.state.prompts[promptId]?.conversation) || this.state.defaultConversation;
  }

  private setTyping(conversation: string, on: boolean): void {
    this.typingIn = on ? conversation : undefined;
    if (this.daemonUp) this.emit({ kind: "typing", conversation, on });
  }

  // MARK: outbox

  /** Sends the outbox head; the next entry waits for its result. */
  private flushOutbox(): void {
    while (this.daemonUp && this.outboxInflight === undefined) {
      const entry = this.state.outbox[0];
      if (!entry) return;
      if (entry.notBefore && this.now < entry.notBefore) {
        // Its one-shot timer flushes it; armed again here after a restart or an early fire.
        this.armOutboxTimer(entry.notBefore + AGENT_GAP_TIMER_SLACK_MS);
        return;
      }
      let op: Op | undefined = entry.op;
      if (entry.child && entry.op.kind === "message.edit") {
        const messageId = this.state.children[entry.child]?.messageId;
        op = messageId ? { ...entry.op, message_id: messageId } : undefined;
      }
      if (!op) {
        // An edit of a card whose send was never confirmed: nothing to edit.
        this.state.outbox.shift();
        this.dirty = true;
        continue;
      }
      this.outboxInflight = entry.idempotency_key;
      this.emit({ kind: "conversation_op", conversation: entry.conversation, idempotency_key: entry.idempotency_key, op });
    }
  }

  private opResult(key: string, reason: string | undefined, change: Change | undefined): void {
    if (this.outboxInflight !== key) {
      // A read cursor op: the owner's change event updates the summary.
      if (reason !== undefined && !reason.includes("cursor_regression")) this.log(`op ${key} rejected: ${reason}`);
      return;
    }
    this.outboxInflight = undefined;
    const head = this.state.outbox[0];
    if (!head) return;
    if (reason === undefined) {
      if (head.child && head.op.kind === "message.send" && change?.kind === "message") {
        const child = this.state.children[head.child];
        if (child) child.messageId = change.message.id;
      }
    } else if (reason.includes("actor_mismatch")) {
      // The binding was lost (the app replaced the token): reconnect, which
      // binds again with the current token, and keep the entry.
      this.log(`op ${key}: binding lost; reconnecting to bind again`);
      this.emit({ kind: "reconnect", port: "daemon" });
      return;
    } else if (reason.includes("agent_rate") && !head.rateRetried) {
      // The owner's agent turn budget: a reply sent inside the minimum gap is
      // retried once, after the gap; anything else (agent_budget too) is dropped.
      head.rateRetried = true;
      head.notBefore = this.now + AGENT_GAP_RETRY_MS;
      this.dirty = true;
      this.log(`op ${key} inside the agent gap; retrying once after it`);
      this.armOutboxTimer(head.notBefore + AGENT_GAP_TIMER_SLACK_MS);
      return;
    } else {
      this.log(`dropping rejected op ${key}: ${reason}`);
    }
    this.state.outbox.shift();
    this.dirty = true;
    this.flushOutbox();
  }

  private armOutboxTimer(at: number): void {
    if (this.outboxTimerAt === at) return;
    this.outboxTimerAt = at;
    this.emit({ kind: "arm_timer", key: OUTBOX_TIMER, at });
  }

  // MARK: children (sessions tagged mux.parent=mux)

  private isChild(session: SessionSummary): boolean {
    return session.tags?.[PARENT_TAG] === MUX_SESSION_NAME && session.sessionId !== this.muxSession;
  }

  private sessionChanged(session: SessionSummary): void {
    // A child's finish waits for its events: its later changes wait behind it, in order.
    const held = this.heldChanges.get(session.sessionId);
    if (held || this.pendingChildren.has(session.sessionId)) {
      if (held) held.push(session);
      else this.heldChanges.set(session.sessionId, [session]);
      return;
    }
    const before = this.sessionStatus.get(session.sessionId);
    this.sessionStatus.set(session.sessionId, session.status);
    this.sessionInfo.set(session.sessionId, session);
    if (!this.isChild(session)) return;
    const child = this.child(session);
    if (turnEnded(before, session.status)) this.childFinished(session);
    else if (session.status === "running" && child.status !== "running")
      this.editWork(session.sessionId, session.name, "running", session.preview);
    else if ((session.status === "closed" || session.status === "disconnected") && child.status === "running")
      this.editWork(session.sessionId, session.name, "failed", session.preview);
    this.flushOutbox();
  }

  /** The child's record, registered with a work card in the conversation the mux is answering when new. */
  private child(session: SessionSummary): ChildRecord {
    const existing = this.state.children[session.sessionId];
    if (existing) return { ...existing };
    const conversation = this.conversationFor(this.folder.running?.promptId) ?? "";
    // A child first seen ready or idle gets a done card (closed: failed, waiting: waiting).
    const status = workStatus(session.status);
    const child: ChildRecord = { conversation, name: session.name, status, edits: 0 };
    this.state.children[session.sessionId] = child;
    if (conversation) {
      const key = `work:${session.sessionId}`;
      this.state.outbox.push({
        conversation,
        idempotency_key: key,
        child: session.sessionId,
        op: { kind: "message.send", client_msg_id: key, parts: [workPart(session.name, status, session.lastPrompt)] },
      });
    }
    this.dirty = true;
    this.log(`child ${session.name} started (${session.sessionId})`);
    return { ...child };
  }

  private editWork(sessionId: string, name: string, status: WorkStatus, preview?: string | null): void {
    const child = this.state.children[sessionId];
    if (!child) return;
    child.status = status;
    child.edits += 1;
    if (child.conversation)
      this.state.outbox.push({
        conversation: child.conversation,
        idempotency_key: `work:${sessionId}:${child.edits}`,
        child: sessionId,
        op: { kind: "message.edit", message_id: "", parts: [workPart(name, status, preview)] },
      });
    this.dirty = true;
  }

  /** Replays a child's held changes after its finish, until one starts another finish. */
  private replayHeld(sessionId: string): void {
    const held = this.heldChanges.get(sessionId);
    if (!held) return;
    this.heldChanges.delete(sessionId);
    for (let next = held.shift(); next; next = held.shift()) {
      this.sessionChanged(next);
      if (this.pendingChildren.has(sessionId)) {
        if (held.length > 0) this.heldChanges.set(sessionId, held);
        return;
      }
    }
  }

  private childFinished(session: SessionSummary): void {
    if (this.acpmuxUp) {
      const after = this.childTurnFloor.get(session.sessionId) ?? 0;
      this.emit({ kind: "fetch_child_events", session_id: session.sessionId, after });
      this.pendingChildren.set(session.sessionId, session);
    } else {
      this.finishChild(session, "");
    }
  }

  private finishChild(session: SessionSummary, reply: string): void {
    this.childTurnFloor.set(session.sessionId, session.lastSeq ?? 0);
    this.editWork(session.sessionId, session.name, workStatus(session.status), excerpt(reply, 200) || session.preview);
    const promptId = `child:${session.sessionId}:${session.turnCount ?? session.stateSeq ?? 0}`;
    this.recordPrompt(promptId, {
      conversation: this.childConversation(session.sessionId),
      text: childFinishedPrompt(session, reply),
    });
    this.dirty = true;
    this.log(`child ${session.name} finished; telling the mux`);
    this.sendPrompt(promptId);
  }

  private childConversation(sessionId: string): string {
    return this.state.children[sessionId]?.conversation || (this.state.defaultConversation ?? "");
  }

  private permission(sessionId: string, permissionId: string, request: Record<string, unknown>): void {
    const known = this.sessionInfo.get(sessionId);
    if (!known?.tags?.[PARENT_TAG] && this.acpmuxUp) {
      // Not known as a child yet: look the session up in a fresh session list.
      this.pendingPermissions.push({ sessionId, permissionId, request });
      this.emit({ kind: "fetch_sessions" });
      return;
    }
    this.onPermission(known, sessionId, permissionId, request);
  }

  private sessions(sessions: SessionSummary[]): void {
    const pending = this.pendingPermissions;
    this.pendingPermissions = [];
    for (const { sessionId, permissionId, request } of pending)
      this.onPermission(
        sessions.find((s) => s.sessionId === sessionId),
        sessionId,
        permissionId,
        request,
      );
  }

  private onPermission(
    session: SessionSummary | undefined,
    sessionId: string,
    permissionId: string,
    request: Record<string, unknown>,
  ): void {
    if (!session || !this.isChild(session)) return;
    const known = Object.hasOwn(this.state.children, sessionId);
    // A child first seen waiting already got a waiting card: no second, identical edit.
    if (known || this.child(session).status !== "waiting") {
      this.child(session);
      this.editWork(sessionId, session.name, "waiting", session.preview);
    }
    const promptId = `perm:${sessionId}:${permissionId}`;
    this.recordPrompt(promptId, {
      conversation: this.childConversation(sessionId),
      text: childPermissionPrompt(session, request),
    });
    this.dirty = true;
    this.flushOutbox();
    this.sendPrompt(promptId);
  }

  /** After a reconnect: children whose turn ended (or whose session is gone) while the host was away. */
  private reconcileChildren(): void {
    for (const sessionId of Object.keys(this.state.children).sort(compare)) {
      const child = this.state.children[sessionId];
      const session = this.sessionInfo.get(sessionId);
      if (!session) {
        if (child.status === "running" || child.status === "waiting") this.editWork(sessionId, child.name, "failed");
        continue;
      }
      // A turn (or a permission wait) that ended while the host was away.
      if ((child.status === "running" || child.status === "waiting") && (session.status === "ready" || session.status === "idle"))
        this.childFinished(session);
    }
    this.flushOutbox();
  }
}
