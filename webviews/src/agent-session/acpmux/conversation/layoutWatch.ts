// l10n-allow-file: diagnostic words for the page log and harnesses, never shown in the pane.
// The transcript's one layout watcher: anything in view that moves with no reason is an event, not a
// guess after the fact (Leo, 2026-11-17: "all this shift stuff is so goofy like we should be able to
// have a system that just detects when things are coming in or out"). It checks the transcript motion
// model's invariants (cmuxterm-hq docs/design/transcript-motion-model.md):
//
// Every painted frame:
// - I2: a row in view changes its top only under input (the last INPUT_MS: wheel, touch, keys, a
//   pointer drag), an append at the bottom (a row id below every row seen, or the bottom row growing
//   while a turn streams), or a declared move (`expect`). Inside an expect, rows it did not name hold
//   still, and its anchor row stays on its pixel.
// - I3: no band over BAND_PX with no row drawn between the first and last rows in view; a row drawn
//   at opacity under 1 (an older page fading in) counts as no row.
// - I5: one row's height changing on two frames in a row (a height animating), except the bottom row
//   in view (the streaming row) and rows an expect covers.
// - I6: the same data drawn again as something else: one row id under a new kind or a new element, or
//   a row that went in the frame a row with the same id tail came (working-<id> to worked-<id>).
// - I9: a clock's box changes width only when its digits' shape changes, and its value never falls.
// - I10: an action's right edge stays where it is while its row keeps its width.
// On the settled frame only (no expect open, no finite animation running, nothing changed):
// - I1: adjacent rows in view leave at most GAP_PX between them and do not overlap by more than 1 px.
// - I4: after an expect closed, no row in view has an inline `translate`, no `.cv-fold` an inline
//   height, and the transcript holds no `[data-fold-clip]` and no ghost copy.
//
// It reads after each frame painted (a frame callback posts a message; test/support/paintedFrames.ts says
// why a read in the frame callback sees a state no frame painted), only while something could have moved:
// a row mounted or unmounted, a row in view, the composer or the scroller resized, a style changed, a
// scroll. A read that changed reads the next frame too, so a move with no DOM change (a transition) is
// followed until a frame repeats. At rest it arms nothing: no frame, no timer (bench/chat-switch.bench.ts
// `idle_wakeups`, as firstLoadWatch.ts keeps it).
//
// `layoutWatch.expect(reason, {rows, anchor, ms})` is the single contract for a move that is meant.
//
// Sinks: dev and nightly builds log each event to the flicker ring (flickerLog.ts `layout-unexplained`,
// with no row id); a dev build can outline the offender for a second (`overlay`); galleries and
// harnesses read `window.cmuxLayoutWatch.unexplained()` (test/support/layoutWatch.ts); `cmux app chat
// perf` reports `layout.unexplained_shifts` (chatPerfCapture.ts). A Release build runs none of it but
// a perf capture's own window. Warn-only for now: nothing fails on an event yet.
// No chat text goes out: ids, kinds, pixels and short words.
import { readFrame, type FrameParts } from "../firstLoadWatch";

export type Invariant = "I1" | "I2" | "I3" | "I4" | "I5" | "I6" | "I9" | "I10";
export type ShiftCause = "mount" | "unmount" | "resize" | "reflow";

/// One unexplained change. `rowId` is the transcript row's id where one is the offender, `selector` what
/// else is; `deltaPx` how far it went (the band's height for I3, the gap for I1); `frame` the read's
/// number on this page; `expect` the declared move it broke, if any; `stack` where the change was heard.
export type LayoutEvent = {
  invariant: Invariant;
  rowId?: string;
  selector?: string;
  cause: ShiftCause;
  deltaPx: number;
  frame: number;
  at: number;
  expect?: string;
  stack?: string;
};

export type ExpectOptions = {
  /// The rows that may move; omitted, any row may except `anchor`.
  rows?: readonly string[];
  /// A row that stays on its pixel while the move runs.
  anchor?: string;
  /// How long the move runs (ms), at most MAX_EXPECT_MS.
  ms?: number;
};

