// The layout-stability watcher (docs/design/transcript-motion-model.md, "The gate"). Leo, 2026-11-17:
// "all this shift stuff is so goofy like we should be able to have a system that just detects when
// things are coming in or out".
//
// It only detects; it never moves anything. After each painted frame it compares every visible
// transcript row with the frame before and flags a row that entered, left or moved, unless the move is
// explained by:
// - reader input in the last INPUT_GRACE_MS;
// - an append at the bottom, or the last row growing while a turn streams (and the follow scroll that
//   keeps it in view);
// - a declared move: `expect(reason, {rows, ms})`, which only the motion owner calls (motionOwner.ts).
//
// So a move the owner did not start is flagged, and a row component that moves something on its own
// is caught without a rule per component. The invariants it checks are the doc's I1-I6, I9 and I10;
// I7 and I8 are browser tests (chat-fold-frame-budget, paneAncestorHas).
//
// This file is two halves: `judgeFrame`, a pure function over two frames' row boxes (unit tested), and
// `startLayoutWatch`, which reads those boxes from the DOM once per frame while it is on.
//
// Cost and stop condition: on only in dev, while the perf watch is on, or when asked
// (`localStorage["cmux.layoutWatch"] = "1"`); one frame callback per frame reading the visible rows'
// boxes; it stops when its stop function is called (the transcript unmounts) and pauses while the page
// is hidden. First PR: warn-only (console and overlay), never a failure.

import { CHAT_MOTION_ATTR, MINIMAL_MOTION } from "./frameBudget";

/// Reader input this recent explains any move.
export const INPUT_GRACE_MS = 300;
/// A band with no row this tall between the first and last visible rows is a blank frame (I3).
export const BLANK_BAND_PX = 40;
/// Moves under this are rounding.
export const SHIFT_TOLERANCE_PX = 1;
/// A row that unmounts and mounts again within this many frames while its data lives broke identity (I6).
const IDENTITY_FRAMES = 3;
/// Flags kept for a reader (debug automation, the overlay).
const KEPT_FLAGS = 200;

export type ShiftCause = "mount" | "unmount" | "resize" | "reflow";
export type Invariant = "I1" | "I2" | "I3" | "I4" | "I5" | "I6" | "I9" | "I10";

/// One visible row as a frame drew it. Tops are in the viewport (what the reader sees); `scrollTop` on
/// the frame turns them into list positions.
export type RowBox = {
  top: number;
  height: number;
  /// The row's kind and root element, for identity (I6).
  kind?: string;
  tag?: string;
  /// The designed gap above this row (`data-gap`), when the row says it (I1 hole check).
  gapAbove?: number;
  /// The right edge of the row's actions slot and the row's text length, for I10.
  actionsRight?: number;
  textLength?: number;
  /// A clock in the row: its text and drawn width, for I9.
  clockText?: string;
  clockWidth?: number;
};

export type WatchFrame = {
  frame: number;
  /// performance.now() of the read.
  at: number;
  scrollTop: number;
  /// Rows in list order (top to bottom), visible ones only.
  order: string[];
  rows: Map<string, RowBox>;
  /// The id of the list's last row (mounted or not): an append changes it.
  lastRowId?: string;
  /// A turn streams into the last row.
  streaming: boolean;
};

export type Expectation = {
  reason: string;
  /// The rows the move may touch; undefined: every row.
  rows?: ReadonlySet<string>;
  /// The row that must stay on its pixel.
  anchorRow?: string;
  from: number;
  until: number;
};

export type ShiftFlag = {
  rowId: string;
  invariant: Invariant;
  cause: ShiftCause;
  deltaPx: number;
  frame: number;
  detail?: string;
  stack?: string;
};

/// What the judge carries from frame to frame.
export type JudgeState = {
  lastResize: Map<string, number>;
  gone: Map<string, { frame: number; kind?: string; tag?: string }>;
  clockSeconds: Map<string, number>;
};

