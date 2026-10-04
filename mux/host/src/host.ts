import { isCount } from "../../packages/brain/src/core/acp.ts";
import { Core, type Effect, type Input } from "../../packages/brain/src/core/core.ts";
import { DEFAULT_CONVERSATION_KEY, MUX_SESSION_NAME } from "../../packages/brain/src/core/rules.ts";
import {
  type AcpmuxEvent,
  AcpmuxClient,
  AcpmuxClosedError,
  AcpmuxError,
  type McpServer,
  type Notification,
  type SessionSummary,
  eventFromUpdate,
} from "./acpmux-client.ts";
import { AGENT_MUX, type ConversationChangedEvent, type Participant, USER_LOCAL } from "./conversation-types.ts";
import { DaemonClient, DaemonError, MissingCapabilityError } from "./daemon-client.ts";
import { takeLock } from "./lock.ts";
import type { MuxPaths } from "./paths.ts";
import { writeSessionDir } from "./session-dir.ts";
import { HostStateFile } from "./state.ts";

export { DEFAULT_CONVERSATION_KEY, MUX_SESSION_NAME };

// The local mux brain host (plans/cmux-next/home.md section 4): a thin I/O
// shell around the brain core (packages/brain/src/core/core.ts), which holds
// every decision. A client of two owners, listening on nothing:
//   - the cmux daemon's local conversation owner (conversation-* commands and
//     conversation-changed events), and
//   - acpmux, which owns the mux session `mux` and its child agents.
// The shell turns owner events and request results into core inputs and runs
// the core's effects: `persist` first (write-ahead), then requests, whose
// answers come back as inputs. Every effect is keyed so an owner dedupes a
// replay (promptId at acpmux, idempotency key at the conversation owner).

/** The timers the shell uses for request timeouts and the outbox retry; tests inject a fake one. */
export interface Clock {
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
  /** Milliseconds since the epoch on this clock: the core's time and every timer use it. */
  nowMs(): number;
}

/** Real timers. They keep the process alive (the reconnect backoff is one of them; the host is a daemon). */
const realClock: Clock = {
  setTimeout(fn, ms) {
    return setTimeout(fn, ms);
  },
  clearTimeout(handle) {
    clearTimeout(handle as ReturnType<typeof setTimeout>);
  },
  nowMs: () => Date.now(),
};

/** A daemon or acpmux request that got no answer within the request timeout. */
export class RequestTimeoutError extends Error {}

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
  /**
   * The mux's conversation credential (minted by the app as the local user):
   * after creating the default conversation, the connection binds as agent_mux so
   * the owner stamps the mux's writes. Absent in tests against the fake daemon.
   */
  agentToken?: string | (() => string | undefined);
  /** Makes the acpmux socket reachable before each connect (starts the daemon from ACPMUX_BIN). */
  startAcpmux?: () => Promise<void>;
  log?: (line: string) => void;
  /** Reconnect backoff after a failed or lost connection. */
  backoff?: { initialMs: number; maxMs: number };
  /** Timers for request timeouts and the outbox retry (default: real timers). */
  clock?: Clock;
  /** How long one daemon or acpmux request (not a prompt) may take before its connection counts as lost (default 30 s). */
  requestTimeoutMs?: number;
}

export class HostAlreadyRunningError extends Error {}

export class MuxHost {
  private readonly stateFile: HostStateFile;
  /** Created in start(), after the MUX_HOME lock, so the state is read by its only writer. */
  private core!: Core;
  private readonly log: (line: string) => void;
  private releaseLock?: () => void;
  private stopped = false;
  /** Aborted by stop(): in-flight connects listen to it. */
  private readonly stopping = new AbortController();
  private readonly stoppedSignal: Promise<void>;
  private signalStop!: () => void;
  private readonly timers = new Map<string, unknown>();
  /** Prompts waiting for `_acpmux/prompt_accepted`: the deadline timer and the connection. */
  private readonly promptAcks = new Map<string, { timer: unknown; acpmux: AcpmuxClient }>();
  /** Per connection loop: the clock time its connection came up, if it did. */
  private readonly upAt = new Map<string, number>();
  private readonly clock: Clock;
  private readonly queue: { effect: Effect; daemon?: DaemonClient; acpmux?: AcpmuxClient }[] = [];
  private draining = false;