/// Input this recent explains motion.
export const INPUT_MS = 300; // motion-allow: an input window, not an animation
/// A move under this is rounding.
export const THRESHOLD_PX = 1;
/// The longest a declared move may run, and how long one runs when it does not say.
export const MAX_EXPECT_MS = 5_000; // motion-allow: a bound on a declared move, not an animation
export const DEFAULT_EXPECT_MS = 400; // motion-allow: a declared move's default window, not an animation
/// I3: the widest band with no row drawn, between the first and last rows in view.
export const BAND_PX = 40;
/// I1: the widest gap between two adjacent rows at rest.
export const GAP_PX = 32;
/// Events held for `unexplained()`; older ones go.
const MAX_EVENTS = 200;

const CLOCK = ".cv-worked__label-time";
const ACTIONS = ".cv-turn-actions, .cv-sent-actions, .cv-received-actions";
const GHOSTS = ".acpmux-row:not([data-row-id]), [data-send-morph-ghost], [data-send-tuck-ghost], [data-fold-clip]";
const INPUT_EVENTS = ["wheel", "touchstart", "touchmove", "keydown", "pointerdown"] as const;

type RowRead = {
  id: string;
  kind: string;
  top: number;
  bottom: number;
  width: number;
  opaque: boolean;
  element: HTMLElement;
  clock?: { width: number; shape: string; seconds?: number };
  actionRight?: number;
};

type Expectation = { reason: string; rows?: Set<string>; anchor?: string; until: number };

/// The row's kind: its `acpmux-<kind>` class (VirtualTranscript.tsx `TranscriptRow`).
function kindOf(element: HTMLElement): string {
  for (const name of Array.from(element.classList ?? []))
    if (name.startsWith("acpmux-") && !name.startsWith("acpmux-row")) return name.slice(7);
  return "";
}

/// The part of a row id that names its data: after the last `:`, else after the first `-`
/// (`working-<id>`, `worked-<id>`, `lane-notices:<id>`).
export function idTail(id: string): string {
  const colon = id.lastIndexOf(":");
  if (colon >= 0) return id.slice(colon + 1);
  const dash = id.indexOf("-");
  return dash >= 0 ? id.slice(dash + 1) : id;
}

/// A clock's value in seconds from its digits and unit letters (`1h 2m`, `45s`), or undefined.
export function clockSeconds(text: string): number | undefined {
  let total = 0;
  let found = false;
  for (const match of text.matchAll(/(\d+(?:\.\d+)?)\s*([hms])/g)) {
    found = true;
    total += Number(match[1]) * (match[2] === "h" ? 3600 : match[2] === "m" ? 60 : 1);
  }
  return found ? total : undefined;
}

const moved = (a: number, b: number) => Math.abs(a - b) > THRESHOLD_PX;
const round1 = (px: number) => Math.round(px * 10) / 10;

export type LayoutWatchSink = (event: LayoutEvent) => void;

type WatchWindow = Window & typeof globalThis;

/// One page's watcher. `start` arms the observers; `stop` drops them all.
export class LayoutWatcher {
  private events: LayoutEvent[] = [];
  private total = 0;
  private settledTicks = 0;
  private readonly settledListeners = new Set<() => void>();
  private readonly sinks = new Set<LayoutWatchSink>();
  private expects: Expectation[] = [];
  private stops: (() => void)[] = [];
  private running = false;
  private frameNo = 0;
  private previous: RowRead[] | undefined;
  private previousSignature = "";
  /// Rows whose height changed in the last read (I5).
  private resized = new Set<string>();
  /// I3 / I5 offenders already reported while they last, so one band or one animation is one event.
  private reported = new Set<string>();
  private lastInput = -Infinity;
  private causes: { cause: ShiftCause; stack?: string } | undefined;
  private frameHandle: number | undefined;
  private posted = false;
  private expectTimer: number | undefined;
  private settled = true;
  private expectSinceSettle = false;
  private observedRows = new Set<Element>();
  private resizeObserver: ResizeObserver | undefined;
  private channel: { post(): void; close(): void } | undefined;

  constructor(
    private readonly win: Window,
    private readonly options: { stacks?: boolean } = {},
  ) {}

  isRunning(): boolean {
    return this.running;
  }

  /// Every event since the page started or the last `clear`, oldest first.
  unexplained(): LayoutEvent[] {
    return this.events.map((event) => ({ ...event }));
  }

  /// How many events this page has had (never cleared): the perf capture's count.
  count(): number {
    return this.total;
  }

  clear(): void {
    this.events = [];
  }

  /// How many settled frames have been read.
  settledCount(): number {
    return this.settledTicks;
  }

  onSettled(listener: () => void): () => void {
    this.settledListeners.add(listener);
    return () => this.settledListeners.delete(listener);
  }

