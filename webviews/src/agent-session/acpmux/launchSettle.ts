// The chat page's launch settle, in every build: once per document, from the page's first paint (the
// chat's saved copy, chatSnapshot/, or the live chat, whichever drew first) it watches what still moves
// and reports it once (`pane.launchSettle`), which the host turns into launch marks on the process's
// clock (AgentPaneLaunchTimings `layoutSettle`): `web.layout.settle` (when the page last moved, or its
// first paint when nothing did), `web.layout.max_move` and `web.layout.max_move.<element>` (the largest
// move, CSS px) and `web.layout.shifts` (how many frames moved). A launch harness reads them per launch
// (scripts/measure/launch-ready.swift); with none listening the host drops them.
//
// "Moved" is the first-load bench's (bench/first-load-after-restart.bench.ts): the composer's box, the
// transcript's scroller and the transcript rows in view (by row id, so a row keeps its name across the
// copy's swap to the live page), read on the layer on top (the copy's shadow root while it shows),
// moving or resizing by more than layoutWatch.ts's 1 px tolerance. A move is measured from where the
// element was when first seen after first paint (layoutWatch.ts). Chromium's layout-shift entries add
// the elements the frame reads do not cover (WebKit has none; the frame reads are the measure there).
//
// It reads boxes once per frame and changes nothing on screen. It ends after QUIET_MS with nothing
// moving, at CAP_MS, at the person's first press, key or wheel (what moves after is theirs), and when the
// page is hidden (no report then: a hidden page draws no frames, so its count would be wrong).

import { SNAPSHOT_HOST_TAG } from "./chatSnapshot/shared";

export type SettleBox = { x: number; y: number; w: number; h: number };

/// The watch ends after this long with nothing moving.
export const QUIET_MS = 1_500;
/// The watch ends this long after first paint, moving or not. The page paints about 1 s after the window shows, and
/// launch-ready quits the app 6 s after it shows, so the report must come before then.
export const CAP_MS = 4_000;
/// A box that moved by no more than this did not move (layoutWatch.ts `tolerance`).
export const TOLERANCE_PX = 1;
/// A layout-shift entry this close to a frame already counted is that frame's move.
const SAME_FRAME_MS = 16;

/// What the page reports (`pane.launchSettle`); times are ms since 1970.
export type LaunchSettleReport = {
  settledEpochMs: number;
  maxMovePx: number;
  element: string;
  shifts: number;
};

/// The short name of a tracked key (`transcript-row:<id>` reads `transcript-row`).
const elementOf = (key: string) => key.split(":", 1)[0]!;

const moveOf = (from: SettleBox, to: SettleBox) =>
  Math.max(Math.abs(to.x - from.x), Math.abs(to.y - from.y), Math.abs(to.w - from.w), Math.abs(to.h - from.h));

/// The settle's bookkeeping, apart from the page (tests drive it with frames of their own).
export class LaunchSettle {
  private readonly first = new Map<string, SettleBox>();
  private previous = new Map<string, SettleBox>();
  private readonly shiftTimes: number[] = [];
  private lastShift: number | undefined;
  private maxMove = 0;
  private maxElement = "none";

  /// `start`: the first paint, ms since 1970.
  constructor(readonly start: number) {}

  /// One frame's boxes at `at` (ms since 1970). An element seen first now did not move.
  frame(at: number, boxes: ReadonlyMap<string, SettleBox>): void {
    let moved = false;
    for (const [key, box] of boxes) {
      const before = this.previous.get(key);
      const origin = this.first.get(key);
      if (!origin) this.first.set(key, box);
      if (before && moveOf(before, box) > TOLERANCE_PX) moved = true;
      if (origin) this.note(key, moveOf(origin, box));
    }
    this.previous = new Map(boxes);
    if (moved) this.shifted(at);
  }

  /// A layout shift the engine reported (Chromium's layout-shift entry): `element` moved `px` at `at`.
  shift(at: number, element: string, px: number): void {
    if (px <= TOLERANCE_PX) return;
    this.note(element, px);
    this.shifted(at);
  }

  private note(key: string, px: number): void {
    if (px <= this.maxMove || px <= TOLERANCE_PX) return;
    this.maxMove = px;
    this.maxElement = elementOf(key);
  }

  private shifted(at: number): void {
    if (this.shiftTimes.some((time) => Math.abs(time - at) < SAME_FRAME_MS)) return;
    this.shiftTimes.push(at);
    this.lastShift = Math.max(this.lastShift ?? at, at);
  }

  /// Whether the watch is over at `now`: quiet for QUIET_MS, or CAP_MS after first paint.
  done(now: number): boolean {
    return now - (this.lastShift ?? this.start) >= QUIET_MS || now - this.start >= CAP_MS;
  }

  report(): LaunchSettleReport {
    return {
      settledEpochMs: Math.round(this.lastShift ?? this.start),
      maxMovePx: Math.round(this.maxMove),
      element: this.maxElement,
      shifts: this.shiftTimes.length,
    };
  }
}

const ROWS = ".acpmux-row[data-row-id]";

