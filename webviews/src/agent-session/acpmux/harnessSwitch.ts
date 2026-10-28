import { errorMessage, isHostRefusal } from "./transportErrors";
import type { ComposerAttachment } from "./attachments";
import { agentName } from "./agents";
import { harnessProfiles, type HarnessProfiles } from "./harnessProfiles";
import { lastModel } from "./lastPick";
import { heldOptionPick } from "./heldOptions";
import { isTrustRefusal } from "./direct";
// Outside render: the store reads the pane language when it builds a string.
import { translate as t } from "./i18n";
import { askStartMode, exactStartMode, onStartModeAskAgain, onStartModeKept } from "./startMode";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

// A harness or model switch as an intent. The pick changes the
// picker, the composer and the session header in the frame it happens: the store records it and
// the pane draws the snapshot through `applySwitch`. acpmux's work (start or reuse an adapter,
// session/new, attach, then the picked model, mode and options) runs behind it. Prompts sent
// before the new session is ready queue on the intent, drawn as the user's message with a quiet
// "Starting Codex…" on it, and go out in order once it is. A newer pick replaces an older one
// (its session, if acpmux already started one, is discarded); a failure hands the queued prompts
// back to the composer, marks the harness in the picker, and offers Retry. While a turn streams,
// a harness pick applies to the next turn: the stream keeps drawing and the next prompt opens the
// new chat. The store outlives a connection, so a reconnect resumes the switch on the new client.
//
// TODO(intents): port onto the IntentStore (webviews/src/protocol/intents, hq48-zero-latency,
// plans/cmux-next/zero-latency.md) once it lands on feat-cmux-next. The plan: one resource,
// "session", so its per-resource FIFO orders the switch before the prompts and picks made during
// it. Kinds: `harness.switch` (apply: the target harness on a new chat; op: leave, session/new,
// attach; supersede and abortSuperseded, an aborted op discarding the session it started),
// `prompt.send` (apply: the queued row; the op resolves once session/prompt is written, not at
// turn end, so later prompts and picks are not held for a turn; onPriorRefused "cancel", whose
// cancellation hands text and attachments back to the composer), `model.set`, `mode.set`,
// `config.set` (apply: the chip; base from the session summary through resync on every client
// snapshot; confirm "event" retired by `receive` when the summary reports the picked value,
// because acpmux echoes no opid). The client is the IntentSender, with link loss mapped to
// ProtocolErrorCode.closed so setSender on reconnect resends. What stays outside the store:
// the deferred phase while a turn streams (the switch op holds the attach until the next
// prompt), the reuse of the empty chat just left, and the prewarm hint.

type Catalog = AcpmuxSnapshot["catalog"];
type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

/// What the store needs from the connected acpmux client (direct.ts implements it).
export type SwitchPort = {
  /// A turn is running in the session the pane shows.
  turnRunning(): boolean;
  /// The shown session: its id, its harness, whether it has nothing in it yet, its folder when a
  /// new chat can start there, and the config options it names (once attached).
  shown():
    | {
        sessionId: string;
        harness?: string;
        model?: string;
        empty: boolean;
        cwd?: string;
        configOptions?: readonly {
          id: string;
          name?: string | null;
          category?: string | null;
          options?: readonly { value: string }[];
        }[];
      }
    | undefined;
  /// `session/new` on `harness`; does not show it.
  create(harness: string, cwd?: string): Promise<string | undefined>;
  /// Stops showing the current session (the pane draws the new chat meanwhile).
  leave(): void;
  /// Shows and attaches `sessionId`; undefined when a newer selection won.
  open(sessionId: string): Promise<string | undefined>;
  /// Sends a prompt to the shown session, its optimistic row keyed by `promptId`.
  send(text: string, attachments: ComposerAttachment[], promptId: string): Promise<unknown>;
  setModel(modelId: string): Promise<void>;
  /// `ticket`: the single-use gesture ticket the pick took (transport.gesture), sent with its frame.
  setMode(modeId: string, ticket?: string): Promise<void>;
  setConfig(configId: string, value: string, ticket?: string): Promise<void>;
  /// Ends a session a superseded switch started and nobody used.
  discard(sessionId: string): void;
  /// Tells acpmux a harness is likely next in `cwd`, so its pool can ready a session. A no-op
  /// without support or over a remote-origin connection; never awaited.
  prewarm(harness: string, cwd?: string): void;
  /// The connection can take a prewarm hint (acpmux lists the method and calls it local).
  prewarmSupported(): boolean;
  /// A new chat starts only with its first send (a chat on another machine, cx-k21v): a pick
  /// before it is remembered, and the send starts the session.
  startsOnSend?(): boolean;
};