export const newJudgeState = (): JudgeState => ({ lastResize: new Map(), gone: new Map(), clockSeconds: new Map() });

/// A clock's text as seconds ("14h 53m", "1m 05s", "12s", "1:05"), or undefined.
export function clockSeconds(text: string): number | undefined {
  const colon = /^(\d+):(\d{2})(?::(\d{2}))?$/.exec(text.trim());
  if (colon) {
    const [a, b, c] = [colon[1], colon[2], colon[3]].map((part) => (part === undefined ? undefined : Number(part)));
    return c === undefined ? a! * 60 + b! : a! * 3600 + b! * 60 + c;
  }
  let total = 0;
  let any = false;
  for (const match of text.matchAll(/(\d+(?:\.\d+)?)\s*(h|m|s)\b/g)) {
    any = true;
    total += Number(match[1]) * (match[2] === "h" ? 3600 : match[2] === "m" ? 60 : 1);
  }
  return any ? total : undefined;
}

/// A clock's shape: its text with every digit as 0, so "9s" -> "10s" is a new shape and may widen.
const clockShape = (text: string) => text.replace(/\d/g, "0");

const live = (expects: readonly Expectation[], at: number) =>
  expects.filter((expect) => at >= expect.from && at <= expect.until);

const named = (expects: readonly Expectation[], id: string) =>
  expects.some((expect) => !expect.rows || expect.rows.has(id));

/// What explains a change above `id` in list order between two frames, as a cause.
function causeAbove(prev: WatchFrame, next: WatchFrame, id: string): ShiftCause {
  const before = new Set(prev.order.slice(0, Math.max(0, prev.order.indexOf(id))));
  const after = next.order.slice(0, Math.max(0, next.order.indexOf(id)));
  if (after.some((row) => !before.has(row))) return "mount";
  if ([...before].some((row) => !after.includes(row))) return "unmount";
  if (
    after.some(
      (row) => Math.abs((prev.rows.get(row)?.height ?? 0) - (next.rows.get(row)?.height ?? 0)) > SHIFT_TOLERANCE_PX,
    )
  )
    return "resize";
  return "reflow";
}

/**
 * The flags one frame raises against the frame before it. Pure: the DOM half reads the frames.
 * `inputAt` is the last reader input's time; `expects` every declared move, live or not.
 */
