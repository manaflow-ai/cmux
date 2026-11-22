// A selection highlight that slides between the items of a tab bar, segmented control or picker
// (Leo, 2026-11-03: "i sent this zzz video i thought was cute and cool and i wanted to have more...
// nice stuff? around the app"). The highlight is one element behind the items: at rest it sits on the
// selected item; when the selection changes it is placed on the new item at once and a Web Animation
// carries it there from where it was drawn, on transform only.
//
// Rules it keeps (leo-workspace design/motion-and-polish.md): the selection changes on the click, and
// the item's own state (aria-selected / aria-pressed, its colour) is the new one in that same frame;
// only the highlight travels. Transform only, so every frame is the compositor's and nothing around it
// moves (no layout shift). The first frame is the final frame: on mount, and when a size changes, the
// highlight is placed with no motion. Interruptible: a change during a slide starts from the drawn
// position. Motion off, a hidden page or a zero motion token: placed at once. Reduce Motion: placed at
// once (the item's own state change is the crossfade).
//
// Stop conditions: no timer and no frame loop. The slide is one finite Web Animation (at most
// --cmux-motion-large, 240 ms) that ends on its own; the next change and unmount cancel it. One
// ResizeObserver on the host and its items re-places the highlight when a size changes (a label, a
// font load); it is disconnected on unmount. A size change during a slide is held until the slide
// finishes, then re-placed with no motion, so the highlight never ends off its item.
import { type CSSProperties, type RefObject, useLayoutEffect, useRef } from "react";
import { MOTION_EASE_OUT, MOTION_MS, MOTION_SPRING, MOTION_SPRING_STEP } from "../../motion/scale.generated";
import { cx } from "../cx";
import { motionMode, springEasing } from "./motionMode";
import "./motion.css";

/** How the highlight looks: a filled pill, a quiet plate (the toolbar's pressed fill), or an underline. */
export type IndicatorLook = "pill" | "plate" | "underline";
/** How it travels: the one spring, the ease-out at `standard`, or not at all. */
export type IndicatorTravel = "spring" | "ease" | "none";

/** The selected item, by default: the one a tablist, a toolbar or a radio group marks. */
export const SELECTED_ITEM = '[aria-selected="true"], [aria-pressed="true"], [aria-checked="true"], [data-selected]';

type Box = { x: number; y: number; w: number; h: number };

const same = (a: Box, b: Box) =>
  Math.abs(a.x - b.x) < 0.5 && Math.abs(a.y - b.y) < 0.5 && Math.abs(a.w - b.w) < 0.5 && Math.abs(a.h - b.h) < 0.5;

/** Where `item` sits in `host`'s padding box, in CSS px (sub-pixel kept). */
function boxIn(host: HTMLElement, item: HTMLElement): Box {
  const outer = host.getBoundingClientRect();
  const inner = item.getBoundingClientRect();
  return {
    x: inner.left - outer.left - host.clientLeft + host.scrollLeft,
    y: inner.top - outer.top - host.clientTop + host.scrollTop,
    w: inner.width,
    h: inner.height,
  };
}

/** Where the highlight is drawn now (mid-slide included), from its own size and computed transform. */
function drawnBox(mark: HTMLElement, rest: Box): Box {
  const matrix = new DOMMatrixReadOnly(getComputedStyle(mark).transform);
  return { x: matrix.e, y: matrix.f, w: rest.w * matrix.a, h: rest.h * matrix.d };
}

export type SlidingIndicatorOptions = {
  /** Changes whenever the selection does (the selected value). The highlight moves when it changes. */
  selected: unknown;
  look?: IndicatorLook;
  travel?: IndicatorTravel;
  /** Finds the selected item inside the host. */
  selector?: string;
};

/**
 * Places `mark` on the selected item inside its parent (the host) and slides it on each change of
 * `selected`. The host must be the highlight's containing block (`.ui-slide-host` makes it one). The
 * host is read from the DOM, not a ref: a child's layout effects run before its parent's ref is set.
 */
