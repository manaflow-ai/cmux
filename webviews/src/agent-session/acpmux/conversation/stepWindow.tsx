// The steps of an opened run that are mounted (ToolGroupRow.tsx StepList, ToolRunSteps.tsx,
// McpCallRows.tsx McpGroupRow): those in view and a view's worth over and under it. The rest are a
// box of their heights each side (measured once drawn, the steps' usual height before), so the list
// is as tall as it is with every step drawn and a scroll lands where it would. The view is the run's
// own scroll box (RunScroll.tsx, 224px) once it scrolls, else the transcript's. What mounts and what
// is read per scroll stay the same at any length: the heights sit in a Fenwick tree (the step at an
// offset, a step's offset: O(log N)), only mounted steps are measured, through one size observer on
// the list, and a scroll that keeps the same steps in range draws nothing.
import { useContext, useLayoutEffect, useMemo, useRef, useState, type ReactNode, type RefObject } from "react";
import { flushSync } from "react-dom";
import type { AcpmuxActivity } from "../model";
import { FindReveal, revealsItem } from "./chatFind";
import { markHeightFold } from "./fold";

/// A step's height before it is measured, in px: the transcript's one-line row (model.ts
/// `toolRowHeight`), until the first drawn steps give the usual one.
const STEP_PX = 22;
/// The view with no layout to read (a test DOM): the run box's cap (RunScroll.tsx, `.cv-run-scroll`).
const BOX_PX = 224;
/// How long the rows under the list are placed before paint after its height is corrected (fold.ts).
const SETTLE_MS = 200; // motion-allow: a watch window after a measured correction, not an animation

/// Step heights as a Fenwick tree: setting one, the sum before one and the step at an offset are each
/// O(log N); building it is one pass, done only when the list's shape changes.
export class StepHeights {
  readonly size: number;
  private readonly values: Float64Array;
  private readonly tree: Float64Array;
  constructor(values: Float64Array) {
    this.size = values.length;
    this.values = values;
    this.tree = new Float64Array(this.size + 1);
    for (let at = 1; at <= this.size; at++) {
      this.tree[at]! += values[at - 1]!;
      const up = at + (at & -at);
      if (up <= this.size) this.tree[up]! += this.tree[at]!;
    }
  }
  height(at: number): number {
    return this.values[at]!;
  }
  /// Sets step `at`'s height and returns how much it changed.
  set(at: number, height: number): number {
    const delta = height - this.values[at]!;
    if (!delta) return 0;
    this.values[at] = height;
    for (let node = at + 1; node <= this.size; node += node & -node) this.tree[node]! += delta;
    return delta;
  }
  /// The heights of the steps before `at`: its top in the list.
  before(at: number): number {
    let sum = 0;
    for (let node = Math.min(at, this.size); node > 0; node -= node & -node) sum += this.tree[node]!;
    return sum;
  }
  total(): number {
    return this.before(this.size);
  }
  /// The step whose box holds offset `y` (the first past a run of empty ones), the last past the end.
  at(y: number): number {
    if (!this.size || y <= 0) return 0;
    let at = 0;
    let rest = y;
    for (let step = 1 << Math.floor(Math.log2(this.size)); step; step >>= 1) {
      const next = at + step;
      if (next <= this.size && this.tree[next]! <= rest) {
        at = next;
        rest -= this.tree[next]!;
      }
    }
    return Math.min(at, this.size - 1);
  }
}

/// A stretch of the list: steps `from` to `to` (exclusive), mounted, or (`rest` set) one box that tall.
export type StepPiece = { from: number; to: number; rest?: number };

type View = { top: number; height: number };

/// What clips the list, and the view's top in the list's own px with its height: the run's box while
/// it scrolls, else the transcript's scroller, and never more than the window shows (a box that does
/// not scroll, with no transcript around it, is clipped by the window alone). No layout (a test DOM):
/// the box's own offset over its cap.
function readView(node: HTMLElement): View & { clip?: HTMLElement } {
  const box = node.closest<HTMLElement>(".cv-run-scroll") ?? undefined;
  const scroller = node.closest<HTMLElement>(".acpmux-scroll") ?? undefined;
  if (!node.getClientRects().length)
    return { top: box?.scrollTop ?? 0, height: box ? BOX_PX : window.innerHeight || BOX_PX, clip: box };
  const clip = box && box.scrollHeight > box.clientHeight + 1 ? box : (scroller ?? box);
  const listTop = node.getBoundingClientRect().top;
  const clipTop = clip ? clip.getBoundingClientRect().top : 0;
  const clipBottom = clip ? clipTop + clip.clientHeight : window.innerHeight;
  const top = Math.max(clipTop, 0);
  const bottom = Math.min(clipBottom, window.innerHeight);
  // Out of the window: the clip's own view, so the window waits by the edge nearest it.
  if (bottom <= top) return { top: clipTop - listTop, height: clipBottom - clipTop || window.innerHeight, clip };
  return { top: top - listTop, height: bottom - top, clip };
}