export function judgeFrame(
  prev: WatchFrame | undefined,
  next: WatchFrame,
  options: { inputAt: number; expects: readonly Expectation[]; state: JudgeState },
): ShiftFlag[] {
  const flags: ShiftFlag[] = [];
  const { state } = options;
  const flag = (rowId: string, invariant: Invariant, cause: ShiftCause, deltaPx: number, detail?: string) =>
    flags.push({
      rowId,
      invariant,
      cause,
      deltaPx: Math.round(deltaPx * 10) / 10,
      frame: next.frame,
      ...(detail ? { detail } : {}),
    });
  const input = next.at - options.inputAt <= INPUT_GRACE_MS;
  const expects = live(options.expects, next.at);
  const lastId = next.order.at(-1);

  // I3, every frame: an uncovered band between the first and last visible rows.
  for (let index = 1; index < next.order.length; index++) {
    const above = next.rows.get(next.order[index - 1]!)!;
    const below = next.rows.get(next.order[index]!)!;
    const band = below.top - (above.top + above.height);
    if (band > BLANK_BAND_PX && !input && !expects.length)
      flag(next.order[index]!, "I3", "reflow", band, "blank band above");
  }

  // I6: a row that left and came back within a few frames, or changed kind or element in place.
  for (const id of next.order) {
    const row = next.rows.get(id)!;
    const gone = state.gone.get(id);
    if (gone && next.frame - gone.frame <= IDENTITY_FRAMES) flag(id, "I6", "mount", 0, "unmounted and mounted again");
    state.gone.delete(id);
    const was = prev?.rows.get(id);
    if (was && ((was.kind && row.kind && was.kind !== row.kind) || (was.tag && row.tag && was.tag !== row.tag)))
      flag(id, "I6", "reflow", 0, `kind ${was.kind}/${was.tag} -> ${row.kind}/${row.tag}`);
  }
  for (const [id, gone] of state.gone) if (next.frame - gone.frame > IDENTITY_FRAMES) state.gone.delete(id);

  // I9: a clock never runs backwards, and keeps its width while its shape holds.
  for (const id of next.order) {
    const row = next.rows.get(id)!;
    if (row.clockText === undefined) continue;
    const seconds = clockSeconds(row.clockText);
    const previous = state.clockSeconds.get(id);
    if (seconds !== undefined) {
      if (previous !== undefined && seconds < previous)
        flag(id, "I9", "reflow", previous - seconds, "clock ran backwards");
      state.clockSeconds.set(id, seconds);
    }
    const was = prev?.rows.get(id);
    if (
      was?.clockText !== undefined &&
      was.clockWidth !== undefined &&
      row.clockWidth !== undefined &&
      clockShape(was.clockText) === clockShape(row.clockText) &&
      Math.abs(was.clockWidth - row.clockWidth) > SHIFT_TOLERANCE_PX
    )
      flag(id, "I9", "reflow", row.clockWidth - was.clockWidth, "clock width changed inside its shape");
  }

  if (!prev) return flags;
  const scrolled = next.scrollTop - prev.scrollTop;
  const appended = next.lastRowId !== prev.lastRowId;
  const lastGrew =
    lastId !== undefined &&
    lastId === prev.order.at(-1) &&
    (next.rows.get(lastId)?.height ?? 0) - (prev.rows.get(lastId)?.height ?? 0) > SHIFT_TOLERANCE_PX;
  const followed = appended || (next.streaming && lastGrew);

  for (const id of next.order) {
    const row = next.rows.get(id)!;
    const was = prev.rows.get(id);
    if (!was) {
      // I2 (mount): a row that appears between rows already on screen, not at the end and not under input.
      const index = next.order.indexOf(id);
      const between = index > 0 && index < next.order.length - 1 && prev.order.length > 0;
      if (between && !input && !named(expects, id) && !(appended && index >= next.order.length - 1))
        flag(id, "I2", "mount", row.height, "appeared between visible rows");
      continue;
    }
    // I10: the actions slot's right edge holds while the row's text changes.
    if (
      was.actionsRight !== undefined &&
      row.actionsRight !== undefined &&
      Math.abs(was.actionsRight - row.actionsRight) > SHIFT_TOLERANCE_PX &&
      was.textLength !== row.textLength
    )
      flag(id, "I10", "reflow", row.actionsRight - was.actionsRight, "actions moved with the text");
    // I5: one row resizing on consecutive frames outside streaming and outside a declared move.
    const grew = Math.abs(row.height - was.height) > SHIFT_TOLERANCE_PX;
    if (grew) {
      const streamingTail = next.streaming && id === lastId;
      const last = state.lastResize.get(id);
      if (!streamingTail && !named(expects, id) && last === prev.frame)
        flag(id, "I5", "resize", row.height - was.height, "height changed on consecutive frames (animated?)");
      state.lastResize.set(id, next.frame);
    }
    // I2: a visible row's top moved.
    const delta = row.top - was.top;
    if (Math.abs(delta) <= SHIFT_TOLERANCE_PX || input) continue;
    const listMove = delta + scrolled; // how far it moved in the list, the scroll aside
    const anchored = expects.find((expect) => expect.anchorRow === id);
    if (anchored) {
      flag(id, "I2", "reflow", delta, `anchor of "${anchored.reason}" left its pixel`);
      continue;
    }
    if (named(expects, id)) continue;
    if (Math.abs(listMove) <= SHIFT_TOLERANCE_PX && followed) continue; // the follow scroll for an append
    const cause = causeAbove(prev, next, id);
    flag(id, "I2", cause, delta, expects.length ? `held still for "${expects[0]!.reason}"? it moved` : undefined);
  }
  for (const id of prev.order) {
    if (next.rows.has(id)) continue;
    const was = prev.rows.get(id)!;
    state.gone.set(id, {
      frame: next.frame,
      ...(was.kind ? { kind: was.kind } : {}),
      ...(was.tag ? { tag: was.tag } : {}),
    });
    // I2 (unmount): a row that leaves from between visible rows with no input and no declared move.
    const index = prev.order.indexOf(id);
    if (index > 0 && index < prev.order.length - 1 && !input && !named(expects, id))
      flag(id, "I2", "unmount", -was.height, "left from between visible rows");
  }

  // I1, on a settled frame (no input, no declared move, nothing moved): no hole, no overlap.
  if (
    !input &&
    !expects.length &&
    !flags.some((item) => item.invariant === "I2") &&
    Math.abs(scrolled) <= SHIFT_TOLERANCE_PX
  ) {
    for (let index = 1; index < next.order.length; index++) {
      const above = next.rows.get(next.order[index - 1]!)!;
      const below = next.rows.get(next.order[index]!)!;
      const gap = below.top - (above.top + above.height);
      if (gap < -SHIFT_TOLERANCE_PX) flag(next.order[index]!, "I1", "reflow", gap, "overlaps the row above");
      else if (below.gapAbove !== undefined && gap - below.gapAbove > SHIFT_TOLERANCE_PX && gap <= BLANK_BAND_PX)
        flag(
          next.order[index]!,
          "I1",
          "reflow",
          gap - below.gapAbove,
          `hole: gap ${Math.round(gap)} px, designed ${below.gapAbove}`,
        );
    }
  }
  return flags;
}