  addSink(sink: LayoutWatchSink): () => void {
    this.sinks.add(sink);
    return () => this.sinks.delete(sink);
  }

  /// A move that is meant: until it ends, the rows it names (any, without `rows`) may move, its anchor
  /// may not. Returns a function that ends it early.
  expect(reason: string, options: ExpectOptions = {}): () => void {
    if (!this.running) return () => undefined;
    const ms = Math.max(0, Math.min(MAX_EXPECT_MS, options.ms ?? DEFAULT_EXPECT_MS));
    const expectation: Expectation = {
      reason,
      rows: options.rows ? new Set(options.rows) : undefined,
      anchor: options.anchor,
      until: this.now() + ms,
    };
    this.expects.push(expectation);
    this.settled = false;
    this.expectSinceSettle = true;
    this.wake("reflow");
    return () => {
      expectation.until = Math.min(expectation.until, this.now());
      this.wake("reflow");
    };
  }

  start(): void {
    if (this.running) return;
    const win = this.win as WatchWindow;
    const doc = win.document;
    this.running = true;
    this.previous = undefined;
    this.previousSignature = "";
    const listen = (
      target: Pick<EventTarget, "addEventListener" | "removeEventListener">,
      type: string,
      run: (event: Event) => void,
    ) => {
      target.addEventListener(type, run, { capture: true, passive: true });
      this.stops.push(() => target.removeEventListener(type, run, { capture: true }));
    };
    const MutationObserverType = win.MutationObserver;
    if (MutationObserverType) {
      const mutations = new MutationObserverType((records) => this.heardMutations(records));
      mutations.observe(doc.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["style", "class"],
      });
      this.stops.push(() => mutations.disconnect());
    }
    const ResizeObserverType = win.ResizeObserver;
    if (ResizeObserverType) {
      this.resizeObserver = new ResizeObserverType(() => this.wake("resize"));
      this.stops.push(() => {
        this.resizeObserver?.disconnect();
        this.resizeObserver = undefined;
        this.observedRows.clear();
      });
    }
    // Input explains motion for INPUT_MS; a read the last frame left is of the state it painted, so it
    // runs first, before the input's own handlers change the page.
    const input = (event: Event) => {
      if (event.type === "pointermove" && !(event as PointerEvent).buttons) return;
      if (this.posted) this.read();
      this.lastInput = this.now();
    };
    for (const type of INPUT_EVENTS) listen(win, type, input);
    listen(win, "pointermove", input);
    for (const type of ["scroll", "transitionrun", "transitionend", "animationstart", "animationend"])
      listen(doc, type, () => this.wake("reflow"));
    listen(win, "resize", () => this.wake("resize"));
    listen(doc, "visibilitychange", () => {
      this.previous = undefined;
      if (doc.visibilityState === "visible") this.wake("reflow");
    });
    const Channel = win.MessageChannel;
    if (Channel) {
      const channel = new Channel();
      channel.port1.onmessage = () => {
        if (this.posted) this.read();
      };
      this.channel = {
        post: () => channel.port2.postMessage(0),
        close: () => {
          channel.port1.onmessage = null;
          channel.port1.close();
          channel.port2.close();
        },
      };
      this.stops.push(() => {
        this.channel?.close();
        this.channel = undefined;
      });
    }
    this.wake("reflow");
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.frameHandle !== undefined) this.win.cancelAnimationFrame(this.frameHandle);
    this.frameHandle = undefined;
    this.posted = false;
    if (this.expectTimer !== undefined) this.win.clearTimeout(this.expectTimer);
    this.expectTimer = undefined;
    for (const stop of this.stops.splice(0)) stop();
    this.expects = [];
    this.previous = undefined;
  }

  private now(): number {
    return this.win.performance.now();
  }

  private heardMutations(records: MutationRecord[]): void {
    let cause: ShiftCause = "reflow";
    for (const record of records) {
      if (record.type !== "childList") continue;
      const rowIn = (nodes: NodeList) =>
        Array.from(nodes).some((node) => (node as Element).classList?.contains("acpmux-row"));
      if (rowIn(record.addedNodes)) {
        cause = "mount";
        break;
      }
      if (rowIn(record.removedNodes)) cause = "unmount";
    }
    this.wake(cause);
  }

  private wake(cause: ShiftCause): void {
    if (!this.running) return;
    // The first non-reflow cause since the last read names the frame's change, with where it was heard.
    if (!this.causes || (this.causes.cause === "reflow" && cause !== "reflow"))
      this.causes = {
        cause,
        stack: this.options.stacks ? new Error().stack?.split("\n").slice(2, 8).join("\n") : undefined,
      };
    this.arm();
  }

  private arm(): void {
    if (this.frameHandle !== undefined || this.posted) return;
    if (this.win.document.visibilityState !== "visible") return;
    this.frameHandle = this.win.requestAnimationFrame(() => {
      this.frameHandle = undefined;
      this.posted = true;
      // After the frame paints: the message runs as a task once this frame has rendered.
      if (this.channel) this.channel.post();
      else this.read();
    });
  }

  private emit(event: Omit<LayoutEvent, "frame" | "at" | "cause" | "stack"> & { cause?: ShiftCause }): void {
    const full: LayoutEvent = {
      ...event,
      cause: event.cause ?? this.causes?.cause ?? "reflow",
      frame: this.frameNo,
      at: Math.round(this.now()),
      ...(this.causes?.stack ? { stack: this.causes.stack } : {}),
    };
    this.total += 1;
    this.events.push(full);
    if (this.events.length > MAX_EVENTS) this.events.shift();
    for (const sink of this.sinks)
      try {
        sink(full);
      } catch {
        // A sink never stops the watch.
      }
  }

  private readRows(): { rows: RowRead[]; parts: FrameParts } {
    const parts: FrameParts = { elements: [] };
    const frame = readFrame(this.win.document, this.now(), parts);
    const view = this.win as WatchWindow;
    const rows = frame.rows.map((row, index): RowRead => {
      const element = parts.elements[index]!;
      const box = element.getBoundingClientRect();
      const opacity = Number(view.getComputedStyle?.(element).opacity ?? "1");
      const clockNode = element.querySelector?.<HTMLElement>(CLOCK);
      const actions = element.querySelector?.<HTMLElement>(ACTIONS);
      const text = clockNode?.textContent ?? "";
      return {
        id: row.id,
        kind: kindOf(element),
        top: row.top,
        bottom: row.top + (row.height ?? box.height),
        width: box.width,
        opaque: !(opacity < 1),
        element,
        clock: clockNode
          ? {
              width: clockNode.getBoundingClientRect().width,
              shape: text.replace(/\d/g, "0"),
              seconds: clockSeconds(text),
            }
          : undefined,
        actionRight: actions ? actions.getBoundingClientRect().right : undefined,
      };
    });
    return { rows, parts };
  }

  private read(): void {
    this.posted = false;
    if (!this.running) return;
    const doc = this.win.document;
    if (doc.visibilityState !== "visible") {
      this.previous = undefined;
      this.causes = undefined;
      return;
    }
    const now = this.now();
    this.frameNo += 1;
    this.expects = this.expects.filter((one) => one.until >= now);
    const { rows, parts } = this.readRows();
    const previous = this.previous;
    if (previous) this.checkFrame(previous, rows, now);
    this.observe(rows, parts);
    const signature = JSON.stringify(rows.map((row) => [row.id, Math.round(row.top), Math.round(row.bottom)]));
    const changed = signature !== this.previousSignature;
    this.previous = rows;
    this.previousSignature = signature;
    this.causes = undefined;
    if (changed) {
      this.settled = false;
      this.arm();
      return;
    }
    this.maybeSettle(rows, parts, now);
  }

  /// I2, I3, I5, I6, I9 and I10 between two painted frames.
  private checkFrame(previous: RowRead[], rows: RowRead[], now: number): void {
    const before = new Map(previous.map((row) => [row.id, row]));
    const byInput = now - this.lastInput <= INPUT_MS;
    const lowestBefore = previous.at(-1);
    const bottom = rows.at(-1);
    // An append: a row below every row seen, or the bottom row grown.
    const grewAtBottom =
      !!lowestBefore &&
      !!bottom &&
      bottom.id === lowestBefore.id &&
      bottom.bottom - bottom.top - (lowestBefore.bottom - lowestBefore.top) > THRESHOLD_PX;
    // A new row under where the lowest row seen is drawn now.
    const lowestNow = lowestBefore && rows.find((row) => row.id === lowestBefore.id);
    const appended =
      grewAtBottom ||
      (!!lowestNow && rows.some((row) => !before.has(row.id) && row.top >= lowestNow.bottom - THRESHOLD_PX));
    const covered = (id: string) => this.expects.some((one) => one.anchor !== id && (!one.rows || one.rows.has(id)));

    // I2
    if (!byInput) {
      let worst: { row: RowRead; delta: number; expect?: string } | undefined;
      for (const row of rows) {
        const old = before.get(row.id);
        if (!old || !moved(old.top, row.top)) continue;
        const delta = row.top - old.top;
        const anchored = this.expects.find((one) => one.anchor === row.id);
        let expect: string | undefined;
        if (anchored) expect = anchored.reason;
        else if (appended || covered(row.id)) continue;
        else if (this.expects.length) expect = this.expects[0]!.reason;
        if (!worst || Math.abs(delta) > Math.abs(worst.delta)) worst = { row, delta, expect };
      }
      if (worst)
        this.emit({
          invariant: "I2",
          rowId: worst.row.id,
          deltaPx: round1(worst.delta),
          ...(worst.expect ? { expect: worst.expect } : {}),
        });
    }

    // I3: the widest band between the first and last rows in view that no opaque row covers.
    let reach = rows[0]?.top ?? 0;
    let band: { below: RowRead; px: number } | undefined;
    for (const row of rows) {
      if (row.opaque) {
        const px = row.top - reach;
        if (px > BAND_PX && (!band || px > band.px)) band = { below: row, px };
        reach = Math.max(reach, row.bottom);
      }
    }
    if (band) {
      const key = `I3:${band.below.id}`;
      if (!this.reported.has(key)) {
        this.reported.add(key);
        this.emit({ invariant: "I3", rowId: band.below.id, selector: "band", deltaPx: round1(band.px) });
      }
    } else for (const key of this.reported) if (key.startsWith("I3:")) this.reported.delete(key);

    // I5, I6, I9, I10 per row seen in both frames.
    const resized = new Set<string>();
    for (const row of rows) {
      const old = before.get(row.id);
      if (!old) continue;
      if (moved(old.bottom - old.top, row.bottom - row.top)) {
        resized.add(row.id);
        const key = `I5:${row.id}`;
        if (this.resized.has(row.id) && row !== bottom && !covered(row.id) && !this.reported.has(key)) {
          this.reported.add(key);
          this.emit({
            invariant: "I5",
            rowId: row.id,
            cause: "resize",
            deltaPx: round1(row.bottom - row.top - (old.bottom - old.top)),
          });
        }
      } else this.reported.delete(`I5:${row.id}`);
      if (old.kind !== row.kind || old.element !== row.element)
        this.emit({
          invariant: "I6",
          rowId: row.id,
          selector: old.kind !== row.kind ? `kind ${old.kind} -> ${row.kind}` : "element",
          cause: "mount",
          deltaPx: 0,
        });
      if (old.clock && row.clock) {
        if (old.clock.shape === row.clock.shape && moved(old.clock.width, row.clock.width))
          this.emit({
            invariant: "I9",
            rowId: row.id,
            selector: CLOCK,
            deltaPx: round1(row.clock.width - old.clock.width),
          });
        else if (
          old.clock.seconds !== undefined &&
          row.clock.seconds !== undefined &&
          row.clock.seconds < old.clock.seconds
        )
          this.emit({ invariant: "I9", rowId: row.id, selector: `${CLOCK} fell`, deltaPx: 0 });
      }
      if (
        !byInput &&
        old.actionRight !== undefined &&
        row.actionRight !== undefined &&
        !moved(old.width, row.width) &&
        moved(old.actionRight, row.actionRight)
      )
        this.emit({
          invariant: "I10",
          rowId: row.id,
          selector: ACTIONS,
          deltaPx: round1(row.actionRight - old.actionRight),
        });
    }
    this.resized = resized;

    // I6: a row that went in the frame one with its id's tail came.
    const ids = new Set(rows.map((row) => row.id));
    const gone = previous.filter((row) => !ids.has(row.id));
    if (gone.length) {
      const goneTails = new Map(gone.map((row) => [idTail(row.id), row]));
      for (const row of rows) {
        if (before.has(row.id)) continue;
        const tail = idTail(row.id);
        const was = goneTails.get(tail) ?? goneTails.get(row.id);
        if (was && tail.length >= 4 && Math.abs(row.top - was.top) <= Math.max(24, was.bottom - was.top))
          this.emit({
            invariant: "I6",
            rowId: row.id,
            selector: `${was.kind || "row"} -> ${row.kind || "row"}`,
            cause: "mount",
            deltaPx: 0,
          });
      }
    }
  }

  /// Nothing changed in this frame: a settled tick, once no expect is open and no finite animation runs.
  private maybeSettle(rows: RowRead[], parts: FrameParts, now: number): void {
    if (this.settled) return;
    const open = this.expects.reduce((latest, one) => Math.max(latest, one.until), -Infinity);
    if (open >= now) {
      if (this.expectTimer !== undefined) this.win.clearTimeout(this.expectTimer);
      this.expectTimer = this.win.setTimeout(
        () => {
          this.expectTimer = undefined;
          this.wake("reflow");
        },
        Math.ceil(open - now) + 1,
      );
      return;
    }
    // A finite animation still running ends with an event that wakes the watch (transitionend,
    // animationend); infinite ones (a spinner) never settle anything.
    const animations = (this.win.document as Document).getAnimations?.() ?? [];
    if (
      animations.some(
        (one) => one.playState === "running" && Number.isFinite(one.effect?.getComputedTiming?.().endTime ?? Infinity),
      )
    )
      return;
    this.settled = true;
    this.settledTicks += 1;
    this.checkSettled(rows, parts);
    for (const listener of this.settledListeners) listener();
  }

  /// I1 and I4 on a settled frame.
  private checkSettled(rows: RowRead[], parts: FrameParts): void {
    for (let at = 1; at < rows.length; at += 1) {
      const above = rows[at - 1]!;
      const row = rows[at]!;
      const gap = row.top - above.bottom;
      if (gap > GAP_PX || gap < -THRESHOLD_PX)
        this.emit({ invariant: "I1", rowId: row.id, selector: gap < 0 ? "overlap" : "gap", deltaPx: round1(gap) });
    }
    if (!this.expectSinceSettle) return;
    this.expectSinceSettle = false;
    for (const row of rows)
      if (row.element.style?.translate)
        this.emit({ invariant: "I4", rowId: row.id, selector: "style.translate", deltaPx: 0 });
    const scope = parts.scroller;
    if (!scope) return;
    for (const fold of Array.from(scope.querySelectorAll<HTMLElement>(".cv-fold")))
      if (fold.style.height) {
        this.emit({
          invariant: "I4",
          rowId: fold.closest<HTMLElement>(".acpmux-row")?.dataset.rowId,
          selector: ".cv-fold height",
          deltaPx: 0,
        });
        break;
      }
    const left = scope.querySelector(GHOSTS);
    if (left)
      this.emit({
        invariant: "I4",
        selector: left.hasAttribute("data-fold-clip") ? "[data-fold-clip]" : "ghost",
        deltaPx: 0,
      });
  }

  /// Watches the rows in view, the composer and the scroller for resizes; rows that left view are dropped.
  private observe(rows: RowRead[], parts: FrameParts): void {
    const observer = this.resizeObserver;
    if (!observer) return;
    const wanted = new Set<Element>(rows.map((row) => row.element));
    if (parts.scroller) wanted.add(parts.scroller);
    const composer = this.win.document.querySelector(".acpmux-composer-box");
    if (composer) wanted.add(composer);
    for (const element of this.observedRows)
      if (!wanted.has(element)) {
        observer.unobserve(element);
        this.observedRows.delete(element);
      }
    for (const element of wanted)
      if (!this.observedRows.has(element)) {
        observer.observe(element);
        this.observedRows.add(element);
      }
  }
}

