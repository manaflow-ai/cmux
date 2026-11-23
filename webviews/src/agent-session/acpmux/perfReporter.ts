// The chat page's half of the live perf commentator (acpmux perf_watch.rs; Leo, 2026-11-18: "just
// some sort of watcher that doesn't really affect anything, but it's just like, okay, it's timing
// this, it's timing that"). The daemon judges every number against its budgets and writes the
// notes; the page only measures what only it sees and reports it, once a second, as
// `_acpmux/perf {op:"report"}`:
//
// - renders per component since the last report (perf.ts `renders`, perfRender.ts),
// - long frames (>= 50 ms) from the engine's `long-animation-frame` or `longtask` entries, else the
//   flicker log's frame watch (flickerLog.ts, which times frames past 100 ms),
// - layout shifts (`layout-shift` entries), each said as after the first paint or not,
// - bytes per method the page's socket carried (wire.ts), the watch's own requests left out,
// - spans the page owns: a new chat (handshake to first token), the page load (navigation to
//   first paint) and a workspace switch (the page shown again to a settled transcript).
//
// Off by default, and off costs nothing: no observer, timer or listener is registered until the
// daemon says the watch is on (one `status` read when the page first connects, the Inspector's
// Perf tab, or a report's answer), and all of them go when it says off.

import {
  acpmuxPerf,
  keyDroppedFrames,
  percentile,
  typingFrameInterval,
  type AcpmuxPerf,
  type AgentMark,
  type TypingSample,
} from "./perf";
import { acpWire, type AcpWireLog, type WireEntry } from "./wire";

/** Sends one `_acpmux/perf` request (the page's client, direct.ts `perf`). */
export type PerfSend = (params: Record<string, unknown>) => Promise<unknown>;

export type PerfPart = { name: string; startMs: number; ms: number };
/** A span as `report` takes it (perf_watch.rs `report`). */
export type PerfSpan = {
  name: string;
  budget?: string;
  ms: number;
  parts: PerfPart[];
  detail?: Record<string, unknown>;
};
export type LayoutShiftReport = { score: number; afterPaint: boolean; what: string };
export type PerfReport = {
  op: "report";
  page: string;
  windowMs: number;
  spans: PerfSpan[];
  renders: Record<string, number>;
  frames: number[];
  layoutShifts: LayoutShiftReport[];
  bytes: { label: string; bytes: number }[];
};

/** How often a report goes while the watch is on. */
export const REPORT_EVERY_MS = 1_000;
/** While on, an empty report goes at least this often, so a page with nothing to say still hears an `off`
 * from another client (`cmux debug perf off`). */
export const HEARTBEAT_EVERY_MS = 5_000;
/** While off, a page shown again asks the daemon at most this often whether the watch was turned on
 * elsewhere (`cmux debug perf on`): one status read, never a timer. */
export const RECHECK_EVERY_MS = 10_000;
/** A frame at least this long is reported (the daemon's `frame` budget is 50 ms). */
export const LONG_FRAME_REPORT_MS = 50;
/** Held between reports at most, each list; older items go first. */
const HELD_CAP = 256;
/** Reports that failed in a row before the reporter stops (the page lost its daemon for good). */
const FAILURES_TO_STOP = 30;
/** Frames a workspace switch waits for its transcript to settle before it is reported unsettled. */
const SWITCH_MAX_FRAMES = 300;
/** Quiet frames in a row that make a transcript settled. */
const SETTLED_FRAMES = 2;
/** The page-load span goes once its marks are all in, or this long after its first paint. */
const PAGE_LOAD_WAIT_MS = 2_000;
/** A page load older than this when the watch turns on is not reported. */
const PAGE_LOAD_MAX_AGE_MS = 60_000;
/** The watch's own requests are not counted as the page's data. */
const OWN_METHOD = "_acpmux/perf";

const round = (ms: number) => Math.round(ms * 10) / 10;

/// Consecutive marks as parts: each part runs from the mark before it to its own, named by its own.
function partsOf(marks: readonly (readonly [name: string, at: number])[], start: number): PerfPart[] {
  const parts: PerfPart[] = [];
  let previous = start;
  for (const [name, at] of marks) {
    parts.push({ name, startMs: round(previous - start), ms: round(Math.max(0, at - previous)) });
    previous = Math.max(previous, at);
  }
  return parts;
}