export function useSlidingIndicator(
  mark: RefObject<HTMLElement | null>,
  { selected, travel = "spring", selector = SELECTED_ITEM }: SlidingIndicatorOptions,
) {
  const rest = useRef<Box | null>(null);
  const slide = useRef<Animation | null>(null);
  // Re-places it on the selected item with no motion, if its box changed; set while mounted.
  const settle = useRef<(() => void) | null>(null);

  // Place it on every selection change, sliding from where it is drawn.
  // perf-hot: one read and one write per selection change; no per-frame work.
  useLayoutEffect(() => {
    const element = mark.current;
    const parent = element?.parentElement;
    if (!parent || !element) return;
    const item = parent.querySelector<HTMLElement>(selector);
    if (!item) {
      slide.current?.cancel();
      slide.current = null;
      rest.current = null;
      element.dataset.empty = "";
      return;
    }
    const target = boxIn(parent, item);
    const was = rest.current;
    // Read the drawn position before the running slide is cancelled, so an interrupted slide
    // continues from where the eye saw it.
    const from = was && slide.current?.playState === "running" ? drawnBox(element, was) : was;
    slide.current?.cancel();
    slide.current = null;
    rest.current = target;
    delete element.dataset.empty;
    element.style.width = `${target.w}px`;
    element.style.height = `${target.h}px`;
    element.style.transform = `translate(${target.x}px, ${target.y}px)`;
    if (!from || same(from, target) || travel === "none" || motionMode(element.ownerDocument) !== "full") return;
    const scaleX = target.w > 0 ? from.w / target.w : 1;
    const scaleY = target.h > 0 ? from.h / target.h : 1;
    slide.current = element.animate(
      [
        { transform: `translate(${from.x}px, ${from.y}px) scale(${scaleX}, ${scaleY})` },
        { transform: `translate(${target.x}px, ${target.y}px)` },
      ],
      travel === "spring"
        ? {
            duration: MOTION_MS[MOTION_SPRING_STEP],
            easing: springEasing(MOTION_SPRING, MOTION_EASE_OUT, element.ownerDocument),
          }
        : { duration: MOTION_MS.standard, easing: MOTION_EASE_OUT },
    );
    slide.current.onfinish = () => {
      slide.current = null;
      settle.current?.();
    };
  }, [mark, selected, travel, selector]);

  // Re-place it, with no motion, when the host or an item changes size; stop on unmount.
  useLayoutEffect(() => {
    const element = mark.current;
    const parent = element?.parentElement;
    if (!parent || !element || typeof ResizeObserver === "undefined") return;
    const place = () => {
      const item = parent.querySelector<HTMLElement>(selector);
      if (!item) return;
      const target = boxIn(parent, item);
      if (rest.current && same(rest.current, target)) return;
      rest.current = target;
      element.style.width = `${target.w}px`;
      element.style.height = `${target.h}px`;
      element.style.transform = `translate(${target.x}px, ${target.y}px)`;
    };
    settle.current = place;
    // During a slide the box is read again when it finishes (onfinish calls settle).
    const observer = new ResizeObserver(() => {
      if (!slide.current) place();
    });
    observer.observe(parent);
    for (const child of parent.children) if (child !== element) observer.observe(child);
    return () => {
      observer.disconnect();
      settle.current = null;
    };
  }, [mark, selector]);

  useLayoutEffect(
    () => () => {
      slide.current?.cancel();
      slide.current = null;
    },
    [],
  );
}

export type SlidingIndicatorProps = SlidingIndicatorOptions & {
  className?: string;
  style?: CSSProperties;
};

/**
 * The highlight element. Render it as the first child of the element holding the items (a tablist,
 * a toolbar group); give that host `ui-slide-host` and the items `ui-slide-item`.
 */
export function SlidingIndicator({ className, style, look = "pill", ...options }: SlidingIndicatorProps) {
  const mark = useRef<HTMLSpanElement>(null);
  useSlidingIndicator(mark, options);
  return (
    <span
      ref={mark}
      className={cx("ui-slide-indicator", className)}
      data-look={look}
      style={style}
      aria-hidden="true"
    />
  );
}