let active: LayoutWatcher | undefined;
/// How many holders asked for the watch (the page itself, a perf capture).
let holders = 0;
let startedBy: "page" | "lease" | undefined;

/// The page's watcher, made on first use; nothing runs until `start`.
export function pageLayoutWatcher(win: Window = window, options: { stacks?: boolean } = {}): LayoutWatcher {
  active ??= new LayoutWatcher(win, options);
  return active;
}

/// The single contract: a move that is meant (the motion owner's; until it exists, the transcript's own
/// intended-move sites). Nothing when no watch runs.
export const layoutWatch = {
  expect(reason: string, options?: ExpectOptions): () => void {
    return active?.isRunning() ? active.expect(reason, options) : () => undefined;
  },
};

/// Starts the page's watch for a holder (a perf capture's window) and returns its count and release; the
/// watch stops again on release when the page itself had not started it.
export function retainLayoutWatch(win: Window = window): { count(): number; release(): void } {
  const watcher = pageLayoutWatcher(win);
  holders += 1;
  if (!watcher.isRunning()) {
    startedBy = "lease";
    watcher.start();
  }
  let released = false;
  return {
    count: () => watcher.count(),
    release: () => {
      if (released) return;
      released = true;
      holders -= 1;
      if (holders === 0 && startedBy === "lease") {
        watcher.stop();
        startedBy = undefined;
      }
    },
  };
}