/**
 * The new-chat span from a page's agent marks (perf.ts, `performance.now()` clock): handshake,
 * composer ready, the first prompt sent and the first token. Only a chat whose first token came
 * after its first prompt is a new chat (a chat opened with a reply already in its history marks its
 * first token as it draws it). The person's own time between the composer being ready and their
 * send is not the app's: it is left out of the total and said as `waitedMs`.
 */
export function newChatSpan(marks: Partial<Record<AgentMark, number>>): PerfSpan | undefined {
  const { handshakeStart, handshakeReady, composerReady, promptSent, firstToken } = marks;
  if (handshakeStart === undefined || promptSent === undefined || firstToken === undefined) return undefined;
  if (firstToken < promptSent) return undefined;
  const before: [string, number][] = [];
  if (handshakeReady !== undefined && handshakeReady <= promptSent) before.push(["handshake", handshakeReady]);
  if (composerReady !== undefined && composerReady <= promptSent) before.push(["composer ready", composerReady]);
  before.sort((left, right) => left[1] - right[1]);
  const ready = before.at(-1)?.[1] ?? handshakeStart;
  // A prompt sent before the page was ready (a queued send) waited on the app, not the person.
  const waited = before.length ? Math.max(0, promptSent - ready) : 0;
  const parts = partsOf(before, handshakeStart);
  const readyMs = Math.max(0, ready - handshakeStart);
  const sendToToken = Math.max(0, firstToken - promptSent);
  if (!before.length) {
    // No ready marks: the span runs from the handshake to the first token as it came.
    parts.push({ name: "prompt sent", startMs: 0, ms: round(Math.max(0, promptSent - handshakeStart)) });
    parts.push({ name: "first token", startMs: round(promptSent - handshakeStart), ms: round(sendToToken) });
    return { name: "new chat", budget: "chat.first_token", ms: round(firstToken - handshakeStart), parts };
  }
  parts.push({ name: "first token", startMs: round(readyMs), ms: round(sendToToken) });
  return {
    name: "new chat",
    budget: "chat.first_token",
    ms: round(readyMs + sendToToken),
    parts,
    detail: { waitedMs: round(waited) },
  };
}

/// The page-load marks, in the order a page goes through them, with the names the span says.
const PAGE_LOAD_MARKS: readonly (readonly [key: string, name: string])[] = [
  ["connectStart", "connect start"],
  ["connected", "connected"],
  ["firstEvent", "first event"],
  ["transcriptMount", "transcript mount"],
  ["painted", "first paint"],
];

/**
 * The page-load span from the page's launch timeline (perf.ts `launchTimeline`, wall clock): from
 * the navigation (`page_origin_epoch_ms`) to its first paint, with each launch mark as a part.
 * Undefined until the page painted. Marks after the paint (a first event that came after a kept
 * copy painted) are still parts; the total is the paint.
 */
export function pageLoadSpan(timeline: Record<string, number>): PerfSpan | undefined {
  const origin = timeline.page_origin_epoch_ms;
  const painted = timeline.painted_epoch_ms;
  if (origin === undefined || painted === undefined) return undefined;
  const marks = PAGE_LOAD_MARKS.flatMap(([key, name]) => {
    const at = timeline[`${key}_epoch_ms`];
    return at === undefined ? [] : [[name, at] as const];
  }).sort((left, right) => left[1] - right[1]);
  return {
    name: "page load",
    budget: "page.load",
    ms: round(Math.max(0, painted - origin)),
    parts: partsOf(marks, origin),
  };
}

/** Whether the page-load marks are all in (so its span is whole). */
export function pageLoadComplete(timeline: Record<string, number>): boolean {
  return PAGE_LOAD_MARKS.every(([key]) => timeline[`${key}_epoch_ms`] !== undefined);
}

/** The workspace-switch span: the page shown at `visible`, its first frame, its transcript settled. */
export function workspaceSwitchSpan(
  visible: number,
  firstFrame: number,
  settled: number,
  isSettled: boolean,
): PerfSpan {
  const span: PerfSpan = {
    name: "workspace switch",
    budget: "workspace.switch",
    ms: round(Math.max(0, settled - visible)),
    parts: partsOf(
      [
        ["first frame", firstFrame],
        ["settled", settled],
      ],
      visible,
    ),
  };
  if (!isSettled) span.detail = { settled: false };
  return span;
}