/// The first and last step a view mounts: itself and a view's height over and under it.
function range(heights: StepHeights, view: View): [number, number] {
  return [heights.at(view.top - view.height), heights.at(view.top + 2 * view.height)];
}

/// A drawn step's height with its margins (a flex column, so they never collapse).
function outerHeight(element: HTMLElement): number {
  const style = getComputedStyle(element);
  return (
    element.getBoundingClientRect().height + (parseFloat(style.marginTop) || 0) + (parseFloat(style.marginBottom) || 0)
  );
}

/// The steps (one per item) that hold Find's match in this row, mounted wherever the view is, so the
/// match is drawn, counted in its place among the row's matches (a step without one adds none) and
/// scrolled to (RunScroll.tsx `toolId`, VirtualTranscript.tsx `scrollRangeInBoxes`). None without Find.
export function useRevealPins(items: readonly AcpmuxActivity[]): readonly number[] | undefined {
  const reveal = useContext(FindReveal);
  return useMemo(
    () => (reveal ? items.flatMap((item, at) => (revealsItem(reveal, item) ? [at] : [])) : undefined),
    [reveal, items],
  );
}

/// The window over a list of `keys.length` steps, each drawn as an element carrying `data-step={key}`
/// as a child of `list`. `keys` is a new array only when the list's shape changes (a step joins or one
/// takes another's place). `quiet(at)`: a step that draws nothing, 0 tall until drawn. `pinned`: steps
/// mounted wherever the view is (the steps Find's match is in). The step holding focus stays mounted
/// too, and a selection that touches the list keeps every step between its ends mounted while it is
/// held (an end in a box or past the list stands for that edge), so a drag across steps, or Select
/// All, copies every step's text in order, as the transcript's line windows do (lineWindow.ts).
/// Returns the list's pieces in order: the caller draws each mounted one's steps and a box for each
/// `rest`.
export function useStepWindow({
  list,
  keys,
  quiet,
  pinned,
}: {
  list: RefObject<HTMLElement | null>;
  keys: readonly string[];
  quiet?: (at: number) => boolean;
  pinned?: readonly number[];
}): StepPiece[] {
  /// Heights read so far, by step key: a step keeps its height through a change of shape.
  const measured = useRef(new Map<string, number>());
  /// The usual step's height, from the first steps drawn.
  const usual = useRef<number | undefined>(undefined);
  const built = useRef<{
    keys: readonly string[];
    usual: number | undefined;
    heights: StepHeights;
    index: Map<string, number>;
  }>(undefined);
  const rebuild = () => {
    const pitch = usual.current ?? STEP_PX;
    const values = new Float64Array(keys.length);
    const index = new Map<string, number>();
    for (let at = 0; at < keys.length; at++) {
      const key = keys[at]!;
      index.set(key, at);
      values[at] = measured.current.get(key) ?? (quiet?.(at) ? 0 : pitch);
    }
    built.current = { keys, usual: usual.current, heights: new StepHeights(values), index };
  };
  if (built.current?.keys !== keys || built.current.usual !== usual.current) rebuild();
  const { heights, index } = built.current!;
  const [view, setView] = useState<View>(() => ({ top: 0, height: BOX_PX }));
  const [, redraw] = useState(0);
  // The step holding focus, by key (so a change of shape keeps it).
  const [focused, setFocused] = useState<string | undefined>(undefined);
  // The steps a held selection runs over, first and last (cleared when it collapses).
  const [span, setSpan] = useState<readonly [number, number] | null>(null);
  const [first, last] = range(heights, view);
  const wanted: [number, number][] = [[first, last + 1]];
  for (const at of pinned ?? []) if (at < keys.length && (at < first || at > last)) wanted.push([at, at + 1]);
  const focusAt = focused === undefined ? undefined : index.get(focused);
  if (focusAt !== undefined) wanted.push([focusAt, focusAt + 1]);
  if (span) wanted.push([Math.min(span[0], keys.length), Math.min(span[1] + 1, keys.length)]);
  wanted.sort((a, b) => a[0] - b[0]);
  const mounted: [number, number][] = [];
  for (const [from, to] of wanted) {
    if (from >= to) continue;
    const prior = mounted.at(-1);
    if (prior && from <= prior[1]) prior[1] = Math.max(prior[1], to);
    else mounted.push([from, to]);
  }
  const pieces: StepPiece[] = [];
  let next = 0;
  for (const [from, to] of keys.length ? mounted : []) {
    if (from > next) pieces.push({ from: next, to: from, rest: heights.before(from) - heights.before(next) });
    pieces.push({ from, to });
    next = to;
  }
  if (next < keys.length) pieces.push({ from: next, to: keys.length, rest: heights.total() - heights.before(next) });

  const drawn = useRef({ first, last, pieces });
  drawn.current = { first, last, pieces };

  /// Reads the drawn steps' heights; a change above the view moves its offset the same distance, so
  /// what the reader sees stays where it is. Returns whether a height changed.
  const measure = useRef<() => boolean>(() => false);
  measure.current = () => {
    const node = list.current;
    if (!node || !node.getClientRects().length) return false;
    const now = built.current!;
    const { top, clip } = readView(node);
    const anchor = top > 0 ? now.heights.at(top) : -1;
    const was = anchor >= 0 ? now.heights.before(anchor) : 0;
    let changed = false;
    const seen = new Set<number>();
    for (const element of node.querySelectorAll<HTMLElement>(":scope > [data-step]")) {
      const key = element.dataset.step!;
      const at = now.index.get(key);
      if (at === undefined) continue;
      seen.add(at);
      const height = outerHeight(element);
      measured.current.set(key, height);
      if (now.heights.set(at, height)) changed = true;
    }
    // A mounted step with no element draws nothing (a quiet thought).
    for (const piece of drawn.current.pieces)
      if (piece.rest === undefined)
        for (let at = piece.from; at < piece.to; at++)
          if (!seen.has(at)) {
            measured.current.set(now.keys[at]!, 0);
            if (now.heights.set(at, 0)) changed = true;
          }
    if (usual.current === undefined && seen.size) {
      // The usual step: the median drawn one, so a lead thought in full or a failure's taller row
      // does not set it. The steps not measured yet take it.
      const sizes = [...seen].map((at) => now.heights.height(at)).filter((height) => height > 0);
      sizes.sort((a, b) => a - b);
      if (sizes.length) {
        usual.current = sizes[sizes.length >> 1]!;
        rebuild();
        changed = true;
      }
    }
    if (!changed) return false;
    const moved = anchor >= 0 ? built.current!.heights.before(anchor) - was : 0;
    if (clip && Math.abs(moved) >= 0.5) clip.scrollTop += moved;
    // The transcript places the rows under this one before paint while its height settles.
    markHeightFold(node, SETTLE_MS);
    return true;
  };

  /// Takes the view's new place; draws again only when it mounts other steps.
  const follow = useRef<(sync: boolean) => void>(() => {});
  follow.current = (sync) => {
    const node = list.current;
    if (!node) return;
    const next = readView(node);
    const [from, to] = range(built.current!.heights, next);
    if (from === drawn.current.first && to === drawn.current.last) return;
    if (sync) flushSync(() => setView(next));
    else setView(next);
  };

  // Before paint, after every draw: the drawn steps' heights, then the view (a list opened scrolled
  // into, or whose heights just changed). It draws again only when a height changed, and a draw that
  // changes none settles it.
  // eslint-disable-next-line react-hooks/exhaustive-deps -- after every draw by design: what it reads is the DOM just drawn
  useLayoutEffect(() => {
    if (measure.current()) redraw((n) => n + 1);
    follow.current(false);
  });

  // The view's scrolls, the list's and the view's sizes, focus and the selection, for the list's life.
  useLayoutEffect(() => {
    const node = list.current;
    if (!node) return;
    const box = node.closest<HTMLElement>(".cv-run-scroll");
    const scroller = node.closest<HTMLElement>(".acpmux-scroll");
    const scrolled = () => follow.current(true);
    const view = node.ownerDocument.defaultView;
    box?.addEventListener("scroll", scrolled, { passive: true });
    scroller?.addEventListener("scroll", scrolled, { passive: true });
    view?.addEventListener("scroll", scrolled, { passive: true });
    const Observer = node.ownerDocument.defaultView?.ResizeObserver;
    const sizes = Observer
      ? new Observer(() => {
          if (measure.current()) flushSync(() => redraw((n) => n + 1));
          follow.current(true);
        })
      : undefined;
    sizes?.observe(node);
    if (box) sizes?.observe(box);
    /// The list's child holding `target`, if any.
    const childOf = (target: Node | null | undefined) => {
      let child: Node | null | undefined = target;
      while (child && child.parentNode !== node) child = child.parentNode;
      return child instanceof HTMLElement ? child : undefined;
    };
    const focusin = (event: FocusEvent) => setFocused(childOf(event.target as Node)?.dataset.step);
    const focusout = (event: FocusEvent) => {
      if (!node.contains(event.relatedTarget as Node | null)) setFocused(undefined);
    };
    const doc = node.ownerDocument;
    // One listener for the list's life: the steps a selection runs over, each end as the step it is
    // in, a box's first or last step, or the list's edge when the end is outside it.
    const selection = () => {
      const now = doc.getSelection();
      const range = now && now.rangeCount > 0 && !now.isCollapsed ? now.getRangeAt(0) : null;
      if (!range || !range.intersectsNode(node)) {
        setSpan((prior) => (prior ? null : prior));
        return;
      }
      const total = built.current!.keys.length;
      const stepAt = (target: Node, end: boolean): number => {
        if (!node.contains(target) || target === node) return end ? total - 1 : 0;
        const child = childOf(target);
        const step = child?.dataset.step;
        if (step !== undefined) return built.current!.index.get(step) ?? (end ? total - 1 : 0);
        const from = Number(child?.dataset.restFrom);
        const to = Number(child?.dataset.restTo);
        if (Number.isFinite(from) && Number.isFinite(to)) return end ? to - 1 : from;
        return end ? total - 1 : 0;
      };
      const from = stepAt(range.startContainer, false);
      const to = stepAt(range.endContainer, true);
      setSpan((prior) => (prior && prior[0] === from && prior[1] === to ? prior : [from, to]));
    };
    node.addEventListener("focusin", focusin);
    node.addEventListener("focusout", focusout);
    doc.addEventListener("selectionchange", selection);
    return () => {
      box?.removeEventListener("scroll", scrolled);
      scroller?.removeEventListener("scroll", scrolled);
      view?.removeEventListener("scroll", scrolled);
      sizes?.disconnect();
      node.removeEventListener("focusin", focusin);
      node.removeEventListener("focusout", focusout);
      doc.removeEventListener("selectionchange", selection);
    };
  }, [list]);

  return pieces;
}

