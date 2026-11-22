// The chat page's relaunch record, only while a launch harness reads the launch marks (`__cmuxLaunchMeasured`,
// the host's `__snapshot/chat.js`, AgentPaneChatSnapshots): from the bundle's start it records, frame by frame,
// what a person sees redo itself on a chat they already read. scripts/cmux-next/relaunch-settled-bench.py reads
// the record from `debug.agent_pane {action: "layout_watch"}` (its `relaunch` field) after each relaunch.
// Leo 2026-11-22: "composer dips down then goes back up. then the crazy fucking stupid folding animations
// somehow replay ... then the top half of the chat blanked out ... then the scroll rail re-rednered. and then
// more shit re-rendered."
//
// Per frame it reads the layer on top (the chat's saved copy's shadow root while it shows, else the live
// page, as launchSettle.ts): the composer's height, whether the top half of the transcript shows any row,
// the scroll rail's node and box, and the rows' ids. First content is the first frame with a composer and a
// row (or the scroller). From there it counts composer height changes, blank top-half frames, rail redraws
// and DOM mutations inside rows that were there at first content, and it lists every animation or
// transition that starts on a transcript element (CSS, Web Animations: the fold's and growth's
// `rows.animate`) with the row it moved. It changes nothing on screen and ends at CAP_MS.

import { SNAPSHOT_HOST_TAG } from "./chatSnapshot/shared";

/// The record ends this long after it starts.
export const CAP_MS = 20_000;
/// A composer height change of no more than this is no change (layoutWatch.ts `tolerance`).
const TOLERANCE_PX = 1;
/// At most this many animations and mutated rows are listed (the counts keep counting).
const MAX_LISTED = 200;

const ROWS = ".acpmux-row[data-row-id]";
const RAIL = ".acpmux-scrollmap";
const DISCONNECTED = '.cv-subagent-done-row[data-state="disconnected"]';

export type RelaunchAnimation = { at: number; kind: string; name: string; row: string; settled: boolean };

export type RelaunchReport = {
  started_page_ms: number;
  first_content_ms: number | null;
  frames: number;
  elapsed_ms: number;
  ended: boolean;
  composer_heights: number[];
  composer_height_changes: number;
  chat_blank_frames: number;
  blank_ms: number;
  scroll_rail_renders: number;
  rail_nodes: number;
  rerenders: number;
  rerendered_rows: string[];
  copy_swaps: number;
  animations: RelaunchAnimation[];
  replayed_animations: number;
  first_rows: string[];
  disconnected_rows: string[];
};

/// One frame's reading of the layer on top.
export type RelaunchFrame = {
  at: number;
  composer?: number;
  rows: string[];
  topHalfRows: number;
  scroller: boolean;
  rail?: { node: object; box: string };
  layer: object;
  disconnected: string[];
};

/// The record's bookkeeping, apart from the page (tests drive it with frames of their own). Times are ms from
/// the record's start.
export class RelaunchRecord {
  private firstContent: number | null = null;
  private frames = 0;
  private last = 0;
  private previous: RelaunchFrame | undefined;
  private readonly heights: number[] = [];
  private heightChanges = 0;
  private blankFrames = 0;
  private blankMs = 0;
  private railRenders = 0;
  private readonly railNodes = new Set<object>();
  private rerenders = 0;
  private readonly rerendered = new Set<string>();
  private swaps = 0;
  private readonly animations: RelaunchAnimation[] = [];
  private replayed = 0;
  private firstRows = new Set<string>();
  private disconnected = new Set<string>();
  ended = false;

  constructor(readonly startedPageMs: number) {}

  get contentShown(): boolean {
    return this.firstContent !== null;
  }

