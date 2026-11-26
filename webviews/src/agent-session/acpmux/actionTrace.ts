// One trace per user action, end to end (cmux#55505): the action mints a W3C trace id where it
// starts (the Enter keypress, a chat switch, a new chat, the page opening), every request it makes
// carries it as `_meta.traceparent`, so acpmux's `rpc` span for that request lands in the same trace,
// and this page's own steps (Enter to the sent bubble's paint, to the first token's paint) go to the
// daemon's one trace file with `_acpmux/trace/spans`. Each step carries its speed-of-light floor
// (`floor_us`, the least it could cost) and acpmux writes `gap_us` beside it.
//
// Off unless the daemon writes a trace (`CMUX_TRACE_FILE`): the page asks `_acpmux/trace/status`
// once, holds what it measured until the answer, then sends or drops it. An older acpmux answers
// that method with an error, which reads as off.

import { acpmuxPerf } from "./perf";

/** One frame at 60 Hz: the floor of any step that ends in a paint. */
export const FRAME_FLOOR_US = 16_667;
/** A local request and its reply over the pane's socket and acpmux's loop. */
export const LOCAL_ROUND_TRIP_FLOOR_US = 1_000;
/** An Enter whose send began later than this is not the send's start. */
const ENTER_WINDOW_MS = 1_000;
/** The most spans held while the status answer is out, or between sends. */
const HELD_SPANS = 256;

export type TraceSpan = {
  name: string;
  ts_us: number;
  dur_us: number;
  trace_id: string;
  floor_us?: number;
  args?: Record<string, unknown>;
};