/// Injected time, so the debounce is testable and the store never keeps a timer while idle.
export type SwitchClock = { now(): number; schedule(run: () => void, ms: number): () => void };
export const browserSwitchClock: SwitchClock = {
  now: () => (typeof performance === "undefined" ? Date.now() : performance.now()),
  schedule: (run, ms) => {
    const timer = setTimeout(run, ms);
    return () => clearTimeout(timer);
  },
};

/// How long the pointer or keyboard rests on a harness before the prewarm hint goes out.
export const PREWARM_DEBOUNCE_MS = 150;
/// The same harness hinted again this soon after its last hint is not sent again (acpmux keeps
/// only the newest hint, so a harness hinted after another one always goes out).
export const PREWARM_REPEAT_MS = 30_000;

export type SwitchConfig = { model?: string; mode?: string; options: Readonly<Record<string, string>> };
export type QueuedSwitchPrompt = { id: string; text: string; at: number };

/// The switch as the pane draws it. A new object on every change (useSyncExternalStore).
export type SwitchView = {
  intent?: {
    id: number;
    harness: string;
    /// Starting: acpmux has not started the session yet. Waiting: it has, and the pane waits for
    /// the next prompt (a turn was streaming at the pick). Failed: it could not start. Trust:
    /// acpmux waits for the folder's trust answer; the switch keeps its prompts until then.
    phase: "starting" | "waiting" | "failed" | "trust";
    /// The pane draws the new chat (false while the old session's turn still streams).
    shown: boolean;
    sessionId?: string;
    error?: string;
    queued: readonly QueuedSwitchPrompt[];
    config: SwitchConfig;
    cwd?: string;
  };
  /// A model picked in a live session, drawn until the session reports a model change.
  model?: { sessionId: string; from?: string; model: string };
  /// A config option picked in a live session, drawn until the session reports the value.
  config?: { sessionId: string; configId: string; from?: string; value: string };
};

type Queued = QueuedSwitchPrompt & {
  attachments: ComposerAttachment[];
  /// The prompt is on the wire (a Quick Composer may close once it is).
  written?(): void;
  resolve(value: unknown): void;
  reject(error: unknown): void;
};

type Intent = {
  id: number;
  harness: string;
  cwd?: string;
  shown: boolean;
  phase: "starting" | "waiting" | "failed" | "trust";
  sessionId?: string;
  /// The session was the one the pane left (empty, same harness): reused, never discarded.
  reused?: boolean;
  error?: string;
  queued: Queued[];
  config: { model?: string; mode?: string; options: Record<string, string> };
  /// Each held mode or config pick's gesture ticket (`mode`, `config:<id>`), the newest pick's.
  tickets: Map<string, Promise<string | undefined>>;
  /// The port a run is in flight on; a reconnect runs again on the new one.
  running?: SwitchPort;
  done: { resolve(sessionId: string | undefined): void; promise: Promise<string | undefined> };
};

/// The frame a gesture ticket redeems for (ad349, pane-native transport).
export type GestureIntent =
  | { method: "session/set_mode"; params: { modeId: string } }
  | { method: "session/set_config_option"; params: { configId: string; value: string } };

export type SwitchHandlers = {
  /// Puts prompts a failed or cancelled switch held back into the composer: their text, joined
  /// in order, and every attachment they carried, as they were.
  restore?(text: string, attachments: ComposerAttachment[]): void;
  /// A switch's session opened (the host persists it as the tab's session).
  opened?(sessionId: string): void;
  /// A pick the agent refused (a model it would not switch to).
  notice?(text: string): void;
  /// Spends the user's pick gesture with the host (`transport.gesture`) and resolves to its
  /// single-use ticket, bound to `intent`: the exact frame the pick sends later (its method, and
  /// its params without sessionId and _meta). Called in the pick's own handler, while the gesture
  /// is live; a refusal means there was none, and the pick applies without a ticket.
  gesture?(intent: GestureIntent): Promise<string | undefined>;
  /// Keeps the send's gesture for a prompt the switch holds behind the folder's trust question,
  /// so the prompt still goes after Trust (heldPrompt.ts): bound to its `promptId`.
  holdPrompt?(promptId: string): void;
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { resolve, promise };
}

const errorText = errorMessage;