/// The short name of a node a layout-shift entry moved.
function classify(node: Node | null | undefined): string {
  const element = node && node.nodeType === 1 ? (node as Element) : node?.parentElement;
  if (!element) return "other";
  if (element.closest(".acpmux-row")) return "transcript-row";
  if (element.closest(".acpmux-composer-box, .acpmux-composer")) return "composer";
  if (element.closest(".acpmux-scroll")) return "scroller";
  if (element.closest("header, [role=banner]")) return "header";
  return "other";
}

const boxOf = (rect: DOMRectReadOnly): SettleBox => ({ x: rect.x, y: rect.y, w: rect.width, h: rect.height });

/// The tracked boxes on the layer on top (bench `recordFrames`): the copy's shadow root while it
/// shows, else the live document; nothing while the live root is held clear with no copy over it.
export function readSettleBoxes(doc: Document, hostTag: string): Map<string, SettleBox> {
  const boxes = new Map<string, SettleBox>();
  const drawn = doc.querySelector<HTMLElement>(hostTag);
  const host = drawn && drawn.style.visibility !== "hidden" ? drawn : null;
  if (!host && doc.getElementById("root")?.style.opacity === "0") return boxes;
  const scope: ParentNode = host?.shadowRoot ?? doc;
  const composer = [...scope.querySelectorAll(".acpmux-composer-box")]
    .map((element) => element.getBoundingClientRect())
    .find((rect) => rect.height > 0);
  if (composer) boxes.set("composer", boxOf(composer));
  const scroller = scope.querySelector<HTMLElement>(".acpmux-scroll");
  const view = scroller?.getBoundingClientRect();
  if (!scroller || !view || view.height <= 0) return boxes;
  boxes.set("scroller", boxOf(view));
  for (const row of scope.querySelectorAll<HTMLElement>(ROWS)) {
    const rect = row.getBoundingClientRect();
    if (rect.height <= 0 || rect.bottom <= view.top || rect.top >= view.bottom) continue;
    if (Number(doc.defaultView?.getComputedStyle(row).opacity) === 0) continue;
    boxes.set(`transcript-row:${row.dataset.rowId}`, boxOf(rect));
  }
  return boxes;
}

type ShiftEntry = PerformanceEntry & {
  hadRecentInput?: boolean;
  sources?: { node?: Node | null; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly }[];
};

let started = false;

/// Starts this document's settle watch at its first paint; later calls do nothing. `report` sends the
/// result once (`pane.launchSettle`). Returns the stop (ends the watch without reporting).
export function watchLaunchSettle(
  report: (method: string, params: Record<string, unknown>) => Promise<unknown>,
  hostTag = SNAPSHOT_HOST_TAG,
  doc: Document = document,
): () => void {
  const view = doc.defaultView;
  // Only while a launch harness reads the marks: the host's `__snapshot/chat.js` says so (AgentPaneChatSnapshots).
  // A person's launch runs nothing here.
  const measured = (view as (Window & { __cmuxLaunchMeasured?: boolean }) | null)?.__cmuxLaunchMeasured === true;
  if (started || !view || !measured || doc.visibilityState === "hidden") return () => {};
  started = true;
  const settle = new LaunchSettle(Date.now());
  let frame: number | undefined;
  let observer: PerformanceObserver | undefined;
  let ended = false;
  const inputs = ["pointerdown", "keydown", "wheel"] as const;
  const stop = () => {
    if (ended) return;
    ended = true;
    if (frame !== undefined) view.cancelAnimationFrame(frame);
    view.clearTimeout(cap);
    observer?.disconnect();
    for (const name of inputs) view.removeEventListener(name, finish, true);
    doc.removeEventListener("visibilitychange", hidden);
  };
  function finish() {
    if (ended) return;
    stop();
    void report("pane.launchSettle", settle.report()).catch(() => undefined);
  }
  function hidden() {
    if (doc.visibilityState === "hidden") stop();
  }
  const tick = () => {
    frame = undefined;
    const now = Date.now();
    settle.frame(now, readSettleBoxes(doc, hostTag));
    if (settle.done(now)) finish();
    else frame = view.requestAnimationFrame(tick);
  };
  // A frame that never comes (the page hidden without a visibility change) still ends the watch.
  const cap = view.setTimeout(finish, CAP_MS);
  for (const name of inputs) view.addEventListener(name, finish, { capture: true, passive: true });
  doc.addEventListener("visibilitychange", hidden);
  try {
    // Entry times are the page's clock; the wall clock's offset to it is taken once, now.
    const offset = Date.now() - view.performance.now();
    observer = new view.PerformanceObserver((list) => {
      for (const entry of list.getEntries() as ShiftEntry[]) {
        if (entry.hadRecentInput) continue;
        for (const source of entry.sources ?? [])
          settle.shift(
            offset + entry.startTime,
            classify(source.node),
            moveOf(boxOf(source.previousRect), boxOf(source.currentRect)),
          );
      }
    });
    observer.observe({ type: "layout-shift" });
  } catch {
    // An engine with no layout-shift entries (WebKit): the frame reads are the measure.
    observer = undefined;
  }
  tick();
  return stop;
}

/// Tests: lets a fresh document start a watch again.
export function resetLaunchSettleForTest(): void {
  started = false;
}