/// Whether the page watches itself: dev builds and every build that is not Release (the host's link
/// scheme is `cmux` only in Release: `cmux-nightly`, `cmux-dev-<tag>`), or a harness that asked before load.
export function layoutWatchWanted(scheme: string | undefined, dev: boolean, win: Window = window): boolean {
  if (dev) return true;
  if ((win as { __cmuxLayoutWatch?: unknown }).__cmuxLayoutWatch === true) return true;
  return scheme !== undefined && scheme !== "cmux";
}

/// The harness and console handle (`window.cmuxLayoutWatch`).
export type LayoutWatchHandle = {
  start(): void;
  stop(): void;
  running(): boolean;
  unexplained(): LayoutEvent[];
  clear(): void;
  settled(): number;
  expect(reason: string, options?: ExpectOptions): () => void;
  overlay(on: boolean): void;
};

declare global {
  interface Window {
    cmuxLayoutWatch?: LayoutWatchHandle;
  }
}

const OVERLAY_MS = 1_000; // motion-allow: how long an offender stays outlined, not an animation

/// Outlines `event`'s row for OVERLAY_MS (dev builds).
function outline(win: Window, event: LayoutEvent): void {
  if (!event.rowId) return;
  const doc = win.document;
  const row = Array.from(doc.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")).find(
    (one) => one.dataset.rowId === event.rowId,
  );
  if (!row) return;
  const box = row.getBoundingClientRect();
  const mark = doc.createElement("div");
  mark.setAttribute("data-layout-watch-mark", event.invariant);
  mark.style.cssText = `position:fixed;pointer-events:none;z-index:2147483647;left:${box.left}px;top:${box.top}px;width:${box.width}px;height:${box.height}px;outline:2px solid magenta;`; // colour-allow: a dev-only debug outline
  doc.body.appendChild(mark);
  win.setTimeout(() => mark.remove(), OVERLAY_MS);
}

