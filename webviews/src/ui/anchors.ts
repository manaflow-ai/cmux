// Six anchors a floating thing can rest at, and the drag that moves it between them (Leo,
// 2026-11-07: "get the toasts to be draggable so you can move it around if you need to see
// something"). Nothing here knows about toasts: a toast stack uses it first, and the sidebar's
// update card can use the same anchors, memory and drag.
//
// - `ANCHORS`, `anchorPoint`, `nearestAnchor`: the six places in a surface's box and which one a
//   point is nearest.
// - `anchorMemory`: the last anchor per key (a toast's kind), kept in the page's localStorage as
//   other webview preferences are; a refused or absent store remembers nothing.
// - `createDrag`: a pointer drag from press to release. It keeps the last moves to tell a flick,
//   and on release says where the thing goes: an anchor, or away (flicked, or dropped past the
//   surface's edge).

export type Anchor = "top-left" | "top" | "top-right" | "bottom-left" | "bottom" | "bottom-right";

export const ANCHORS: readonly Anchor[] = ["top-left", "top", "top-right", "bottom-left", "bottom", "bottom-right"];
export const DEFAULT_ANCHOR: Anchor = "bottom";

export interface Point {
  x: number;
  y: number;
}
export interface Box {
  left: number;
  top: number;
  width: number;
  height: number;
}

export function isAnchor(value: unknown): value is Anchor {
  return typeof value === "string" && (ANCHORS as readonly string[]).includes(value);
}

export function anchorRow(anchor: Anchor): "top" | "bottom" {
  return anchor.startsWith("top") ? "top" : "bottom";
}
export function anchorColumn(anchor: Anchor): "start" | "center" | "end" {
  return anchor.endsWith("-left") ? "start" : anchor.endsWith("-right") ? "end" : "center";
}

/// The point an anchor stands for in `box`: a corner, or the middle of the top or bottom edge.
export function anchorPoint(anchor: Anchor, box: Box): Point {
  const column = anchorColumn(anchor);
  const x = box.left + (column === "start" ? 0 : column === "end" ? box.width : box.width / 2);
  return { x, y: anchorRow(anchor) === "top" ? box.top : box.top + box.height };
}

/// The anchor nearest `point`: by thirds across and halves down, so each anchor owns the region
/// around it (a corner owns its corner even in a very wide box).
export function nearestAnchor(point: Point, box: Box): Anchor {
  const across = box.width > 0 ? (point.x - box.left) / box.width : 0.5;
  const down = box.height > 0 ? (point.y - box.top) / box.height : 1;
  const row = down < 0.5 ? "top" : "bottom";
  if (across < 1 / 3) return `${row}-left`;
  if (across > 2 / 3) return `${row}-right`;
  return row;
}

export interface AnchorMemory {
  get(key: string): Anchor | undefined;
  set(key: string, anchor: Anchor): void;
}

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/// The last anchor per key under `prefix` in `store` (the page's localStorage by default). The
/// default anchor is stored as nothing, so a reset is the same as never having moved.
export function anchorMemory(
  prefix: string,
  store: () => Store | undefined = () => globalThis.localStorage,
): AnchorMemory {
  return {
    get(key) {
      try {
        const value = store()?.getItem(prefix + key);
        return isAnchor(value) ? value : undefined;
      } catch {
        return undefined;
      }
    },
    set(key, anchor) {
      try {
        if (anchor === DEFAULT_ANCHOR) store()?.removeItem(prefix + key);
        else store()?.setItem(prefix + key, anchor);
      } catch {
        // Storage refused: the anchor holds for this page only.
      }
    },
  };
}

/** Pixels the pointer moves before a press becomes a drag (a click stays a click). */
export const DRAG_SLOP = 4;
/** A release faster than this, in px/ms, flings the thing away. */
export const FLICK_SPEED = 1.1;
/** A release this far past the box's edge, in px, takes the thing away. */
export const EDGE_OUT = 24;
/** Moves older than this, in ms, no longer count toward the release speed. */
const VELOCITY_WINDOW_MS = 80;

export type DragRelease =
  | { kind: "click" }
  | { kind: "snap"; anchor: Anchor; offset: Point }
  | { kind: "dismiss"; offset: Point; velocity: Point };

export interface Drag {
  /** Whether the press has moved past the slop: the thing follows the pointer. */
  readonly dragging: boolean;
  /** How far the pointer is from the press. */
  readonly offset: Point;
  move(point: Point, at: number): Point;
  /** Where the thing goes. `box` is the surface it may rest in, in the pointer's coordinates. */
  release(point: Point, at: number, box: Box): DragRelease;
}

/// A drag from a press at `start` (time `at`, in ms). The caller holds the thing (its timer
/// stops) from the press to the release; `release` says where it goes.
export function createDrag(start: Point, at: number): Drag {
  let offset: Point = { x: 0, y: 0 };
  let dragging = false;
  const samples: { point: Point; at: number }[] = [{ point: start, at }];
  const velocity = (now: number): Point => {
    const recent = samples.filter((sample) => now - sample.at <= VELOCITY_WINDOW_MS);
    const first = recent[0] ?? samples.at(-1)!;
    const last = samples.at(-1)!;
    const ms = last.at - first.at;
    if (ms <= 0) return { x: 0, y: 0 };
    return { x: (last.point.x - first.point.x) / ms, y: (last.point.y - first.point.y) / ms };
  };
  return {
    get dragging() {
      return dragging;
    },
    get offset() {
      return offset;
    },
    move(point, now) {
      offset = { x: point.x - start.x, y: point.y - start.y };
      if (!dragging && Math.hypot(offset.x, offset.y) >= DRAG_SLOP) dragging = true;
      samples.push({ point, at: now });
      if (samples.length > 16) samples.shift();
      return offset;
    },
    release(point, now, box) {
      this.move(point, now);
      if (!dragging) return { kind: "click" };
      const speed = velocity(now);
      const outside =
        point.x < box.left - EDGE_OUT ||
        point.x > box.left + box.width + EDGE_OUT ||
        point.y < box.top - EDGE_OUT ||
        point.y > box.top + box.height + EDGE_OUT;
      if (outside || Math.hypot(speed.x, speed.y) >= FLICK_SPEED) return { kind: "dismiss", offset, velocity: speed };
      return { kind: "snap", anchor: nearestAnchor(point, box), offset };
    },
  };
}