/// The list's children for its `pieces`, one flat list: `draw(from, to)`'s keyed steps for each
/// mounted stretch, so a step keeps its element (and React skips it) as the window moves, and a box as
/// tall as the steps it stands for (`.cv-steps__rest`, aria-hidden, nothing to read or select) for each
/// other. A box for an odd count of steps is padded by an empty one, so the zebra look's odd rows
/// (`:nth-child(odd)`) stay the odd steps.
export function windowedSteps(
  pieces: readonly StepPiece[],
  draw: (from: number, to: number) => ReactNode[],
): ReactNode[] {
  const children: ReactNode[] = [];
  let count = 0;
  for (const piece of pieces) {
    if (piece.rest === undefined) {
      children.push(...draw(piece.from, piece.to));
      count += piece.to - piece.from;
      continue;
    }
    children.push(
      <div
        key={`rest:${piece.from}`}
        className="cv-steps__rest"
        data-steps-rest={piece.to - piece.from}
        data-rest-from={piece.from}
        data-rest-to={piece.to}
        style={{ height: piece.rest }}
        aria-hidden
      />,
    );
    count += 1;
    if ((count - piece.to) % 2 !== 0) {
      children.push(
        <div
          key={`rest-pad:${piece.from}`}
          className="cv-steps__rest"
          data-rest-from={piece.to}
          data-rest-to={piece.to}
          aria-hidden
        />,
      );
      count += 1;
    }
  }
  return children;
}