/** Keys a key-to-paint span carries their own times for, at most (a second of fast typing is about 10). */
const KEY_PAINT_KEYS = 64;
/** A key whose frame-after mark has not come this long after its paint is reported without it (a hidden page). */
const KEY_NEXT_FRAME_WAIT_MS = 1_000;

/**
 * The composer's typing since the last report as one span (Leo: "we need typing in the gui to be fast too and
 * smootha nd stuff"): each key from its keydown to after the frame that drew it (perf.ts's composer key
 * listener: one rAF, then a task after it, the post-paint mark). The span's total is the slowest key, judged
 * against `composer.key_paint`; its parts are that key's stages (to the page's listener, the edit done, the
 * frame start, the paint). `detail` has every key's paint time, so a reader takes p50/p95/p99 over many
 * reports, the dropped frames (`keyDroppedFrames`) and the prompt's length. Undefined with no keys.
 */
export function keyPaintSpan(
  samples: readonly TypingSample[],
  nominal = typingFrameInterval(samples),
): PerfSpan | undefined {
  if (!samples.length) return undefined;
  const slowest = samples.reduce((worst, sample) => (sample.paint > worst.paint ? sample : worst));
  const stages: [string, number][] = [];
  if (slowest.listener !== undefined) stages.push(["listener", slowest.listener]);
  if (slowest.work !== undefined) stages.push(["edit", slowest.work]);
  stages.push(["frame", slowest.frame], ["paint", slowest.paint]);
  const sorted = samples.map((sample) => sample.paint).sort((a, b) => a - b);
  return {
    name: "key to paint",
    budget: "composer.key_paint",
    ms: round(slowest.paint),
    parts: partsOf(stages, 0),
    detail: {
      keys: samples.length,
      p50Ms: round(percentile(sorted, 0.5)),
      p95Ms: round(percentile(sorted, 0.95)),
      p99Ms: round(percentile(sorted, 0.99)),
      droppedFrames: samples.reduce((total, sample) => total + keyDroppedFrames(sample, nominal), 0),
      frameIntervalMs: round(nominal),
      chars: samples.reduce((most, sample) => Math.max(most, sample.chars ?? 0), 0),
      paintMs: samples.slice(-KEY_PAINT_KEYS).map((sample) => round(sample.paint)),
    },
  };
}

/** Bytes per method of the wire entries after `afterSeq`, the watch's own left out, largest first. */
export function bytesByMethod(entries: readonly WireEntry[], afterSeq: number): { label: string; bytes: number }[] {
  const sums = new Map<string, number>();
  for (const entry of entries) {
    if (entry.seq <= afterSeq || entry.size === undefined || entry.kind === "lifecycle") continue;
    const label = entry.method ?? entry.kind;
    if (label === OWN_METHOD) continue;
    sums.set(label, (sums.get(label) ?? 0) + entry.size);
  }
  return [...sums]
    .map(([label, bytes]) => ({ label, bytes }))
    .sort((left, right) => right.bytes - left.bytes)
    .slice(0, 64);
}

/**
 * Renders per component since `last` (both perf.ts `renders` counts). A transcript row's own mount
 * (`mount:<id>`) is not a re-render; its remounts (`remount:<id>`) are counted together as
 * `row remount`. A count below its last one was reset meanwhile (a debug bench): all of it is new.
 */
export function renderDelta(
  current: ReadonlyMap<string, number>,
  last: ReadonlyMap<string, number>,
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const [name, count] of current) {
    if (name.startsWith("mount:")) continue;
    const before = last.get(name) ?? 0;
    const delta = count >= before ? count - before : count;
    if (delta <= 0) continue;
    const key = name.startsWith("remount:") ? "row remount" : name;
    out[key] = (out[key] ?? 0) + delta;
  }
  return out;
}

/** A shifted node, said as its tag and first class: no text of the chat. */
function describeNode(node: unknown): string {
  const element = node as { tagName?: string; classList?: { item(index: number): string | null } } | null;
  if (!element?.tagName) return "";
  const first = element.classList?.item(0);
  return `${element.tagName.toLowerCase()}${first ? `.${first}` : ""}`;
}