export class HarnessSwitch {
  private intent?: Intent;
  private modelPick?: SwitchView["model"];
  private configPick?: SwitchView["config"];
  private port?: SwitchPort;
  private generation = 0;
  private current: SwitchView = {};
  private listeners = new Set<() => void>();
  /// The session the pane left for the current intent, when it was empty: switching back reuses it.
  private left?: { sessionId: string; harness?: string };
  private hintTarget?: string;
  private cancelHint?: () => void;
  private lastHint?: { harness: string; at: number };
  private handlers: SwitchHandlers = {};

  constructor(private readonly clock: SwitchClock = browserSwitchClock) {
    // A pending chat's access chip draws acpmux's kept answer (`applySwitch`): it asks again when
    // the answer may have changed, and draws again when a kept answer changed.
    onStartModeAskAgain(() => {
      const intent = this.intent;
      if (intent && !intent.reused) void askStartMode(intent.harness, intent.cwd);
    });
    onStartModeKept(() => {
      if (this.intent) this.changed();
    });
  }

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  readonly view = (): SwitchView => this.current;

  /// Drops a live config pick once the host echoes the selected value. Keeping this in the
  /// switch store prevents a late or reconnect snapshot from being masked by an old optimistic
  /// value.
  reconcile(snapshot: AcpmuxSnapshot): void {
    const pick = this.configPick;
    if (!pick || snapshot.sessionId !== pick.sessionId) return;
    const option = snapshot.summary?.configOptions?.find((item) => item.id === pick.configId);
    if (option?.currentValue !== pick.value) return;
    this.configPick = undefined;
    this.changed();
  }

  /// What the pane does with prompts handed back, opened sessions and refused picks.
  setHandlers(handlers: SwitchHandlers): void {
    this.handlers = handlers;
  }

  /// The client the switch runs on. A switch waiting on a connection runs now.
  connect(port: SwitchPort): void {
    this.port = port;
    const intent = this.intent;
    // A chat on another machine whose start answered on a connection that dropped: the new
    // connection already shows that chat (empty, same agent), so the switch takes it instead of
    // starting again, which the machine refuses (a false failure, cx-k21v).
    if (intent && !intent.sessionId && port.startsOnSend?.()) {
      const shown = port.shown();
      if (shown?.empty && (!shown.harness || shown.harness === intent.harness)) intent.sessionId = shown.sessionId;
    }
    if (intent && intent.phase !== "failed" && intent.phase !== "trust" && !intent.running) void this.run(intent);
  }
  /// The connection dropped: whatever was in flight runs again on the next client.
  disconnect(port?: SwitchPort): void {
    if (port && this.port !== port) return;
    this.port = undefined;
    if (this.intent) this.intent.running = undefined;
  }