/// Sets up `window.cmuxLayoutWatch` and starts the page's watch when `wanted`: events go to `record` (the
/// flicker ring), to the console and, with `overlay`, to an outline in dev builds.
export function installLayoutWatch(
  win: Window,
  options: { wanted: boolean; dev: boolean; record?: (event: LayoutEvent) => void },
): LayoutWatcher {
  const watcher = pageLayoutWatcher(win, { stacks: options.wanted });
  let overlayOn = false;
  try {
    overlayOn = options.dev && win.localStorage?.getItem("cmux.layoutWatch.overlay") === "1";
  } catch {
    // No storage: no overlay until asked.
  }
  if (!win.cmuxLayoutWatch) {
    watcher.addSink((event) => {
      options.record?.(event);
      if (options.dev)
        console.warn("[layoutWatch]", event.invariant, event.rowId ?? event.selector, event.deltaPx, event);
      if (overlayOn) outline(win, event);
    });
    win.cmuxLayoutWatch = {
      start: () => {
        startedBy = "page";
        watcher.start();
      },
      stop: () => watcher.stop(),
      running: () => watcher.isRunning(),
      unexplained: () => watcher.unexplained(),
      clear: () => watcher.clear(),
      settled: () => watcher.settledCount(),
      expect: (reason, expectOptions) => layoutWatch.expect(reason, expectOptions),
      overlay: (on) => {
        overlayOn = on;
      },
    };
  }
  if (options.wanted && !watcher.isRunning()) win.cmuxLayoutWatch.start();
  return watcher;
}

/// Tests: the page starts again with no watch.
export function resetLayoutWatchForTests(): void {
  active?.stop();
  active = undefined;
  holders = 0;
  startedBy = undefined;
}

// A harness that asked before load (test/support/layoutWatch.ts `watchLayoutFromLoad`) watches from the
// first module that declares a move, gallery pages that never run the pane's handshake too.
if (typeof window !== "undefined" && (window as { __cmuxLayoutWatch?: unknown }).__cmuxLayoutWatch === true)
  installLayoutWatch(window, { wanted: true, dev: false });