/// I4: what a declared move may not leave behind when its window closes, in `root`.
export function leftovers(root: ParentNode): ShiftFlag[] {
  const flags: ShiftFlag[] = [];
  for (const row of root.querySelectorAll<HTMLElement>(".acpmux-row")) {
    const style = row.style;
    if (style.translate || (style.transform && style.transform !== "none"))
      flags.push({
        rowId: row.dataset.rowId ?? "?",
        invariant: "I4",
        cause: "reflow",
        deltaPx: 0,
        frame: frameCount,
        detail: "inline translate left after settle",
      });
  }
  for (const fold of root.querySelectorAll<HTMLElement>(".cv-fold"))
    if (fold.style.height)
      flags.push({
        rowId: fold.closest<HTMLElement>(".acpmux-row")?.dataset.rowId ?? "?",
        invariant: "I4",
        cause: "resize",
        deltaPx: 0,
        frame: frameCount,
        detail: "fold kept an inline height after settle",
      });
  for (const ghost of root.querySelectorAll<HTMLElement>(".acpmux-row--fold-ghost"))
    flags.push({
      rowId: ghost.dataset.rowId ?? "?",
      invariant: "I4",
      cause: "unmount",
      deltaPx: 0,
      frame: frameCount,
      detail: "ghost left after settle",
    });
  return flags;
}

// ---- The live half: one watcher per page, `expect()` for the motion owner. ----

let expects: Expectation[] = [];
let frameCount = 0;
const kept: ShiftFlag[] = [];
const counts = new Map<Invariant, number>();
const listeners = new Set<(flags: ShiftFlag[]) => void>();
let closeChecks: { until: number; reason: string }[] = [];

/**
 * Declare a move before making it: `rows` may move (all rows when omitted) for `ms`; `anchorRow` must
 * stay on its pixel. Only the motion owner calls this (motionOwner.ts `transition`), so any other move
 * is a flag. Returns a function that ends the window early.
 */