  /// Picks `harness` for a new chat, in `cwd`, else in the shown chat's folder (the switch keeps
  /// the project). Draws it now; resolves with the session once it opens (undefined when a newer
  /// pick or a cancel replaced it, or it failed). `deferred`: the pane stays where it is (the New
  /// Tab page, cx-e2aa) and the new chat shows with the next prompt, as a pick during a turn does.
  /// `model`: a model row of `harness` was picked; the new chat starts on it and draws it now.
  /// `options`: config picks made with it (a typed combo's effort and Fast, under their kind's id,
  /// heldOptions.ts), held as a pick during the switch is: applied before the first prompt.
  switchTo(
    harness: string,
    folder?: string,
    options: { deferred?: boolean; model?: string; options?: Readonly<Record<string, string>> } = {},
  ): Promise<string | undefined> {
    const previous = this.intent;
    const port = this.port;
    const shownSession = port?.shown();
    const cwd = folder ?? previous?.cwd ?? shownSession?.cwd;
    const held = Object.entries(options.options ?? {});
    if (previous && previous.harness === harness && previous.phase !== "failed" && previous.cwd === cwd) {
      if (options.model) void this.pickModel(options.model);
      for (const [configId, value] of held) this.pickConfig(configId, value);
      return previous.done.promise;
    }
    // While the shown session's turn streams (or the pane holds a page), the pick applies to the next turn.
    const shown = options.deferred ? false : (previous?.shown ?? !(port?.turnRunning() ?? false));
    // Back to the harness of the session still on screen: there is nothing left to switch. The
    // pick's held options are not sent from here: that session is live, and the composer sends a
    // combo's effort and Fast to it once it reports the picked model (ComposerPickers `crossing`),
    // as a combo in a running chat does. Sending them here as well raced that, and a write still in
    // flight when the model reported went out twice.
    if (!shown && previous && shownSession?.harness === harness) {
      this.cancel();
      if (options.model && options.model !== shownSession.model)
        void this.pickModel(options.model, { sessionId: shownSession.sessionId, model: shownSession.model });
      return Promise.resolve(shownSession.sessionId);
    }
    const done = deferred<string | undefined>();
    const model = options.model ?? (previous?.harness === harness ? previous.config.model : undefined);
    const intent: Intent = {
      id: ++this.generation,
      harness,
      cwd,
      shown,
      phase: "starting",
      queued: previous?.queued ?? [],
      // A model or mode picked for one harness does not carry to another; to another folder it does.
      config: {
        ...(previous?.harness === harness ? previous.config : { options: {} }),
        // A model row of this harness picked it, or the caller passed the one last picked on it
        // (`lastOfferedModel`): the new chat starts on that model.
        ...(model ? { model } : {}),
      },
      tickets: previous?.harness === harness ? previous.tickets : new Map(),
      done,
    };
    if (previous) this.retire(previous, false);
    this.modelPick = undefined;
    this.configPick = undefined;
    this.intent = intent;
    // Each held option takes its gesture ticket now, in the pick's own handler.
    for (const [configId, value] of held) this.holdConfig(intent, configId, value);
    if (shown && shownSession && !previous) {
      this.left = shownSession.empty ? { sessionId: shownSession.sessionId, harness: shownSession.harness } : undefined;
      port?.leave();
    }
    // Back to the empty chat the pane just left on that harness: it is reused as it is.
    if (shown && this.left && this.left.harness === harness) {
      intent.sessionId = this.left.sessionId;
      intent.reused = true;
    }
    this.cancelHintTimer();
    this.changed();
    // Before session/new: acpmux's answer as its rules stand when the chat is asked for.
    if (!intent.reused) void askStartMode(intent.harness, intent.cwd);
    void this.run(intent);
    return done.promise;
  }

  /// A prompt sent from the composer. Returns undefined when no switch holds it (the caller sends
  /// it as usual), else a promise that settles as the send would.
  /// `promptId`: a seeded prompt's own id (its host ticket is bound to it, cx-k21v gap 4).
  send(
    text: string,
    attachments: ComposerAttachment[] = [],
    written?: () => void,
    promptId?: string,
  ): Promise<unknown> | undefined {
    let intent = this.intent;
    if (!intent) return undefined;
    // After a failure, sending is retrying with this prompt.
    if (intent.phase === "failed") {
      void this.switchTo(intent.harness, intent.cwd, { deferred: !intent.shown });
      intent = this.intent!;
    }
    const { promise, resolve, reject } = (() => {
      let resolve!: (value: unknown) => void;
      let reject!: (error: unknown) => void;
      const promise = new Promise<unknown>((done, fail) => {
        resolve = done;
        reject = fail;
      });
      return { promise, resolve, reject };
    })();
    const id = promptId ?? crypto.randomUUID();
    intent.queued = [...intent.queued, { id, text, attachments, at: Date.now(), resolve, reject, written }];
    // A prompt sent while the switch waits for the trust answer keeps this send's gesture for
    // after Trust (the first held prompt only: one ticket per send).
    if (intent.phase === "trust" && intent.queued.length === 1) this.handlers.holdPrompt?.(id);
    if (!intent.shown) {
      // The pick waited for this prompt: the pane moves to the new chat now.
      intent.shown = true;
      this.port?.leave();
    }
    this.changed();
    if ((intent.sessionId || this.port?.startsOnSend?.()) && !intent.running) void this.run(intent);
    return promise;
  }