type Observe = (type: string, onEntries: (entries: PerformanceEntry[]) => void) => (() => void) | undefined;

/** The engine's observer for `type`, or undefined where it has none. */
const observeEngine: Observe = (type, onEntries) => {
  const Observer = (globalThis as { PerformanceObserver?: typeof PerformanceObserver }).PerformanceObserver;
  if (!Observer?.supportedEntryTypes?.includes(type)) return undefined;
  try {
    const observer = new Observer((list) => onEntries(list.getEntries()));
    observer.observe({ type, buffered: false });
    return () => observer.disconnect();
  } catch {
    return undefined;
  }
};

export type PerfReporterEnv = {
  perf: AcpmuxPerf;
  wire: AcpWireLog;
  /** `performance.now()`. */
  now: () => number;
  /** `Date.now()`. */
  wall: () => number;
  every: (run: () => void, ms: number) => unknown;
  stopEvery: (handle: unknown) => void;
  frame: (run: (time: number) => void) => unknown;
  cancelFrame: (handle: unknown) => void;
  observe: Observe;
};

function browserEnv(): PerfReporterEnv {
  return {
    perf: acpmuxPerf,
    wire: acpWire,
    now: () => performance.now(),
    wall: () => Date.now(),
    every: (run, ms) => setInterval(run, ms),
    stopEvery: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
    frame: (run) => requestAnimationFrame(run),
    cancelFrame: (handle) => cancelAnimationFrame(handle as number),
    observe: observeEngine,
  };
}

type Switch = { visible: number; firstFrame?: number; quiet: number; frames: number; handle?: unknown };

/** The page's reporter; one per page (`perfReporter`). */
export class PerfReporter {
  /** Whether the daemon said the watch is on (and so this page measures and reports). */
  on = false;
  /** The page's name in the daemon's notes. */
  page = "chat";
  private send: PerfSend | undefined;
  private checked = false;
  private lastStatusAt = Number.NEGATIVE_INFINITY;
  private lastSentAt = 0;
  private listeners = new Set<() => void>();
  // While on:
  private timer: unknown;
  private stops: (() => void)[] = [];
  private wasEnabled = false;
  private lastRenders = new Map<string, number>();
  private lastWireSeq = 0;
  private lastTyping = 0;
  private lastReportAt = 0;
  private frames: number[] = [];
  private shifts: LayoutShiftReport[] = [];
  private spans: PerfSpan[] = [];
  private ownFrames = false;
  private sending = false;
  private failures = 0;
  private pageLoadDone = false;
  private chatSpanFor: number | undefined;
  private switching: Switch | undefined;
  private disturbed = false;

  constructor(private readonly env: PerfReporterEnv = browserEnv()) {}

  /**
   * The page's client connected: `send` reaches the daemon from now on. The first call asks the
   * daemon once whether the watch is on; off, nothing else runs.
   */
  attach(send: PerfSend): void {
    this.send = send;
    if (this.checked) return;
    this.checked = true;
    this.askStatus();
  }

  /** One status read; its answer turns the reporter on or off. */
  private askStatus(): void {
    const send = this.send;
    if (!send) return;
    this.lastStatusAt = this.env.now();
    void send({ op: "status" }).then(
      (status) => this.setOn(isOn(status)),
      () => undefined,
    );
  }