export type TraceRequest = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** One action in flight: its trace id and when it began (ms since 1970, the daemon's clock). */
export type TraceAction = { traceId: string; name: string; startMs: number; args?: Record<string, unknown> };

const hex = (bytes: number) => {
  const out = new Uint8Array(bytes);
  crypto.getRandomValues(out);
  return Array.from(out, (b) => b.toString(16).padStart(2, "0")).join("");
};

/** `00-<trace id>-<span id>-01`, the W3C traceparent acpmux reads its trace id from. */
export function traceparentOf(traceId: string): string {
  return `00-${traceId}-${hex(8)}-01`;
}

/** Now on the epoch clock every process of a trace shares, ms with sub-ms precision. */
export function epochNowMs(): number {
  return typeof performance !== "undefined" && Number.isFinite(performance.timeOrigin)
    ? performance.timeOrigin + performance.now()
    : Date.now();
}

/** Calls `done` with the epoch time just after the next frame paints (a frame callback, then a task). */
export function afterNextPaint(done: (atMs: number) => void): void {
  if (typeof requestAnimationFrame !== "function" || typeof MessageChannel === "undefined") {
    queueMicrotask(() => done(epochNowMs()));
    return;
  }
  requestAnimationFrame(() => {
    const channel = new MessageChannel();
    channel.port1.onmessage = () => {
      channel.port1.close();
      done(epochNowMs());
    };
    channel.port2.postMessage(0);
  });
}

type Status = "unknown" | "asking" | "on" | "off";

type SendTrace = TraceAction & { promptId: string; firstToken: boolean };

export class ActionTrace {
  private status: Status = "unknown";
  private request: TraceRequest | undefined;
  private held: TraceSpan[] = [];
  private flushing = false;
  private lastEnterMs: number | undefined;
  private sends = new Map<string, SendTrace>();
  /** The newest send, the one whose first token the next agent text paints. */
  private latestSend: SendTrace | undefined;
  private switching: TraceAction | undefined;
  private keyTarget: Pick<Document, "addEventListener"> | undefined;
  /** The page's pid stand-in (a webview has no pid of its own), so Perfetto draws it as its own track. */
  pid =
    typeof performance !== "undefined" && Number.isFinite(performance.timeOrigin)
      ? 1_000_000 + (Math.round(performance.timeOrigin) % 1_000_000)
      : 1_000_000;
  private installed = false;

  /** Starts watching this page: the composers' Enter and the page's launch marks. Once per page. */
  install(): void {
    if (this.installed) return;
    this.installed = true;
    this.watchKeys();
    acpmuxPerf.launchListener = (stage, at) => {
      // The page's own marks the person sees: connected, its first frame, its rows, its settled rows.
      if (stage === "connected") this.pageMark(stage, at, LOCAL_ROUND_TRIP_FLOOR_US);
      else if (stage === "painted" || stage === "rowsDrawn" || stage === "settledDrawn")
        this.pageMark(stage, at, FRAME_FLOOR_US);
    };
  }

  /** The client's request: the status question and the spans go on its socket. */
  connect(request: TraceRequest): void {
    this.request = request;
    if (this.status === "off" && this.held.length === 0) return;
    if (this.status === "unknown") this.ask();
    else if (this.status === "on") this.flush();
  }

  /** Whether this page measures (unknown counts: it holds until acpmux answers). */
  get active(): boolean {
    return this.status !== "off";
  }

  /** Watches the composers' Enter (capture, before any handler), the send's start. */
  watchKeys(
    target: Pick<Document, "addEventListener"> | undefined = typeof document === "undefined" ? undefined : document,
  ): void {
    if (!target || this.keyTarget) return;
    this.keyTarget = target;
    target.addEventListener(
      "keydown",
      ((event: KeyboardEvent) => {
        if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
        const element = event.target as Element | null;
        if (!element?.closest?.(".acpmux-composer, .nt-composer")) return;
        this.lastEnterMs =
          typeof performance !== "undefined" && Number.isFinite(performance.timeOrigin)
            ? performance.timeOrigin + event.timeStamp
            : Date.now();
      }) as EventListener,
      true,
    );
  }

  /** A new action from `startMs` (now when unset): its trace id for every request it makes. */
  begin(name: string, startMs = epochNowMs(), args?: Record<string, unknown>): TraceAction | undefined {
    if (!this.active) return undefined;
    return { traceId: hex(16), name, startMs, ...(args ? { args } : {}) };
  }

  /** A step of `action` from its start to `endMs` (now when unset), against `floorUs`. */
  step(
    action: TraceAction | undefined,
    step: string,
    floorUs?: number,
    endMs = epochNowMs(),
    fromMs = action?.startMs,
  ): void {
    if (!action || fromMs === undefined || !this.active) return;
    this.record({
      name: `${action.name}.${step}`,
      ts_us: Math.round(fromMs * 1000),
      dur_us: Math.max(0, Math.round((endMs - fromMs) * 1000)),
      trace_id: action.traceId,
      ...(floorUs !== undefined ? { floor_us: floorUs } : {}),
      ...(action.args ? { args: action.args } : {}),
    });
  }

  /** A step of `action` that ends when the next frame paints. */
  stepAtPaint(action: TraceAction | undefined, step: string, floorUs = FRAME_FLOOR_US): void {
    if (!action || !this.active) return;
    afterNextPaint((at) => this.step(action, step, floorUs, at));
  }

  // The send: Enter to the sent bubble's paint, to acpmux taking it, to the first token's paint.

  /** A prompt goes: its trace begins at the Enter that sent it (or now, a click on Send). */
  beginSend(promptId: string, sessionId?: string): string | undefined {
    if (!this.active) return undefined;
    const now = epochNowMs();
    const enter = this.lastEnterMs !== undefined && now - this.lastEnterMs <= ENTER_WINDOW_MS ? this.lastEnterMs : now;
    this.lastEnterMs = undefined;
    const action = this.begin("send", enter, sessionId ? { chat: sessionId } : undefined);
    if (!action) return undefined;
    const send: SendTrace = { ...action, promptId, firstToken: false };
    this.sends.set(promptId, send);
    if (this.sends.size > 32) this.sends.delete(this.sends.keys().next().value as string);
    this.latestSend = send;
    if (enter !== now) this.step(action, "enter_to_send", undefined, now);
    return traceparentOf(action.traceId);
  }

  /** The prompt's traceparent, for every request its send makes (a retry, the side prompt). */
  sendTraceparent(promptId: string): string | undefined {
    const send = this.sends.get(promptId);
    return send ? traceparentOf(send.traceId) : undefined;
  }

  /** The sent bubble is in the rows: its paint ends the first step the person sees. */
  sendShown(promptId: string): void {
    this.stepAtPaint(this.sends.get(promptId), "enter_to_bubble_paint", FRAME_FLOOR_US);
  }

  /** The prompt is on its way over the socket. */
  sendRequested(promptId: string): void {
    this.step(this.sends.get(promptId), "enter_to_request", 0);
  }

  /** acpmux took the prompt (`_acpmux/prompt_accepted`). */
  sendAccepted(promptId: string): void {
    this.step(this.sends.get(promptId), "enter_to_accepted", LOCAL_ROUND_TRIP_FLOOR_US);
  }

  /**
   * The first agent text after a send. `atMs` is when acpmux recorded it, so the daemon-to-paint
   * step is ours alone (the model's time to first token is not in it).
   */
  firstToken(atMs?: number): void {
    const send = this.latestSend;
    if (!send || send.firstToken || !this.active) return;
    send.firstToken = true;
    const arrived = epochNowMs();
    afterNextPaint((painted) => {
      this.step(send, "enter_to_first_token_paint", undefined, painted);
      if (typeof atMs === "number" && Number.isFinite(atMs) && atMs > send.startMs) {
        this.step(send, "first_token_daemon_to_arrive", LOCAL_ROUND_TRIP_FLOOR_US / 2, arrived, atMs);
        this.step(send, "first_token_daemon_to_paint", FRAME_FLOOR_US, painted, atMs);
      }
    });
  }

  // The chat switch: the selection to the chat's rows painted.

  /** A chat is selected; the newest selection is the one that paints. */
  beginSwitch(sessionId: string, from?: string): TraceAction | undefined {
    const action = this.begin("chat_switch", epochNowMs(), { chat: sessionId, ...(from ? { from } : {}) });
    this.switching = action;
    return action;
  }

  /** The kept tail drew before the attach (the instant paint a cached chat gets). */
  switchTailShown(action: TraceAction | undefined): void {
    if (action && action === this.switching) this.stepAtPaint(action, "select_to_tail_paint");
  }

  /** The chat's attach is in and its rows drawn. */
  switchAttached(action: TraceAction | undefined): void {
    if (!action || action !== this.switching) return;
    this.switching = undefined;
    this.step(action, "select_to_attach", LOCAL_ROUND_TRIP_FLOOR_US);
    this.stepAtPaint(action, "select_to_attached_paint", FRAME_FLOOR_US);
  }

  // The page itself (a tab opening, the app's first window): its origin to its launch marks.

  /** A launch mark of this page (`acpmuxPerf.markLaunch`): a span from the page's origin. */
  pageMark(stage: string, atMs: number, floorUs?: number): void {
    if (!this.active || typeof performance === "undefined" || !Number.isFinite(performance.timeOrigin)) return;
    this.pageAction ??= { traceId: hex(16), name: "page_open", startMs: performance.timeOrigin };
    this.step(this.pageAction, `origin_to_${stage}`, floorUs, atMs);
  }
  private pageAction: TraceAction | undefined;

  private record(span: TraceSpan): void {
    if (this.status === "off") return;
    this.held.push(span);
    if (this.held.length > HELD_SPANS) this.held.shift();
    if (this.status === "on") this.flush();
    else if (this.status === "unknown") this.ask();
  }

  private ask(): void {
    if (!this.request || this.status !== "unknown") return;
    this.status = "asking";
    this.request("_acpmux/trace/status", {}).then(
      (answer) => {
        this.status = (answer as { enabled?: unknown } | undefined)?.enabled === true ? "on" : "off";
        if (this.status === "on") this.flush();
        else this.dropAll();
      },
      () => {
        this.status = "off";
        this.dropAll();
      },
    );
  }

  private dropAll(): void {
    this.held = [];
    this.sends.clear();
    this.latestSend = undefined;
    this.switching = undefined;
  }

  // One request per task's worth of spans: a burst of steps goes together.
  private flush(): void {
    if (this.flushing || !this.request || this.held.length === 0) return;
    this.flushing = true;
    queueMicrotask(() => {
      this.flushing = false;
      const spans = this.held;
      this.held = [];
      if (!spans.length || !this.request) return;
      void this.request("_acpmux/trace/spans", { process: "webview", pid: this.pid, spans }).catch(() => {});
    });
  }
}

/** The page's one action trace. */
export const actionTrace = new ActionTrace();