  /// A model pick. While a switch is pending it is recorded for the new session; in a live
  /// session it draws at once and goes to the agent, reverting if the agent refuses it. Resolves
  /// whether the pick holds: false when the agent refused it or there was no session to take it.
  pickModel(model: string, live?: { sessionId: string; model?: string }): Promise<boolean> {
    const intent = this.intent;
    if (intent) {
      intent.config = { ...intent.config, model };
      this.changed();
      return Promise.resolve(true);
    }
    const port = this.port;
    if (!port || !live) return Promise.resolve(false);
    const pick = { sessionId: live.sessionId, from: live.model, model };
    this.modelPick = pick;
    this.configPick = undefined;
    this.changed();
    return port.setModel(model).then(
      () => true,
      (error) => {
        if (this.modelPick !== pick) return false;
        this.modelPick = undefined;
        this.changed();
        this.handlers.notice?.(t("switch.modelFailed", { model, reason: errorText(error) || "?" }));
        return false;
      },
    );
  }
  /// A permission mode or config option picked while a switch is pending; false otherwise.
  /// A held pick takes a gesture ticket at once (pane-native transport); a live pick needs none.
  pickMode(mode: string): boolean {
    if (!this.intent) return false;
    this.intent.config = { ...this.intent.config, mode };
    this.intent.tickets.set("mode", this.takeTicket({ method: "session/set_mode", params: { modeId: mode } }));
    this.changed();
    return true;
  }
  pickConfig(configId: string, value: string, live?: { sessionId: string; current?: string }): boolean {
    if (!this.intent) {
      const port = this.port;
      if (!port || !live) return false;
      const pick = { sessionId: live.sessionId, configId, from: live.current, value };
      this.configPick = pick;
      this.modelPick = undefined;
      this.changed();
      void port.setConfig(configId, value).catch((error) => {
        if (this.configPick !== pick) return;
        this.configPick = undefined;
        this.changed();
        this.handlers.notice?.(t("switch.modelFailed", { model: value, reason: errorText(error) || "?" }));
      });
      return true;
    }
    this.holdConfig(this.intent, configId, value);
    this.changed();
    return true;
  }

  /// Records a config pick on `intent` for its session, with the pick's gesture ticket.
  private holdConfig(intent: Intent, configId: string, value: string): void {
    intent.config = { ...intent.config, options: { ...intent.config.options, [configId]: value } };
    intent.tickets.set(
      `config:${configId}`,
      this.takeTicket({ method: "session/set_config_option", params: { configId, value } }),
    );
  }

  private takeTicket(intent: GestureIntent): Promise<string | undefined> {
    const gesture = this.handlers.gesture;
    if (!gesture) return Promise.resolve(undefined);
    try {
      return gesture(intent).catch(() => undefined);
    } catch {
      return Promise.resolve(undefined);
    }
  }

  /// Cancel on a queued prompt: it leaves the queue and goes back to the composer. The harness
  /// keeps starting.
  cancelQueued(id: string): void {
    const intent = this.intent;
    const prompt = intent?.queued.find((candidate) => candidate.id === id);
    if (!intent || !prompt) return;
    intent.queued = intent.queued.filter((candidate) => candidate !== prompt);
    this.handlers.restore?.(prompt.text, prompt.attachments);
    // Back in the composer (`handedBack`): the sender puts nothing back.
    prompt.reject(Object.assign(new Error(t("switch.cancelled")), { handedBack: true }));
    this.changed();
  }

  /// After the folder's Trust answer: the switch that waited for it starts the same harness in the
  /// same folder now, and sends the prompts it kept, once (the trust route's re-run, direct.ts).
  resumeAfterTrust(): void {
    const intent = this.intent;
    if (intent?.phase !== "trust") return;
    intent.phase = "starting";
    this.changed();
    void this.run(intent);
  }

  /// Retry after a failure: starts the harness again (the prompt stays in the composer).
  retry(): void {
    const intent = this.intent;
    if (intent?.phase === "failed") void this.switchTo(intent.harness, intent.cwd, { deferred: !intent.shown });
  }

  /// The user went elsewhere (another session, a fork, a default new chat): the switch ends and
  /// its queued prompts go back to the composer.
  /// The New Tab page closed (cx-e2aa): a switch a pick started behind it, never shown because no
  /// prompt went, ends and its session is discarded. A shown switch is the chat's own.
  cancelDeferred(): void {
    if (this.intent && !this.intent.shown) this.cancel();
  }

  cancel(): void {
    const intent = this.intent;
    if (intent) {
      this.intent = undefined;
      this.retire(intent, true);
    }
    this.modelPick = undefined;
    this.configPick = undefined;
    this.left = undefined;
    this.changed();
  }