  frame(frame: RelaunchFrame): void {
    this.frames += 1;
    const previous = this.previous;
    this.previous = frame;
    const interval = previous ? frame.at - previous.at : 0;
    this.last = frame.at;
    for (const name of frame.disconnected) this.disconnected.add(name);
    if (this.firstContent === null) {
      if (frame.composer === undefined || (!frame.rows.length && !frame.scroller)) return;
      this.firstContent = frame.at;
      this.firstRows = new Set(frame.rows);
      if (frame.composer !== undefined) this.heights.push(Math.round(frame.composer));
      if (frame.rail) this.railNodes.add(frame.rail.node);
      return;
    }
    const height = frame.composer;
    const lastHeight = this.heights.at(-1);
    if (height !== undefined && (lastHeight === undefined || Math.abs(height - lastHeight) > TOLERANCE_PX)) {
      if (lastHeight !== undefined) this.heightChanges += 1;
      this.heights.push(Math.round(height));
    }
    // The top half of the transcript shows no row, or the transcript went away.
    if (this.firstRows.size && (!frame.scroller || frame.topHalfRows === 0)) {
      this.blankFrames += 1;
      this.blankMs += interval;
    }
    if (previous?.layer !== frame.layer) this.swaps += previous ? 1 : 0;
    const rail = frame.rail;
    const before = previous?.rail;
    if (rail && !this.railNodes.has(rail.node)) {
      this.railNodes.add(rail.node);
      // The copy's swap to the live page draws a new rail: the same box in the swap's frame draws nothing new.
      if (!(before && before.box === rail.box && previous?.layer !== frame.layer)) this.railRenders += 1;
    } else if (rail && before && rail.node === before.node && rail.box !== before.box) this.railRenders += 1;
    else if (!rail && before) this.railRenders += 1;
  }

  /// A batch of DOM mutations seen in one task: `rows` are the ids of the rows they touched (the rail's own as "rail").
  mutated(rows: Iterable<string>): void {
    if (this.firstContent === null) return;
    for (const row of rows) {
      if (row === "rail") {
        this.railRenders += 1;
        continue;
      }
      if (!this.firstRows.has(row)) continue;
      this.rerenders += 1;
      if (this.rerendered.size < MAX_LISTED) this.rerendered.add(row);
    }
  }

  /// An animation or transition started at `at` on `row` (a row id, "rows" for the transcript's row stack).
  animated(at: number, kind: string, name: string, row: string): void {
    const settled = row === "rows" ? this.firstRows.size > 0 : this.firstRows.has(row);
    if (settled && this.firstContent !== null) this.replayed += 1;
    if (this.animations.length < MAX_LISTED) this.animations.push({ at: Math.round(at), kind, name, row, settled });
  }

  report(): RelaunchReport {
    return {
      started_page_ms: Math.round(this.startedPageMs),
      first_content_ms: this.firstContent === null ? null : Math.round(this.firstContent),
      frames: this.frames,
      elapsed_ms: Math.round(this.last),
      ended: this.ended,
      composer_heights: this.heights.slice(0, MAX_LISTED),
      composer_height_changes: this.heightChanges,
      chat_blank_frames: this.blankFrames,
      blank_ms: Math.round(this.blankMs),
      scroll_rail_renders: this.railRenders,
      rail_nodes: this.railNodes.size,
      rerenders: this.rerenders,
      rerendered_rows: [...this.rerendered],
      copy_swaps: this.swaps,
      animations: this.animations,
      replayed_animations: this.replayed,
      first_rows: [...this.firstRows].slice(0, MAX_LISTED),
      disconnected_rows: [...this.disconnected],
    };
  }
}

/// The layer on top: the copy's shadow root while it shows, else the live document; undefined while the live
/// root is held clear with no copy over it.
function topLayer(doc: Document, hostTag: string): ParentNode | undefined {
  const drawn = doc.querySelector<HTMLElement>(hostTag);
  const host = drawn && drawn.style.visibility !== "hidden" ? drawn : null;
  if (host?.shadowRoot) return host.shadowRoot;
  if (doc.getElementById("root")?.style.opacity === "0") return undefined;
  return doc;
}

const boxText = (rect: DOMRectReadOnly) =>
  `${Math.round(rect.x)},${Math.round(rect.y)},${Math.round(rect.width)},${Math.round(rect.height)}`;

/// Reads one frame of the layer on top.
export function readRelaunchFrame(doc: Document, hostTag: string, at: number): RelaunchFrame {
  const layer = topLayer(doc, hostTag);
  const frame: RelaunchFrame = { at, rows: [], topHalfRows: 0, scroller: false, layer: layer ?? doc, disconnected: [] };
  if (!layer) return frame;
  const composer = [...layer.querySelectorAll(".acpmux-composer-box")]
    .map((element) => element.getBoundingClientRect())
    .find((rect) => rect.height > 0);
  if (composer) frame.composer = composer.height;
  const scroller = layer.querySelector<HTMLElement>(".acpmux-scroll");
  const view = scroller?.getBoundingClientRect();
  frame.scroller = !!view && view.height > 0;
  const middle = view ? view.top + view.height / 2 : 0;
  const style = doc.defaultView;
  for (const row of layer.querySelectorAll<HTMLElement>(ROWS)) {
    const id = row.dataset.rowId!;
    frame.rows.push(id);
    if (!view) continue;
    const rect = row.getBoundingClientRect();
    if (rect.height <= 0 || rect.bottom <= view.top || rect.top >= middle) continue;
    if (Number(style?.getComputedStyle(row).opacity) === 0) continue;
    frame.topHalfRows += 1;
  }
  const rail = layer.querySelector<HTMLElement>(RAIL);
  if (rail) frame.rail = { node: rail, box: boxText(rail.getBoundingClientRect()) };
  for (const row of layer.querySelectorAll<HTMLElement>(DISCONNECTED))
    frame.disconnected.push((row.textContent ?? "").trim().slice(0, 120));
  return frame;
}