  private daemon?: DaemonClient;
  private acpmux?: AcpmuxClient;

  private readyResolve!: () => void;
  /** Resolves once both owners are connected and the first catch-up ran. */
  readonly ready: Promise<void>;
  private fail!: (error: Error) => void;
  /** Rejects when the host cannot run at all (the daemon lacks local conversations). */
  readonly fatal: Promise<never>;

  constructor(private readonly options: HostOptions) {
    this.log = options.log ?? ((line) => console.error(`${new Date().toISOString()} mux host: ${line}`));
    this.stateFile = new HostStateFile(options.paths.hostState);
    this.clock = options.clock ?? realClock;
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
    try {
      // Read after the lock: the state's only writer is the lock holder.
      this.core = new Core(this.stateFile.load());
      writeSessionDir(this.options.paths, this.options.self, this.options.sessionEnv, {
        mcp: this.options.mcpServers.length > 0,
      });
    } catch (error) {
      // A host that does not start must not keep the lock.
      this.releaseLock = undefined;
      release();
      throw error;
    }
    void this.loop("daemon", () => this.runDaemon());
    void this.loop("acpmux", () => this.runAcpmux());
  }

  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.signalStop();
    this.stopping.abort();
    for (const timer of this.timers.values()) this.clock.clearTimeout(timer);
    this.timers.clear();
    for (const { timer } of this.promptAcks.values()) this.clock.clearTimeout(timer);
    this.promptAcks.clear();
    this.daemon?.close();
    this.acpmux?.close();
    this.releaseLock?.();
  }

  /** Runs one connection until it ends; reconnects with backoff only after a failure or loss. */
  private async loop(name: string, run: () => Promise<void>): Promise<void> {
    const { initialMs, maxMs } = this.options.backoff ?? { initialMs: 500, maxMs: 30_000 };
    let delay = initialMs;
    while (!this.stopped) {
      this.upAt.delete(name);
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
      // A connection that lived longer than maxMs starts the backoff over; one
      // that came up and closed at once keeps growing it.
      const up = this.upAt.get(name);
      if (up !== undefined && this.clock.nowMs() - up > maxMs) delay = initialMs;
      // The wait runs on the injected clock; stop() ends it at once.
      let timer: unknown;
      await Promise.race([new Promise((resolve) => (timer = this.clock.setTimeout(() => resolve(undefined), delay))), this.stoppedSignal]);
      this.clock.clearTimeout(timer);
      delay = Math.min(delay * 2, maxMs);
    }
  }

  // MARK: core

  /**
   * Steps the core and queues its effects. Effects run in order, one at a
   * time, each on the connections that were current when its step ran; a
   * conversation write waits for the owner's answer before the next effect
   * starts (as the old host's serial queue did), and its answer is the next
   * input. `persist` is the first effect of its step, so the state is on
   * disk before that step's requests go out. `log` lines are written at once.
   */
  private feed(input: Input): void {
    if (this.stopped) return;
    const ports = { daemon: this.daemon, acpmux: this.acpmux };
    for (const effect of this.core.step(input, this.clock.nowMs())) {
      // Diagnostics are written when the core decides, not when the queue gets there.
      if (effect.kind === "log") this.log(effect.line);
      else this.queue.push({ effect, ...ports });
    }
    void this.drain();
  }

  private async drain(): Promise<void> {
    if (this.draining) return;
    this.draining = true;
    try {
      for (let next = this.queue.shift(); next && !this.stopped; next = this.queue.shift()) {
        try {
          await this.run(next.effect, next.daemon, next.acpmux);
        } catch (error) {
          this.log(`effect ${next.effect.kind} failed: ${String(error)}`);
        }
      }
    } finally {
      this.draining = false;
    }
  }

  private async run(effect: Effect, daemon: DaemonClient | undefined, acpmux: AcpmuxClient | undefined): Promise<void> {
    switch (effect.kind) {
      case "persist":
        this.stateFile.save(effect.state);
        return;
      case "log":
        this.log(effect.line);
        return;
      case "ready":
        this.readyResolve();
        return;
      case "arm_timer": {
        this.clock.clearTimeout(this.timers.get(effect.key));
        const timer = this.clock.setTimeout(
          () => {
            this.timers.delete(effect.key);
            this.feed({ kind: "timer", key: effect.key });
          },
          Math.max(0, effect.at - this.clock.nowMs()),
        );
        this.timers.set(effect.key, timer);
        return;
      }
      case "reconnect":
        (effect.port === "daemon" ? daemon : acpmux)?.close();
        return;
      case "prompt":
        this.prompt(acpmux, effect.prompt_id, effect.text);
        return;
      case "fetch_sessions":
        if (!acpmux) return;
        void this.timed(acpmux, "acpmux", "sessions", acpmux.sessions()).then(
          (sessions) => this.feed({ kind: "sessions", sessions }),
          () => this.feed({ kind: "sessions", sessions: [], failed: true }),
        );
        return;
      case "fetch_child_events":
        if (!acpmux) return;
        void this.timed(acpmux, "acpmux", "events", acpmux.events(effect.session_id, effect.after))
          .catch(() => [] as AcpmuxEvent[])
          .then((events) => this.feed({ kind: "child_events", session_id: effect.session_id, events }));
        return;
    }
    if (!daemon || daemon.isClosed) return;
    switch (effect.kind) {
      case "conversation_op":
        try {
          const result = await this.timed(daemon, "daemon", "op", daemon.op({
            conversation: effect.conversation,
            idempotency_key: effect.idempotency_key,
            actor: AGENT_MUX,
            op: effect.op,
          }));
          this.feed({ kind: "op_result", idempotency_key: effect.idempotency_key, change: result.change });
        } catch (error) {
          // A reject carries the owner's reason; a lost connection arrives as `disconnected`.
          if (error instanceof DaemonError)
            this.feed({ kind: "op_result", idempotency_key: effect.idempotency_key, reason: error.message });
        }
        return;
      case "typing":
        try {
          await this.timed(daemon, "daemon", "typing", daemon.typing(effect.conversation, AGENT_MUX, effect.on));
        } catch (error) {
          this.log(`typing ${effect.on ? "on" : "off"} failed: ${String(error)}`);
        }
        return;
      case "list_conversations":
        this.read(daemon, undefined, this.timed(daemon, "daemon", "list", daemon.list()), (conversations) => ({ kind: "conversations_listed", conversations }));
        return;
      case "fetch_snapshot":
        this.read(daemon, effect.conversation, this.timed(daemon, "daemon", "snapshot", daemon.snapshot(effect.conversation, effect.tail)), ({ conversation, messages }) => ({
          kind: "snapshot",
          conversation,
          messages,
        }));
        return;
      case "fetch_history":
        this.read(
          daemon,
          effect.conversation,
          this.timed(daemon, "daemon", "history", daemon.history(effect.conversation, effect.before_seq, effect.limit)),
          (messages) => ({ kind: "history", conversation: effect.conversation, messages }),
        );
        return;
    }
  }

  /** How long one daemon or acpmux request may take (default 30 s). */
  private get requestTimeoutMs(): number {
    return this.options.requestTimeoutMs ?? 30_000;
  }

  /**
   * A connect (socket plus handshake) bounded by the request timeout. The
   * deadline, or stop(), aborts the connect, which closes its socket, so a
   * stuck handshake leaves no socket open; a client that still arrives late
   * (or after stop) is closed.
   */
  private connectWithin<T extends { close(): void }>(what: string, start: (signal: AbortSignal) => Promise<T>): Promise<T> {
    const ms = this.requestTimeoutMs;
    const controller = new AbortController();
    let late = false;
    const connect = start(controller.signal);
    return new Promise<T>((resolve, reject) => {
      const timer = this.clock.setTimeout(() => {
        late = true;
        this.log(`${what} connect got no answer in ${ms} ms; retrying`);
        controller.abort();
        reject(new RequestTimeoutError(`${what} connect timed out`));
      }, ms);
      // stop() aborts the connect too: its socket closes and nothing runs after it.
      const onStop = () => {
        if (late) return;
        late = true;
        this.clock.clearTimeout(timer);
        controller.abort();
        reject(new Error(`${what} connect stopped`));
      };
      if (this.stopping.signal.aborted) onStop();
      else this.stopping.signal.addEventListener("abort", onStop, { once: true });
      connect.then(
        (client) => {
          this.stopping.signal.removeEventListener("abort", onStop);
          this.clock.clearTimeout(timer);
          if (late || this.stopped) client.close();
          if (late) return;
          if (this.stopped) {
            late = true;
            reject(new Error(`${what} connect stopped`));
            return;
          }
          resolve(client);
        },
        (error) => {
          this.stopping.signal.removeEventListener("abort", onStop);
          this.clock.clearTimeout(timer);
          reject(error);
        },
      );
    });
  }

  /**
   * A daemon or acpmux request bounded by the request timeout. A timeout
   * counts as a lost connection: that connection is dropped (the core sees
   * `disconnected`), the request fails, and the reconnect retries. One stuck
   * daemon request cannot block the serial effect queue; a stuck acpmux read
   * cannot leave a child finish or a permission waiting forever. Prompts have
   * their own deadline on the acknowledgment (`prompt`).
   */
  private timed<T>(client: { close(): void }, port: "daemon" | "acpmux", what: string, request: Promise<T>): Promise<T> {
    const ms = this.requestTimeoutMs;
    return new Promise<T>((resolve, reject) => {
      const timer = this.clock.setTimeout(() => {
        this.log(`${port} ${what} got no answer in ${ms} ms; reconnecting`);
        reject(new RequestTimeoutError(`${what} timed out`));
        client.close();
      }, ms);
      request.then(
        (value) => {
          this.clock.clearTimeout(timer);
          resolve(value);
        },
        (error) => {
          this.clock.clearTimeout(timer);
          reject(error);
        },
      );
    });
  }

  /**
   * A daemon read the inbox waits for. An owner refusal (a reject with a
   * reason) skips that read (`fetch_refused`, no reconnect); any other
   * failure drops the connection, and the reconnect catches up again.
   */
  private read<T>(daemon: DaemonClient, conversation: string | undefined, request: Promise<T>, input: (value: T) => Input): void {
    request.then(
      (value) => this.feed(input(value)),
      (error) => {
        if (error instanceof DaemonError) {
          this.feed({ kind: "fetch_refused", ...(conversation === undefined ? {} : { conversation }), reason: error.message });
          return;
        }
        this.log(`daemon read failed: ${String(error)}; reconnecting`);
        daemon.close();
      },
    );
  }

  /**
   * A prompt. Its request answers when the turn ends, which has no bound; the
   * acknowledgment (`_acpmux/prompt_accepted`, sent as soon as acpmux records
   * the prompt) has the request deadline. A missing acknowledgment closes the
   * connection (the prompt is sent again on the next connect). A refusal by
   * acpmux is `prompt_settled {rejected}`: the core retries it on the clock.
   */
  private prompt(acpmux: AcpmuxClient | undefined, promptId: string, text: string): void {
    const session = this.core.state.muxSessionId;
    if (!acpmux || !session) return;
    const ms = this.requestTimeoutMs;
    this.clock.clearTimeout(this.promptAcks.get(promptId)?.timer);
    const timer = this.clock.setTimeout(() => {
      this.promptAcks.delete(promptId);
      this.log(`prompt ${promptId} got no acknowledgment in ${ms} ms; reconnecting`);
      acpmux.close();
    }, ms);
    this.promptAcks.set(promptId, { timer, acpmux });
    acpmux
      .prompt(session, text, { promptId, delivery: "turn" })
      .then(
        () => ({ rejected: false }),
        (error) => {
          const rejected = error instanceof AcpmuxError && !(error instanceof AcpmuxClosedError);
          const next = rejected ? "the core retries it" : "resent on the next acpmux connect";
          this.log(`prompt ${promptId} failed: ${String(error)}; ${next}`);
          return { rejected };
        },
      )
      .then(({ rejected }) => {
        this.acknowledged(promptId, acpmux);
        this.feed({ kind: "prompt_settled", prompt_id: promptId, ...(rejected ? { rejected: true } : {}) });
      });
  }

  /** The prompt's acknowledgment arrived (or its request settled) on `acpmux`: its deadline ends. */
  private acknowledged(promptId: string, acpmux: AcpmuxClient): void {
    const pending = this.promptAcks.get(promptId);
    if (pending?.acpmux !== acpmux) return;
    this.clock.clearTimeout(pending.timer);
    this.promptAcks.delete(promptId);
  }

  // MARK: daemon

  private async runDaemon(): Promise<void> {
    // Events that arrive before the core knows the connection are held, then fed after it.
    let held: Record<string, unknown>[] | undefined = [];
    const daemon = await this.connectWithin("daemon", (signal) =>
      DaemonClient.connect(this.options.daemonSocket, {
        subscribe: true,
        signal,
        onEvent: (event) => {
          if (held) held.push(event);
          else this.onDaemonEvent(daemon, event);
        },
      }),
    );
    const closed = new Promise<void>((resolve) => daemon.onClose(() => resolve()));
    try {
      const { conversation } = await this.timed(
        daemon,
        "daemon",
        "create",
        daemon.create({
          idempotency_key: DEFAULT_CONVERSATION_KEY,
          actor: USER_LOCAL,
          title: "mux",
          participants: this.defaultParticipants(),
        }),
      );
      // Read at every connect: the app mints a new token on each launch.
      const token = typeof this.options.agentToken === "function" ? this.options.agentToken() : this.options.agentToken;
      if (token) await this.timed(daemon, "daemon", "bind", daemon.bind(AGENT_MUX, token));
      this.daemon = daemon;
      this.log(`daemon connected (${daemon.identity.app ?? "?"} ${daemon.identity.version ?? ""}); conversation ${conversation.id}`);
      this.upAt.set("daemon", this.clock.nowMs());
      this.feed({ kind: "daemon_connected", conversation });
      const queued = held;
      held = undefined;
      for (const event of queued) this.onDaemonEvent(daemon, event);
      await Promise.race([closed, this.stoppedSignal]);
    } finally {
      daemon.close();
      if (this.daemon === daemon) {
        this.daemon = undefined;
        this.feed({ kind: "disconnected", port: "daemon" });
      }
    }
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
    if (event.event !== "conversation-changed" || this.daemon !== daemon) return;
    const changed = event as unknown as ConversationChangedEvent;
    this.feed({ kind: "conversation_changed", conversation: changed.conversation, change: changed.change });
  }

  // MARK: acpmux

  private async runAcpmux(): Promise<void> {
    await this.options.startAcpmux?.();
    const acpmux = await this.connectWithin("acpmux", (signal) =>
      AcpmuxClient.connect(this.options.acpmuxSocket, "mux-host", signal),
    );
    const closed = new Promise<void>((resolve) => acpmux.onClose(() => resolve()));
    // The connect sequence (sessions, watch, first event, attach) has one deadline:
    // a stuck step closes the client and the loop connects again.
    const ms = this.requestTimeoutMs;
    const deadline = this.clock.setTimeout(() => {
      this.log(`acpmux connect got no answer in ${ms} ms; reconnecting`);
      acpmux.close();
    }, ms);
    // Notifications that arrive while attach replays are held, then fed after it.
    let held: Notification[] | undefined = [];
    acpmux.onNotification((n) => {
      if (held) held.push(n);
      else this.onAcpmuxNotification(n, acpmux);
    });
    try {
      const { sessionId, created } = await this.ensureMuxSession(acpmux);
      // The session list from the watch call itself has no gap to the change
      // notifications; an acpmux that does not return one is listed after watch.
      const watched = (await acpmux.watch(true)) as { sessions?: unknown } | undefined;
      const listed = watched?.sessions;
      const sessions = Array.isArray(listed) ? (listed as SessionSummary[]) : await acpmux.sessions();
      // The log's identity is the `at` of its seq 1 event. A log host.json does
      // not know (another session, or another identity) replays from 0; the core
      // decides the reset and the reply-key epoch (core.ts acpmuxConnected).
      // A failed fetch fails the connect (the loop retries): an unknown identity would decide a reset wrongly.
      const [firstEvent] = await acpmux.events(sessionId, 0, 1);
      const firstAt: unknown = firstEvent?.at;
      const logId = isCount(firstAt) ? firstAt : undefined;
      const state = this.core.state;
      // A host.json without acpmuxLog (from before it existed) adopts this identity: no replay from 0.
      const known =
        state.muxSessionId === sessionId &&
        (logId === undefined || state.acpmuxLog === undefined || logId === state.acpmuxLog);
      const { events, cursorReset } = await this.attach(acpmux, sessionId, known ? state.acpmuxSeq : 0);
      this.clock.clearTimeout(deadline);
      this.acpmux = acpmux;
      this.log(`acpmux connected; mux session ${sessionId} (${events.length} events replayed)`);
      this.upAt.set("acpmux", this.clock.nowMs());
      this.feed({
        kind: "acpmux_connected",
        session_id: sessionId,
        sessions,
        events,
        ...(cursorReset ? { cursor_reset: true } : {}),
        ...(logId === undefined ? {} : { log_id: logId }),
        ...(created ? { created: true } : {}),
      });
      const queued = held;
      held = undefined;
      for (const n of queued) this.onAcpmuxNotification(n, acpmux);
      await Promise.race([closed, this.stoppedSignal]);
    } finally {
      this.clock.clearTimeout(deadline);
      acpmux.close();
      if (this.acpmux === acpmux) {
        this.acpmux = undefined;
        this.feed({ kind: "disconnected", port: "acpmux" });
      }
    }
  }

  private async attach(
    acpmux: AcpmuxClient,
    sessionId: string,
    after: number,
  ): Promise<{ events: AcpmuxEvent[]; cursorReset: boolean }> {
    try {
      return { events: (await acpmux.attach(sessionId, after)).events, cursorReset: false };
    } catch (error) {
      // The log is shorter than the saved cursor (a re-imported session): replay it all. The core
      // treats this as a reset: the replay posts no promptless turn and reply keys get a new epoch.
      if (after === 0 || !String(error).includes("cursor_future")) throw error;
      return { events: (await acpmux.attach(sessionId, 0)).events, cursorReset: true };
    }
  }

  /** The `mux` acpmux session, created with the mux's cwd, harness and policy when missing. */
  /** The `mux` session id, and whether this call created it (a new log). */
  private async ensureMuxSession(acpmux: AcpmuxClient): Promise<{ sessionId: string; created: boolean }> {
    const existing = (await acpmux.sessions()).find((s) => s.name === MUX_SESSION_NAME);
    if (existing) return { sessionId: existing.sessionId, created: false };
    const { sessionId } = await acpmux.newSession({
      cwd: this.options.paths.session,
      name: MUX_SESSION_NAME,
      harness: this.options.harness,
      policy: this.options.policy,
      mcpServers: this.options.mcpServers,
    });
    this.log(`created acpmux session ${MUX_SESSION_NAME} (${this.options.harness})`);
    return { sessionId, created: true };
  }

  private onAcpmuxNotification(n: Notification, acpmux?: AcpmuxClient): void {
    if (n.method === "_acpmux/prompt_accepted") {
      const promptId = n.params.promptId;
      if (typeof promptId === "string" && acpmux) this.acknowledged(promptId, acpmux);
    } else if (n.method === "_acpmux/event") {
      this.feed({ kind: "acpmux_event", event: n.params as unknown as AcpmuxEvent });
    } else if (n.method === "session/update") {
      this.feed({ kind: "acpmux_event", event: eventFromUpdate(n.params) });
    } else if (n.method === "_acpmux/session_changed") {
      const session = n.params.session as SessionSummary | undefined;
      if (session) this.feed({ kind: "session_changed", session });
    } else if (n.method === "_acpmux/permission_pending") {
      const params = n.params as { sessionId: string; permissionId: string; request?: Record<string, unknown> };
      this.feed({
        kind: "permission_pending",
        session_id: params.sessionId,
        permission_id: params.permissionId,
        request: params.request ?? {},
      });
    }
  }
}