  /// The highlight rests on `harness` in the picker (the pointer, the arrows, or the choices
  /// opening on it). Debounced; a repeat of the last hint within PREWARM_REPEAT_MS and the
  /// harness the pane already runs are not sent. The hint names the folder a switch would use.
  hint(harness: string | undefined): void {
    if (harness === this.hintTarget) return;
    this.cancelHintTimer();
    this.hintTarget = harness;
    // A connection that cannot prewarm (remote origin, no _acpmux/prewarm) starts no timer.
    if (!harness || !this.port?.prewarmSupported()) return;
    this.cancelHint = this.clock.schedule(() => {
      this.cancelHint = undefined;
      const port = this.port;
      if (!port || this.hintTarget !== harness) return;
      const shown = port.shown();
      const running = this.intent?.harness ?? shown?.harness;
      if (harness === running) return;
      const now = this.clock.now();
      const last = this.lastHint;
      if (last?.harness === harness && now - last.at < PREWARM_REPEAT_MS) return;
      this.lastHint = { harness, at: now };
      port.prewarm(harness, this.intent?.cwd ?? shown?.cwd);
    }, PREWARM_DEBOUNCE_MS);
  }

  private cancelHintTimer(): void {
    this.cancelHint?.();
    this.cancelHint = undefined;
  }

  /// Ends `intent`: discards the session it started that nobody opened, settles what waits on it.
  private retire(intent: Intent, restoreQueued: boolean): void {
    if (intent.sessionId && !intent.reused && intent.phase !== "failed") this.port?.discard(intent.sessionId);
    intent.sessionId = undefined;
    if (restoreQueued && intent.queued.length) {
      this.handBack(intent.queued);
      for (const prompt of intent.queued)
        prompt.reject(Object.assign(new Error(t("switch.cancelled")), { handedBack: true }));
      intent.queued = [];
    }
    intent.done.resolve(undefined);
  }

  private async run(intent: Intent): Promise<void> {
    const port = this.port;
    if (!port || intent.running) return;
    let sessionId = intent.sessionId;
    // A chat on another machine starts with the first send, never with a pick (cx-k21v).
    if (!sessionId && intent.queued.length === 0 && port.startsOnSend?.()) return;
    intent.running = port;
    if (!sessionId) {
      try {
        sessionId = await port.create(intent.harness, intent.cwd);
      } catch (error) {
        if (intent.running === port) intent.running = undefined;
        // A dropped connection is not a failure: the next client runs it again.
        if (this.intent !== intent || this.port !== port) return;
        this.fail(intent, error);
        return;
      }
      if (this.intent !== intent) {
        if (sessionId) port.discard(sessionId);
        return;
      }
      if (!sessionId) {
        intent.running = undefined;
        this.fail(intent, new Error(t("switch.noSession")));
        return;
      }
      intent.sessionId = sessionId;
    }
    if (!intent.shown) {
      intent.running = undefined;
      intent.phase = "waiting";
      this.changed();
      return;
    }
    let opened: string | undefined;
    try {
      opened = await port.open(sessionId);
    } catch (error) {
      if (intent.running === port) intent.running = undefined;
      if (this.intent !== intent || this.port !== port) return;
      this.fail(intent, error);
      return;
    }
    if (this.intent !== intent) return;
    if (!opened) {
      intent.running = undefined;
      if (this.port === port) this.fail(intent, new Error(t("switch.noSession")));
      return;
    }
    this.left = undefined;
    this.handlers.opened?.(opened);
    // What was picked while acpmux started the harness, one request at a time, in pick order of kind.
    const { model, mode, options } = intent.config;
    const applied: Promise<void>[] = [];
    if (model) applied.push(port.setModel(model).catch((error) => this.refused(model, error)));
    // A pick the host refuses (a transport refusal) says so; any other refusal stays quiet, as before.
    const pickRefused = (error: unknown) => {
      if (isHostRefusal(error)) this.handlers.notice?.(errorMessage(error));
    };
    const ticket = (key: string) => intent.tickets.get(key) ?? Promise.resolve(undefined);
    // A pick held before the session named its options (a New Tab combo's effort or Fast) goes under
    // the opened session's own option id and value; one it offers no option or no such value for is
    // not sent, and a session that reports an empty list takes none. A session whose attach carried
    // no list at all (an older acpmux, a port that cannot read it) has said nothing to resolve the
    // picks against: they go as they were held, as before, and the agent answers for them.
    const offered = port.shown()?.configOptions;
    // A held mode the agent refuses always says so: a company-managed Mac's Claude Code settings can
    // disable a mode, and the chat would otherwise run on another one with no reason given.
    if (mode)
      applied.push(
        ticket("mode")
          .then((t) => port.setMode(mode, t))
          .catch((error) => this.handlers.notice?.(t("switch.modeFailed", { mode, reason: errorText(error) || "?" }))),
      );
    for (const [configId, value] of Object.entries(options)) {
      const pick = offered ? heldOptionPick(configId, value, offered) : { configId, value };
      if (!pick) continue;
      // The pick's ticket is bound to the frame it was taken for: a renamed pick goes without it.
      const same = pick.configId === configId && pick.value === value;
      applied.push(
        ticket(`config:${configId}`)
          .then((t) => port.setConfig(pick.configId, pick.value, same ? t : undefined))
          .catch(pickRefused),
      );
    }
    // Prompts go out after the picks, so the first turn runs on what the user chose.
    await Promise.all(applied);
    if (this.intent !== intent) return;
    const queued = intent.queued;
    intent.queued = [];
    this.intent = undefined;
    for (const prompt of queued) {
      port.send(prompt.text, prompt.attachments, prompt.id).then(prompt.resolve, prompt.reject);
      prompt.written?.();
    }
    this.changed();
    intent.done.resolve(opened);
  }