export function expect(
  reason: string,
  options: { rows?: Iterable<string>; anchorRow?: string; ms: number },
): () => void {
  const now = performance.now();
  const item: Expectation = {
    reason,
    from: now,
    until: now + Math.max(0, options.ms),
    ...(options.rows ? { rows: new Set(options.rows) } : {}),
    ...(options.anchorRow ? { anchorRow: options.anchorRow } : {}),
  };
  expects.push(item);
  closeChecks.push({ until: item.until, reason });
  return () => {
    item.until = Math.min(item.until, performance.now());
    for (const check of closeChecks) if (check.reason === reason && check.until > item.until) check.until = item.until;
  };
}

/// The declared moves live now (tests, debug automation).
export const liveExpectations = (at = performance.now()) => live(expects, at);

/// The watch's flags so far, newest last, and a count per invariant (debug automation, the metric).
export function layoutWatchReport(): { flags: ShiftFlag[]; counts: Record<string, number>; unexplained: number } {
  let unexplained = 0;
  for (const value of counts.values()) unexplained += value;
  return { flags: [...kept], counts: Object.fromEntries(counts), unexplained };
}

export function onLayoutFlags(listener: (flags: ShiftFlag[]) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Forget flags and declared moves (tests).
export function resetLayoutWatch(): void {
  expects = [];
  closeChecks = [];
  kept.length = 0;
  counts.clear();
  frameCount = 0;
}

/// Whether the watch runs on this page: dev builds, the perf watch, or asked for by hand.
export function layoutWatchWanted(perfOn: boolean): boolean {
  if (perfOn) return true;
  try {
    if (globalThis.localStorage?.getItem("cmux.layoutWatch") === "1") return true;
  } catch {
    // A page with no storage (a sandboxed frame) watches only in dev.
  }
  return Boolean(import.meta.env?.DEV) && import.meta.env?.MODE !== "test";
}

function readRow(row: HTMLElement, scrollerTop: number): RowBox {
  const rect = row.getBoundingClientRect();
  const box: RowBox = { top: rect.top - scrollerTop, height: rect.height, tag: row.tagName };
  const kind = row.dataset.rowKind ?? row.dataset.kind;
  if (kind) box.kind = kind;
  const gap = row.dataset.gap;
  if (gap !== undefined && gap !== "") box.gapAbove = Number(gap);
  const actions = row.querySelector<HTMLElement>("[data-slot='actions']");
  if (actions) {
    box.actionsRight = actions.getBoundingClientRect().right;
    box.textLength = (row.querySelector<HTMLElement>("[data-slot='body']") ?? row).textContent?.length ?? 0;
  }
  const clock = row.querySelector<HTMLElement>("[data-clock]");
  if (clock) {
    box.clockText = clock.textContent ?? "";
    box.clockWidth = clock.getBoundingClientRect().width;
  }
  return box;
}

/// One frame of `scroller`'s visible rows.
export function readWatchFrame(
  scroller: HTMLElement,
  frame: number,
  streaming: boolean,
  lastRowId?: string,
): WatchFrame {
  const view = scroller.getBoundingClientRect();
  const rows = new Map<string, RowBox>();
  const order: string[] = [];
  for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
    if (row.classList.contains("acpmux-row--fold-ghost")) continue;
    const id = row.dataset.rowId!;
    const box = readRow(row, view.top);
    if (box.height <= 0 || box.top + box.height < 0 || box.top > view.height || rows.has(id)) continue;
    rows.set(id, box);
    order.push(id);
  }
  order.sort((a, b) => rows.get(a)!.top - rows.get(b)!.top);
  return {
    frame,
    at: performance.now(),
    scrollTop: scroller.scrollTop,
    order,
    rows,
    streaming,
    ...(lastRowId ? { lastRowId } : {}),
  };
}

export type LayoutWatchOptions = {
  /// Whether a turn streams now, and the list's last row id (mounted or not).
  streaming: () => boolean;
  lastRowId: () => string | undefined;
  /// Each flag, as it is raised (the metric counter, `acpmuxPerf.render("layout.unexplained_shifts")`).
  onFlag?: (flag: ShiftFlag) => void;
  /// Draw an outline on a flagged row for a moment (dev and nightly).
  overlay?: boolean;
};

