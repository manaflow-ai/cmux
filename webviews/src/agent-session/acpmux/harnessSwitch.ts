import type { ComposerAttachment } from "./attachments";
import { agentName } from "./agents";
import { harnessProfiles, type HarnessProfiles } from "./harnessProfiles";
// Outside render: the store reads the pane language when it builds a string.
import { translate as t } from "./i18n";
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
  /// The shown session: its id, its harness, whether it has nothing in it yet, and its folder
  /// when a new chat can start there.
  shown(): { sessionId: string; harness?: string; empty: boolean; cwd?: string } | undefined;
  /// `session/new` on `harness`; does not show it.
  create(harness: string, cwd?: string): Promise<string | undefined>;
  /// Stops showing the current session (the pane draws the new chat meanwhile).
  leave(): void;
  /// Shows and attaches `sessionId`; undefined when a newer selection won.
  open(sessionId: string): Promise<string | undefined>;
  /// Sends a prompt to the shown session, its optimistic row keyed by `promptId`.
  send(text: string, attachments: ComposerAttachment[], promptId: string): Promise<unknown>;
  setModel(modelId: string): Promise<void>;
  setMode(modeId: string): Promise<void>;
  setConfig(configId: string, value: string): Promise<void>;
  /// Ends a session a superseded switch started and nobody used.
  discard(sessionId: string): void;
  /// Tells acpmux a harness is likely next, so it can warm its adapter. A no-op without support.
  prewarm(harness: string): void;
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
/// A harness hinted this recently is not hinted again.
export const PREWARM_REPEAT_MS = 30_000;

export type SwitchConfig = { model?: string; mode?: string; options: Readonly<Record<string, string>> };
export type QueuedSwitchPrompt = { id: string; text: string; at: number };