  /// Prompts the composer gets back, with their attachments; nothing is lost.
  private handBack(prompts: Queued[]): void {
    this.handlers.restore?.(
      prompts.map((prompt) => prompt.text).join("\n\n"),
      prompts.flatMap((prompt) => prompt.attachments),
    );
  }

  private refused(model: string, error: unknown): void {
    this.handlers.notice?.(t("switch.modelFailed", { model, reason: errorText(error) || "?" }));
  }

  private fail(intent: Intent, error: unknown): void {
    // Trust is a separate binary decision in the pane: the one trust question owns the next step,
    // never a generic "Couldn't start" card with Retry. The switch keeps its harness, folder and
    // prompts and waits; Trust runs it again (`resumeAfterTrust`) and sends them once (cx-nn3e).
    if (isTrustRefusal(error)) {
      intent.phase = "trust";
      intent.error = undefined;
      // The Trust click's gesture goes to the answer; the prompt keeps its own send's gesture.
      const first = intent.queued[0];
      if (first) this.handlers.holdPrompt?.(first.id);
      this.changed();
      return;
    }
    intent.phase = "failed";
    intent.error = errorText(error) || t("switch.unknownError");
    if (intent.queued.length) {
      this.handBack(intent.queued);
      // The prompts are back in the composer (`handedBack`); acpmux's refusal reason rides along.
      const refusal = error as { reason?: unknown } | undefined;
      const reason = Object.assign(new Error(intent.error), {
        handedBack: true,
        ...(typeof refusal?.reason === "string" ? { reason: refusal.reason } : {}),
      });
      for (const prompt of intent.queued) prompt.reject(reason);
      intent.queued = [];
    }
    this.changed();
    intent.done.resolve(undefined);
  }

  private changed(): void {
    const intent = this.intent;
    this.current = {
      ...(intent && {
        intent: {
          id: intent.id,
          harness: intent.harness,
          phase: intent.phase,
          shown: intent.shown,
          sessionId: intent.sessionId,
          error: intent.error,
          queued: intent.queued.map(({ id, text, at }) => ({ id, text, at })),
          config: intent.config,
          cwd: intent.cwd,
        },
      }),
      ...(this.modelPick && { model: this.modelPick }),
      ...(this.configPick && { config: this.configPick }),
    };
    for (const listener of this.listeners) listener();
  }
}

/// The snapshot as the pane draws it under `view`. Without a switch it is `raw` (or `raw` with a
/// picked model drawn until the session reports a change). During one, the target harness's
/// composer comes from the session once it attaches, else from what that harness last reported
/// (harnessProfiles.ts), else from the catalog; queued prompts draw as the user's messages.
/// The model a new chat on `harness` in `folder` starts on before anything is picked: acpmux's
/// saved default or the profile's own model (`start`, acpmux start_defaults.rs), else the one last
/// picked on it here (lastPick.ts) while the harness still offers it, else acpmux's catalog
/// default, else what a session acpmux last started there reported, else its last session's, else
/// the catalog's first.
export function defaultModel(
  harness: string,
  catalog: Catalog,
  profiles: HarnessProfiles = harnessProfiles,
  folder?: string,
): string | undefined {
  const profile = profiles.get(harness);
  const start = catalog.find((entry) => entry.id === harness)?.start;
  // A saved default (acpmux defaults, or a pick acpmux saved) or the profile's own model wins over
  // this page's last pick: acpmux starts the chat on it.
  const decided = start?.modelSource === "saved" || start?.modelSource === "profile" ? start.model : undefined;
  return (
    decided ??
    lastOfferedModel(harness, catalog, folder) ??
    start?.model ??
    profile?.startModel ??
    profile?.model ??
    catalog.find((entry) => entry.id === harness)?.models[0]?.id
  );
}