const INPUTS = ["pointerdown", "wheel", "touchstart", "keydown"] as const;

/// Whether the chat over `scroller` is in its minimal motion (frameBudget.ts: its frames missed their
/// budget). The watch is a diagnostic: each frame it reads every visible row's box, a layout forced
/// ahead of the frame's own, and on a chat already missing its frames that read is the cost of a frame
/// the reader waits on (composer_typing.l1.webkit, typing while a reply streams: about 0.5 ms a frame of
/// readWatchFrame's boxes and 1 ms of the tick). So it reads nothing while the chat is minimal, as
/// the chat's motion sheds there, and picks up from a fresh frame once the mark goes: a frame pair
/// across the gap is never judged (`prev` is cleared), so the gap raises no flag. In minimal motion
/// rows land in place and nothing glides, so a move the watch would flag there is one it sees again
/// once the chat moves.
function shedding(scroller: HTMLElement): boolean {
  return scroller.closest(`[${CHAT_MOTION_ATTR}="${MINIMAL_MOTION}"]`) !== null;
}

/// Watch `scroller`'s rows on every frame until the returned function is called.
export function startLayoutWatch(scroller: HTMLElement, options: LayoutWatchOptions): () => void {
  const view = scroller.ownerDocument.defaultView;
  if (!view || typeof view.requestAnimationFrame !== "function") return () => undefined;
  const state = newJudgeState();
  let inputAt = Number.NEGATIVE_INFINITY;
  let prev: WatchFrame | undefined;
  let handle = 0;
  let stopped = false;
  const noteInput = () => {
    inputAt = performance.now();
  };
  for (const name of INPUTS) view.addEventListener(name, noteInput, { capture: true, passive: true });
  const raise = (flags: ShiftFlag[]) => {
    if (!flags.length) return;
    const stack = new Error().stack?.split("\n").slice(2, 6).join("\n");
    for (const item of flags) {
      if (stack) item.stack = stack;
      kept.push(item);
      if (kept.length > KEPT_FLAGS) kept.shift();
      counts.set(item.invariant, (counts.get(item.invariant) ?? 0) + 1);
      options.onFlag?.(item);
      if (options.overlay) outline(scroller, item);
    }
    console.warn("[layoutWatch] unexplained layout change", flags);
    for (const listener of listeners) listener(flags);
  };
  const tick = () => {
    handle = 0;
    if (stopped) return;
    if (scroller.ownerDocument.visibilityState !== "hidden" && scroller.isConnected && !shedding(scroller)) {
      frameCount += 1;
      const next = readWatchFrame(scroller, frameCount, options.streaming(), options.lastRowId());
      const now = next.at;
      const flags = judgeFrame(prev, next, { inputAt, expects, state });
      // I4 when a declared move's window closes.
      const closed = closeChecks.filter((check) => check.until <= now);
      if (closed.length) {
        closeChecks = closeChecks.filter((check) => check.until > now);
        if (!live(expects, now).length) flags.push(...leftovers(scroller));
      }
      expects = expects.filter((item) => item.until > now - INPUT_GRACE_MS);
      raise(flags);
      prev = next;
    } else prev = undefined;
    handle = view.requestAnimationFrame(tick);
  };
  handle = view.requestAnimationFrame(tick);
  return () => {
    stopped = true;
    if (handle) view.cancelAnimationFrame(handle);
    for (const name of INPUTS) view.removeEventListener(name, noteInput, { capture: true });
  };
}

function outline(scroller: HTMLElement, item: ShiftFlag): void {
  const row = scroller.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${CSS.escape(item.rowId)}"]`);
  if (!row) return;
  row.dataset.layoutFlag = item.invariant;
  // One timer per flag, ended by itself (stop condition: 600 ms).
  setTimeout(() => {
    if (row.dataset.layoutFlag === item.invariant) delete row.dataset.layoutFlag;
  }, 600); // motion-allow: a debug overlay timer, not an animation
}