/// The row an element is in: its id, "rows" for the transcript's row stack, "rail" for the scroll rail, else "".
function rowOf(node: Node | null): string {
  const element = node && node.nodeType === 1 ? (node as Element) : node?.parentElement;
  if (!element) return "";
  const row = element.closest<HTMLElement>(ROWS);
  if (row) return row.dataset.rowId ?? "";
  if (element.closest(RAIL)) return "rail";
  if (element.querySelector(ROWS)) return "rows";
  return "";
}

let record: RelaunchRecord | undefined;

/// The record so far, or null when none runs (`layout_watch`'s `relaunch` field).
export function relaunchWatchReport(): RelaunchReport | null {
  return record?.report() ?? null;
}

/// Starts this document's relaunch record when a launch harness reads the launch marks; later calls do nothing.
/// The flag may come after the bundle starts (the host's script loads `async`), so it waits for its event.
export function watchRelaunch(doc: Document = document, hostTag = SNAPSHOT_HOST_TAG): void {
  const view = doc.defaultView;
  if (!view || record) return;
  const measured = () => (view as Window & { __cmuxLaunchMeasured?: boolean }).__cmuxLaunchMeasured === true;
  if (!measured()) {
    view.addEventListener("cmux-restored-chat", () => measured() && watchRelaunch(doc, hostTag), { once: true });
    return;
  }
  const origin = view.performance.now();
  const now = () => view.performance.now() - origin;
  const current = new RelaunchRecord(origin);
  record = current;
  const seen = new WeakSet<Animation>();
  const watchedRoots = new WeakSet<Node>();
  const observer = new MutationObserver((mutations) => {
    const rows = new Set<string>();
    for (const mutation of mutations) {
      if (!topLayerHas(mutation.target)) continue;
      const row = rowOf(mutation.target);
      if (row && row !== "rows") rows.add(row);
    }
    current.mutated(rows);
  });
  const topLayerHas = (node: Node) => {
    const layer = topLayer(doc, hostTag);
    return !!layer && layer === node.getRootNode();
  };
  const onAnimation = (event: Event) => {
    const target = event.target as Element | null;
    if (!target || !topLayerHas(target)) return;
    const row = rowOf(target);
    if (!row || row === "rail") return;
    const name = (event as AnimationEvent).animationName ?? (event as TransitionEvent).propertyName ?? event.type;
    current.animated(now(), event.type, name, row);
  };
  const watchRoot = (root: Document | ShadowRoot) => {
    if (watchedRoots.has(root)) return;
    watchedRoots.add(root);
    observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
    root.addEventListener("animationstart", onAnimation, true);
    root.addEventListener("transitionstart", onAnimation, true);
  };
  watchRoot(doc);
  const sampleAnimations = (root: Document | ShadowRoot) => {
    for (const animation of root.getAnimations?.() ?? []) {
      if (seen.has(animation)) continue;
      seen.add(animation);
      // CSS ones are counted by their start events.
      if (/^CSS(Animation|Transition)$/.test(animation.constructor.name)) continue;
      const target = (animation.effect as KeyframeEffect | null)?.target ?? null;
      const row = rowOf(target);
      if (!row || row === "rail" || !target || !topLayerHas(target)) continue;
      current.animated(now(), "web-animation", animation.id || "animate", row);
    }
  };
  const tick = () => {
    const at = now();
    const host = doc.querySelector<HTMLElement>(hostTag);
    if (host?.shadowRoot) watchRoot(host.shadowRoot);
    sampleAnimations(doc);
    if (host?.shadowRoot) sampleAnimations(host.shadowRoot);
    current.frame(readRelaunchFrame(doc, hostTag, at));
    if (at >= CAP_MS) {
      current.ended = true;
      observer.disconnect();
      return;
    }
    view.requestAnimationFrame(tick);
  };
  view.requestAnimationFrame(tick);
}

/// Tests start over with no record.
export function resetRelaunchWatchForTests(): void {
  record = undefined;
}