/// The switch as the pane draws it. A new object on every change (useSyncExternalStore).
export type SwitchView = {
  intent?: {
    id: number;
    harness: string;
    /// Starting: acpmux has not started the session yet. Waiting: it has, and the pane waits for
    /// the next prompt (a turn was streaming at the pick). Failed: it could not start.
    phase: "starting" | "waiting" | "failed";
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
  phase: "starting" | "waiting" | "failed";
  sessionId?: string;
  /// The session was the one the pane left (empty, same harness): reused, never discarded.
  reused?: boolean;
  error?: string;
  queued: Queued[];
  config: { model?: string; mode?: string; options: Record<string, string> };
  /// The port a run is in flight on; a reconnect runs again on the new one.
  running?: SwitchPort;
  done: { resolve(sessionId: string | undefined): void; promise: Promise<string | undefined> };
};

export type SwitchHandlers = {
  /// Puts prompts a failed or cancelled switch held back into the composer: their text, joined
  /// in order, and every attachment they carried, as they were.
  restore?(text: string, attachments: ComposerAttachment[]): void;
  /// A switch's session opened (the host persists it as the tab's session).
  opened?(sessionId: string): void;
  /// A pick the agent refused (a model it would not switch to).
  notice?(text: string): void;
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { resolve, promise };
}

const errorText = (error: unknown) =>
  error instanceof Error && error.message ? error.message : typeof error === "string" && error ? error : "";

export class HarnessSwitch {
  private intent?: Intent;
  private modelPick?: SwitchView["model"];
  private port?: SwitchPort;
  private generation = 0;
  private current: SwitchView = {};
  private listeners = new Set<() => void>();
  /// The session the pane left for the current intent, when it was empty: switching back reuses it.
  private left?: { sessionId: string; harness?: string };
  private hintTarget?: string;
  private cancelHint?: () => void;
  private hinted = new Map<string, number>();
  private handlers: SwitchHandlers = {};

  constructor(private readonly clock: SwitchClock = browserSwitchClock) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  readonly view = (): SwitchView => this.current;

  /// What the pane does with prompts handed back, opened sessions and refused picks.
  setHandlers(handlers: SwitchHandlers): void {
    this.handlers = handlers;
  }

  /// The client the switch runs on. A switch waiting on a connection runs now.
  connect(port: SwitchPort): void {
    this.port = port;
    const intent = this.intent;
    if (intent && intent.phase !== "failed" && !intent.running) void this.run(intent);
  }
  /// The connection dropped: whatever was in flight runs again on the next client.
  disconnect(port?: SwitchPort): void {
    if (port && this.port !== port) return;
    this.port = undefined;
    if (this.intent) this.intent.running = undefined;
  }

  /// Picks `harness` for a new chat, in `cwd`, else in the shown chat's folder (the switch keeps
  /// the project). Draws it now; resolves with the session once it opens (undefined when a newer
  /// pick or a cancel replaced it, or it failed).
  switchTo(harness: string, folder?: string): Promise<string | undefined> {
    const previous = this.intent;
    const port = this.port;
    const shownSession = port?.shown();
    const cwd = folder ?? previous?.cwd ?? shownSession?.cwd;
    if (previous && previous.harness === harness && previous.phase !== "failed" && previous.cwd === cwd)
      return previous.done.promise;
    // While the shown session's turn streams, the pick applies to the next turn.
    const shown = previous?.shown ?? !(port?.turnRunning() ?? false);
    // Back to the harness of the session still on screen: there is nothing left to switch.
    if (!shown && previous && shownSession?.harness === harness) {
      this.cancel();
      return Promise.resolve(shownSession.sessionId);
    }
    const done = deferred<string | undefined>();
    const intent: Intent = {
      id: ++this.generation,
      harness,
      cwd,
      shown,
      phase: "starting",
      queued: previous?.queued ?? [],
      // A model or mode picked for one harness does not carry to another.
      config: { options: {} },
      done,
    };
    if (previous) this.retire(previous, false);
    this.modelPick = undefined;
    this.intent = intent;
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
    void this.run(intent);
    return done.promise;
  }

  /// A prompt sent from the composer. Returns undefined when no switch holds it (the caller sends
  /// it as usual), else a promise that settles as the send would.
  send(text: string, attachments: ComposerAttachment[] = [], written?: () => void): Promise<unknown> | undefined {
    let intent = this.intent;
    if (!intent) return undefined;
    // After a failure, sending is retrying with this prompt.
    if (intent.phase === "failed") {
      void this.switchTo(intent.harness, intent.cwd);
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
    intent.queued = [
      ...intent.queued,
      { id: crypto.randomUUID(), text, attachments, at: Date.now(), resolve, reject, written },
    ];
    if (!intent.shown) {
      // The pick waited for this prompt: the pane moves to the new chat now.
      intent.shown = true;
      this.port?.leave();
    }
    this.changed();
    if (intent.sessionId && !intent.running) void this.run(intent);
    return promise;
  }

  /// A model pick. While a switch is pending it is recorded for the new session; in a live
  /// session it draws at once and goes to the agent, reverting if the agent refuses it.
  pickModel(model: string, live?: { sessionId: string; model?: string }): Promise<void> {
    const intent = this.intent;
    if (intent) {
      intent.config = { ...intent.config, model };
      this.changed();
      return Promise.resolve();
    }
    const port = this.port;
    if (!port || !live) return Promise.resolve();
    const pick = { sessionId: live.sessionId, from: live.model, model };
    this.modelPick = pick;
    this.changed();
    return port.setModel(model).catch((error) => {
      if (this.modelPick !== pick) return;
      this.modelPick = undefined;
      this.changed();
      this.handlers.notice?.(t("switch.modelFailed", { model, reason: errorText(error) || "?" }));
    });
  }
  /// A permission mode or config option picked while a switch is pending; false otherwise.
  pickMode(mode: string): boolean {
    if (!this.intent) return false;
    this.intent.config = { ...this.intent.config, mode };
    this.changed();
    return true;
  }
  pickConfig(configId: string, value: string): boolean {
    if (!this.intent) return false;
    this.intent.config = { ...this.intent.config, options: { ...this.intent.config.options, [configId]: value } };
    this.changed();
    return true;
  }

  /// Cancel on a queued prompt: it leaves the queue and goes back to the composer. The harness
  /// keeps starting.
  cancelQueued(id: string): void {
    const intent = this.intent;
    const prompt = intent?.queued.find((candidate) => candidate.id === id);
    if (!intent || !prompt) return;
    intent.queued = intent.queued.filter((candidate) => candidate !== prompt);
    this.handlers.restore?.(prompt.text, prompt.attachments);
    prompt.reject(new Error(t("switch.cancelled")));
    this.changed();
  }

  /// Retry after a failure: starts the harness again (the prompt stays in the composer).
  retry(): void {
    const intent = this.intent;
    if (intent?.phase === "failed") void this.switchTo(intent.harness, intent.cwd);
  }

  /// The user went elsewhere (another session, a fork, a default new chat): the switch ends and
  /// its queued prompts go back to the composer.
  cancel(): void {
    const intent = this.intent;
    if (intent) {
      this.intent = undefined;
      this.retire(intent, true);
    }
    this.modelPick = undefined;
    this.left = undefined;
    this.changed();
  }

  /// The pointer or keyboard rests on `harness` in the picker. Debounced; one hint per harness
  /// per PREWARM_REPEAT_MS; nothing for the harness the pane already runs.
  hint(harness: string | undefined): void {
    if (harness === this.hintTarget) return;
    this.cancelHintTimer();
    this.hintTarget = harness;
    if (!harness) return;
    this.cancelHint = this.clock.schedule(() => {
      this.cancelHint = undefined;
      const port = this.port;
      if (!port || this.hintTarget !== harness) return;
      const shown = port.shown();
      const running = this.intent?.harness ?? shown?.harness;
      if (harness === running) return;
      const now = this.clock.now();
      const last = this.hinted.get(harness);
      if (last !== undefined && now - last < PREWARM_REPEAT_MS) return;
      this.hinted.set(harness, now);
      port.prewarm(harness);
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
      for (const prompt of intent.queued) prompt.reject(new Error(t("switch.cancelled")));
      intent.queued = [];
    }
    intent.done.resolve(undefined);
  }

  private async run(intent: Intent): Promise<void> {
    const port = this.port;
    if (!port || intent.running) return;
    intent.running = port;
    let sessionId = intent.sessionId;
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
    if (mode) applied.push(port.setMode(mode).catch(() => undefined));
    for (const [configId, value] of Object.entries(options))
      applied.push(port.setConfig(configId, value).catch(() => undefined));
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
    intent.phase = "failed";
    intent.error = errorText(error) || t("switch.unknownError");
    if (intent.queued.length) {
      this.handBack(intent.queued);
      const reason = new Error(intent.error);
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
    };
    for (const listener of this.listeners) listener();
  }
}

/// The snapshot as the pane draws it under `view`. Without a switch it is `raw` (or `raw` with a
/// picked model drawn until the session reports a change). During one, the target harness's
/// composer comes from the session once it attaches, else from what that harness last reported
/// (harnessProfiles.ts), else from the catalog; queued prompts draw as the user's messages.
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
    if (!pick || !summary || summary.sessionId !== pick.sessionId || summary.model !== pick.from) return raw;
    return { ...raw, summary: { ...summary, model: pick.model, confirmedModel: summary.model } };
  }
  const name = agentName(intent.harness, catalog.find((entry) => entry.id === intent.harness)?.name);
  const attached = intent.shown && intent.sessionId !== undefined && raw.sessionId === intent.sessionId;
  const live = attached ? raw.summary : undefined;
  const profile = profiles.get(intent.harness);
  const config = intent.config;
  const predicted =
    config.model ??
    live?.model ??
    profile?.startModel ??
    profile?.model ??
    catalog.find((entry) => entry.id === intent.harness)?.models[0]?.id;
  const modes = live?.modes ?? profile?.modes;
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
  };
}
