import { useLayoutEffect, useRef } from "react";
import { cssTimeMs } from "../conversation/fold";
import { motionAllowed } from "./trayMotionModel";

/// The glides `useGlide` starts, told apart from a node's other animations.
const GLIDE = "acpmux-glide";
/// A Tick's width ease (`slide`): the one animation that already carries the parts after it.
export const SLIDE = "acpmux-slide";

/// The parts of `row` that `selector` names move to a new place as one glide instead of a jump (Leo,
/// 2026-11-09, on the hat's "+2 more" and time: "the animations don't track properly to squishy"):
/// whatever moves them (a count that grows a digit, a mark or a failed count joining before them), each
/// slides from where it was drawn to where it now lies, on transform alone, on the slide's clock.
/// - A change React renders: where it was drawn is read while rendering, before React commits, glide in
///   flight included, so a change mid-glide carries on from the drawn place (interruptible); where it
///   lies is read after this commit's own width eases have started (`Tick` slide, a child's layout
///   effect, which runs first), so a part those eases already carry is not moved twice.
/// - A change only a child renders (a count's old digits leaving once its roll ends, "+10" to "+9"): a
///   ResizeObserver on the row's children sees the size change, and the parts glide from their last
///   laid-out place plus whatever offset they are still drawn at. While a width ease runs in the row,
///   that ease owns the movement and nothing glides on top of it.
/// A row that changed width (a window resize) puts every part in its place at once, cancelling a glide
/// in flight, and so does every change while motion may not run.
export function useGlide(row: { readonly current: HTMLElement | null }, selector: string): void {
  const before = useRef<Placed | undefined>(undefined);
  const laid = useRef<Placed | undefined>(undefined);
  const observer = useRef<ResizeObserver | undefined>(undefined);
  const node = row.current;
  if (node) before.current = drawnPlaces(node, selector);
  useLayoutEffect(() => {
    const first = before.current;
    before.current = undefined;
    const node = row.current;
    if (!node) return;
    laid.current = glideFrom(node, selector, first);
    // Watch every child the row has now, so a child that changes size on its own moves the parts too.
    if (!observer.current && typeof ResizeObserver === "function")
      observer.current = new ResizeObserver(() => {
        const node = row.current;
        if (!node || !laid.current) return;
        // A width ease in the row (Tick slide) carries what follows it; don't glide on top of it. A roll
        // or a crossfade (opacity, transform) moves nothing after it, so it never stops a glide: the
        // subagent icon row widening while the count rolls still glides the kinds after it.
        const easing = node.getAnimations({ subtree: true }).some((animation) => animation.id === SLIDE);
        laid.current = glideFrom(node, selector, easing ? undefined : stillDrawnAt(laid.current));
      });
    observer.current?.disconnect();
    for (const child of node.children) observer.current?.observe(child);
  });
  useLayoutEffect(() => () => observer.current?.disconnect(), []);
}

/// Where the parts sit in a row, from its left edge, and the row's width.
type Placed = { width: number; at: Map<Element, number> };

/// Where each part is drawn now, glide in flight included.
function drawnPlaces(node: HTMLElement, selector: string): Placed {
  const origin = node.getBoundingClientRect();
  const at = new Map<Element, number>();
  for (const part of node.querySelectorAll(selector)) at.set(part, part.getBoundingClientRect().left - origin.left);
  return { width: origin.width, at };
}

/// Where each part was last laid out, plus the offset a glide still draws it at.
function stillDrawnAt(laid: Placed): Placed {
  const at = new Map<Element, number>();
  for (const [part, left] of laid.at) at.set(part, left + glideOffset(part));
  return { width: laid.width, at };
}

/// The horizontal offset a running glide draws `part` at (its animated `translate`), 0 when none.
function glideOffset(part: Element): number {
  const glides = part.getAnimations().filter((animation) => animation.id === GLIDE);
  if (glides.length === 0) return 0;
  const translate = part.ownerDocument.defaultView?.getComputedStyle(part).translate ?? "";
  return Number.parseFloat(translate) || 0;
}

/// Puts the parts in their places: each glides from where `first` drew it, unless the row changed
/// width, motion may not run, or there is no `first`, when each lands at once. Returns where they lie.
function glideFrom(node: HTMLElement, selector: string, first: Placed | undefined): Placed {
  const origin = node.getBoundingClientRect();
  const style = node.ownerDocument.defaultView?.getComputedStyle(node);
  const duration = cssTimeMs(style?.getPropertyValue("--agent-motion-move") ?? "") ?? 180;
  const moves =
    first !== undefined && Math.abs(origin.width - first.width) < 0.5 && duration > 0 && motionAllowed(node);
  const easing = style?.getPropertyValue("--agent-ease-out").trim() || "ease-out";
  const at = new Map<Element, number>();
  for (const part of node.querySelectorAll<HTMLElement>(selector)) {
    for (const glide of part.getAnimations()) if (glide.id === GLIDE) glide.cancel();
    const left = part.getBoundingClientRect().left - origin.left;
    at.set(part, left);
    const from = moves ? first.at.get(part) : undefined;
    if (from === undefined || Math.abs(from - left) < 0.5) continue;
    const glide = part.animate([{ translate: `${from - left}px 0` }, { translate: "0 0" }], { duration, easing });
    glide.id = GLIDE;
  }
  return { width: origin.width, at };
}