  /** Whether the watch is on, as the daemon last said (the Perf tab's switch, a report's answer). */
  setOn(on: boolean): void {
    if (on === this.on) return;
    if (on) this.start();
    else this.stop();
    for (const listener of this.listeners) listener();
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** The transcript on screen was replaced whole (flickerLog.ts `noteTranscriptReplace`). */
  transcriptReplaced(): void {
    if (this.on) this.disturbed = true;
  }

  /** A long frame the flicker log's frame watch timed (flickerLog.ts), when the engine reports none. */
  longFrame(ms: number): void {
    if (this.on && !this.ownFrames) this.hold(this.frames, Math.round(ms));
  }

  /** The report due now, or undefined when nothing happened since the last one. */
  buildReport(): PerfReport | undefined {
    const { perf, wire, now } = this.env;
    const at = now();
    const windowMs = Math.max(1, Math.round(at - this.lastReportAt));
    this.lastReportAt = at;
    this.collectPageLoad();
    this.collectTyping();
    const renders = renderDelta(perf.renders, this.lastRenders);
    this.lastRenders = new Map(perf.renders);
    const entries = wire.entries();
    const bytes = bytesByMethod(entries, this.lastWireSeq);
    this.lastWireSeq = entries.at(-1)?.seq ?? this.lastWireSeq;
    const report: PerfReport = {
      op: "report",
      page: this.page,
      windowMs,
      spans: this.spans,
      renders,
      frames: this.frames,
      layoutShifts: this.shifts,
      bytes,
    };
    this.spans = [];
    this.frames = [];
    this.shifts = [];
    const empty =
      !report.spans.length &&
      !report.frames.length &&
      !report.layoutShifts.length &&
      !report.bytes.length &&
      !Object.keys(renders).length;
    return empty ? undefined : report;
  }

  /** An empty report: it says nothing, and its answer tells a quiet page that the watch went off. */
  private heartbeat(): PerfReport {
    return {
      op: "report",
      page: this.page,
      windowMs: REPORT_EVERY_MS,
      spans: [],
      renders: {},
      frames: [],
      layoutShifts: [],
      bytes: [],
    };
  }

  /** One report; skipped while the last one is still out (its items wait for the next). */
  tick(): void {
    if (!this.on || this.sending || !this.send) return;
    const sentAt = this.lastSentAt;
    const report = this.buildReport() ?? (this.env.now() - sentAt >= HEARTBEAT_EVERY_MS ? this.heartbeat() : undefined);
    if (!report) return;
    this.lastSentAt = this.env.now();
    this.sending = true;
    void this.send(report).then(
      (answer) => {
        this.sending = false;
        this.failures = 0;
        if (answer && typeof answer === "object" && (answer as { on?: unknown }).on === false) this.setOn(false);
      },
      () => {
        this.sending = false;
        this.failures += 1;
        if (this.failures >= FAILURES_TO_STOP) this.setOn(false);
      },
    );
  }

  private start(): void {
    const { perf, wire, now, every, observe } = this.env;
    this.on = true;
    this.wasEnabled = perf.enabled;
    perf.enable();
    perf.markListener = (stage) => this.agentMarked(stage);
    this.lastRenders = new Map(perf.renders);
    this.lastWireSeq = wire.entries().at(-1)?.seq ?? 0;
    this.lastTyping = perf.typingPushed;
    this.lastReportAt = now();
    this.lastSentAt = now();
    this.failures = 0;
    this.chatSpanFor = undefined;
    const frames = (entries: PerformanceEntry[]) => {
      for (const entry of entries)
        if (entry.duration >= LONG_FRAME_REPORT_MS) this.hold(this.frames, Math.round(entry.duration));
    };
    const stopFrames = observe("long-animation-frame", frames) ?? observe("longtask", frames);
    this.ownFrames = stopFrames !== undefined;
    if (stopFrames) this.stops.push(stopFrames);
    const stopShifts = observe("layout-shift", (entries) => this.shifted(entries));
    if (stopShifts) this.stops.push(stopShifts);
    this.timer = every(() => this.tick(), REPORT_EVERY_MS);
  }

  private stop(): void {
    const { perf, stopEvery } = this.env;
    this.on = false;
    stopEvery(this.timer);
    this.timer = undefined;
    for (const stop of this.stops.splice(0)) stop();
    this.cancelSwitch();
    perf.markListener = undefined;
    if (!this.wasEnabled) perf.disable();
    this.frames = [];
    this.shifts = [];
    this.spans = [];
    this.disturbed = false;
  }

  private hold<T>(list: T[], item: T): void {
    list.push(item);
    if (list.length > HELD_CAP) list.shift();
  }

  private agentMarked(stage: AgentMark): void {
    if (stage !== "firstToken") return;
    const marks = this.env.perf.agentMarkTimes();
    if (marks.handshakeStart === undefined || this.chatSpanFor === marks.handshakeStart) return;
    const span = newChatSpan(marks);
    if (!span) return;
    this.chatSpanFor = marks.handshakeStart;
    this.hold(this.spans, span);
  }

  /// The keys typed since the last report, up to the first whose frame-after mark is still due.
  private collectTyping(): void {
    const { perf, wall } = this.env;
    const fresh = perf.typingAfter(this.lastTyping);
    if (!fresh.length) return;
    const now = wall();
    let ready = 0;
    while (
      ready < fresh.length &&
      (fresh[ready]!.next_frame_ms !== undefined ||
        now - (fresh[ready]!.paint_epoch_ms ?? Number.NEGATIVE_INFINITY) >= KEY_NEXT_FRAME_WAIT_MS)
    )
      ready += 1;
    // Keys the ring dropped before this report are skipped, not waited for.
    this.lastTyping = perf.typingPushed - (fresh.length - ready);
    const span = keyPaintSpan(fresh.slice(0, ready));
    if (span) this.hold(this.spans, span);
  }

  private collectPageLoad(): void {
    if (this.pageLoadDone) return;
    const timeline = this.env.perf.launchTimeline();
    const painted = timeline.painted_epoch_ms;
    if (painted === undefined) return;
    const age = this.env.wall() - painted;
    if (age > PAGE_LOAD_MAX_AGE_MS) {
      this.pageLoadDone = true;
      return;
    }
    if (!pageLoadComplete(timeline) && age < PAGE_LOAD_WAIT_MS) return;
    const span = pageLoadSpan(timeline);
    if (!span) return;
    this.pageLoadDone = true;
    this.hold(this.spans, span);
  }

  private shifted(entries: PerformanceEntry[]): void {
    const origin = this.env.perf.launchTimeline();
    const painted =
      origin.painted_epoch_ms !== undefined && origin.page_origin_epoch_ms !== undefined
        ? origin.painted_epoch_ms - origin.page_origin_epoch_ms
        : undefined;
    for (const raw of entries) {
      const entry = raw as PerformanceEntry & {
        value?: number;
        hadRecentInput?: boolean;
        sources?: { node?: unknown }[];
      };
      if (entry.hadRecentInput || !(typeof entry.value === "number" && entry.value > 0)) continue;
      this.disturbed = true;
      this.hold(this.shifts, {
        score: Math.round(entry.value * 10_000) / 10_000,
        afterPaint: painted !== undefined && entry.startTime > painted,
        what: describeNode(entry.sources?.[0]?.node),
      });
    }
  }

  /// The page was shown or hidden (flickerLog.ts's `visibilitychange`, the page's one listener). Shown
  /// again (a workspace or tab with this chat came forward): time it to its first
  /// frame and to the first SETTLED_FRAMES frames in a row with no transcript replace and no shift.
  visibilityChanged(visible: boolean): void {
    if (!this.on) {
      // Off here: the watch may have been turned on by another client since; ask again, at most every RECHECK_EVERY_MS.
      if (visible && this.checked && this.env.now() - this.lastStatusAt >= RECHECK_EVERY_MS) this.askStatus();
      return;
    }
    this.cancelSwitch();
    if (!visible) return;
    const state: Switch = { visible: this.env.now(), quiet: 0, frames: 0 };
    this.switching = state;
    this.disturbed = false;
    const step = (time: number) => {
      if (this.switching !== state || !this.on) return;
      state.frames += 1;
      if (state.firstFrame === undefined) {
        state.firstFrame = time;
      } else if (this.disturbed) {
        state.quiet = 0;
      } else {
        state.quiet += 1;
      }
      this.disturbed = false;
      const settled = state.quiet >= SETTLED_FRAMES;
      if (settled || state.frames >= SWITCH_MAX_FRAMES) {
        this.switching = undefined;
        this.hold(this.spans, workspaceSwitchSpan(state.visible, state.firstFrame, time, settled));
        return;
      }
      state.handle = this.env.frame(step);
    };
    state.handle = this.env.frame(step);
  }

  private cancelSwitch(): void {
    const state = this.switching;
    this.switching = undefined;
    if (state?.handle !== undefined) this.env.cancelFrame(state.handle);
  }
}

function isOn(status: unknown): boolean {
  return !!status && typeof status === "object" && (status as { on?: unknown }).on === true;
}

/** The page's reporter. */
export const perfReporter = new PerfReporter();