/// The model last picked on `harness` in `folder` (lastPick.ts), while the harness still offers it.
export function lastOfferedModel(harness: string, catalog: Catalog, folder?: string): string | undefined {
  const picked = lastModel(harness, folder);
  const models = catalog.find((entry) => entry.id === harness)?.models ?? [];
  return picked && (models.length === 0 || models.some((model) => model.id === picked)) ? picked : undefined;
}

export function applySwitch(
  raw: AcpmuxSnapshot,
  view: SwitchView,
  catalog: Catalog = raw.catalog,
  profiles: HarnessProfiles = harnessProfiles,
): AcpmuxSnapshot {
  const intent = view.intent;
  if (!intent) {
    const pick = view.model;
    const summary = raw.summary;
    if (pick && summary && summary.sessionId === pick.sessionId && summary.model === pick.from)
      return { ...raw, summary: { ...summary, model: pick.model, confirmedModel: summary.model } };
    const config = view.config;
    if (!config || !summary || summary.sessionId !== config.sessionId) return raw;
    const option = summary.configOptions?.find((item) => item.id === config.configId);
    if (!option || option.currentValue === config.value) return raw;
    return {
      ...raw,
      summary: {
        ...summary,
        configOptions: summary.configOptions?.map((item) =>
          item.id === config.configId ? { ...item, currentValue: config.value } : item,
        ),
      },
    };
  }
  const name = agentName(intent.harness, catalog.find((entry) => entry.id === intent.harness)?.name);
  const attached = intent.shown && intent.sessionId !== undefined && raw.sessionId === intent.sessionId;
  const live = attached ? raw.summary : undefined;
  const profile = profiles.get(intent.harness);
  const config = intent.config;
  const predicted = config.model ?? live?.model ?? defaultModel(intent.harness, catalog, profiles, intent.cwd);
  // Before the session reports, the mode acpmux answers it will start the chat in
  // (`_acpmux/start_mode`, kept per harness and folder), never the mode the harness's last chat
  // ran, nor another folder's answer; none without an answer for this folder.
  const modes =
    live?.modes ??
    (profile?.modes && {
      ...profile.modes,
      currentModeId:
        raw.origin === "remote" || raw.origin === "peer"
          ? undefined
          : exactStartMode(intent.harness, intent.cwd)?.modeId,
    });
  const summary: Summary = {
    ...(live ?? { sessionId: "", turnCount: 0, cwd: raw.summary?.cwd ?? intent.cwd }),
    harness: intent.harness,
    model: predicted,
    // Nothing to confirm before a session: the composer sequences picks against what it draws.
    confirmedModel: live ? live.model : predicted,
    modes: modes && config.mode ? { ...modes, currentModeId: config.mode } : modes,
    configOptions: (live?.configOptions ?? profile?.configOptions)?.map((option) =>
      option.id in config.options ? { ...option, currentValue: config.options[option.id] } : option,
    ),
    promptCapabilities: live?.promptCapabilities ?? profile?.promptCapabilities,
  };
  const switching: NonNullable<AcpmuxSnapshot["switching"]> = {
    harness: intent.harness,
    name,
    phase: intent.phase === "failed" ? "failed" : intent.shown ? "starting" : "deferred",
    ...(intent.error && { error: intent.error }),
  };
  const status = t("switch.starting", { agent: name });
  const queued: AcpmuxRow[] = intent.queued.map((prompt) => ({
    id: `local-${prompt.id}`,
    // The sent prompt keeps this id as version 1, so its row draws again without the status.
    version: 0,
    at: prompt.at,
    kind: "user",
    text: prompt.text,
    pending: true,
    status,
    queued: prompt.id,
  }));
  if (!intent.shown || attached)
    return { ...raw, summary, switching, rows: queued.length ? [...raw.rows, ...queued] : raw.rows };
  return {
    ...raw,
    rows: queued,
    sessionId: undefined,
    summary,
    switching,
    isWorking: false,
    queue: [],
    permission: undefined,
    permissionGroups: raw.permissionGroups && { ...raw.permissionGroups, groups: [] },
    canLoadOlder: false,
    canFork: false,
    canHandoff: false,
    handoff: undefined,
    commands: [],
    missingSession: undefined,
    unavailable: undefined,
    missingReason: undefined,
  };
}
