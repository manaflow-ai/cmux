// The UI inspector's live label and hint, as a model (Leo, 2026-11-08: "you should be able to just
// see maybe some sort of preview as you're going and hovering"). While picking, a label beside the
// outline names the element (its component, else its tag, and a short selector), quotes its text and
// gives its size and key styles, so the person sees what a click would pick before clicking. A
// one-line hint says what the picker is for and which keys it takes.
//
// Where the label sits: beside the outline, never over it, and always whole on screen. Each
// placement is an order of sides to try; the first side where the label fits inside the viewport
// (its cross axis clamped to the edges) without touching the element wins. An element too big for
// any side (a whole column) takes the spot that covers it least. The hint keeps to the top edge and
// moves to the bottom when the pointer, the outline or the label is under it.
import { componentOf, selectorOf } from "./report";

/** How much the label says: one line; a name line and the text; or those and the key styles. */
export type LabelDensity = "compact" | "standard" | "card";
/** Where the label goes first: above the outline (flips below), below (flips above), at its side, or inside its corner. */
export type LabelPlacement = "above" | "below" | "side" | "inside";
export type LabelSide = "above" | "below" | "right" | "left" | "inside" | "over";

/**
 * The shipped label (gallery `agent-pane.ui-inspector` compares the rest): the card, because the
 * styles answer "what is this UI thing" and its three short lines still fit a narrow pane; above the
 * outline first, as the eye reads a name before the thing it names, flipping below at the top edge.
 */
export const UI_POINTER_LABEL_DENSITY: LabelDensity = "card";
export const UI_POINTER_LABEL_PLACEMENT: LabelPlacement = "above";

/** The label's and hint's distance from the viewport's edges, in CSS px. */
export const UI_POINTER_EDGE = 4;
/** The gap between the outline and the label. */
export const UI_POINTER_LABEL_GAP = 4;
/** How far around the hint the pointer, outline or label pushes it to the other edge. */
const HINT_CLEARANCE = 8;
/** The longest text quote the label shows, in characters. */
const SNIPPET_LIMIT = 80;

export type Box = { x: number; y: number; width: number; height: number };
type Size = { width: number; height: number };

const ORDER: Record<LabelPlacement, LabelSide[]> = {
  above: ["above", "below", "right", "left"],
  below: ["below", "above", "right", "left"],
  side: ["right", "left", "above", "below"],
  inside: ["inside"],
};

const clamp = (value: number, low: number, high: number) => Math.max(low, Math.min(value, high));

const overlapArea = (a: Box, b: Box) =>
  Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x)) *
  Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));

/** The part of `box` inside the viewport (a box past an edge is measured from what shows). */
function visiblePart(box: Box, view: Size): Box {
  const x = clamp(box.x, 0, view.width);
  const y = clamp(box.y, 0, view.height);
  return {
    x,
    y,
    width: clamp(box.x + box.width, 0, view.width) - x,
    height: clamp(box.y + box.height, 0, view.height) - y,
  };
}

/** Where the label goes for `target` (viewport px): its top-left corner and the side it took. */
export function placeLabel(
  target: Box,
  label: Size,
  view: Size,
  placement: LabelPlacement,
): { x: number; y: number; side: LabelSide } {
  const t = visiblePart(target, view);
  const minX = UI_POINTER_EDGE;
  const minY = UI_POINTER_EDGE;
  // The last top-left corner that keeps the label whole on screen; a label wider (or taller) than
  // the viewport has none, so its bound stays at the near edge: it starts there and runs past the far one.
  const lastX = view.width - UI_POINTER_EDGE - label.width;
  const lastY = view.height - UI_POINTER_EDGE - label.height;
  const maxX = Math.max(minX, lastX);
  const maxY = Math.max(minY, lastY);
  const gap = UI_POINTER_LABEL_GAP;
  const spot = (side: LabelSide) => {
    switch (side) {
      case "above":
        return { x: clamp(t.x, minX, maxX), y: t.y - gap - label.height };
      case "below":
        return { x: clamp(t.x, minX, maxX), y: t.y + t.height + gap };
      case "right":
        return { x: t.x + t.width + gap, y: clamp(t.y, minY, maxY) };
      case "left":
        return { x: t.x - gap - label.width, y: clamp(t.y, minY, maxY) };
      default:
        return { x: clamp(t.x + gap, minX, maxX), y: clamp(t.y + gap, minY, maxY) };
    }
  };
  const sides = ORDER[placement];
  for (const side of sides) {
    const at = spot(side);
    const inside = at.x >= minX && at.y >= minY && at.x <= lastX && at.y <= lastY;
    if (inside && (side === "inside" || overlapArea({ ...at, ...label }, t) === 0)) return { ...at, side };
  }
  // No side fits whole: every side's spot pulled on screen, the one that covers the element least.
  let best = { x: minX, y: minY, side: "over" as LabelSide };
  let bestArea = Number.POSITIVE_INFINITY;
  for (const side of [...sides, "inside" as const]) {
    const at = spot(side);
    const x = clamp(at.x, minX, maxX);
    const y = clamp(at.y, minY, maxY);
    const area = overlapArea({ x, y, ...label }, t);
    if (area < bestArea) {
      best = { x, y, side: "over" };
      bestArea = area;
    }
  }
  return best;
}

/** The edge the hint takes: the top, unless something it must not cover is there and not at the bottom. */
export function hintEdge(hint: Size, view: Size, obstacles: readonly Box[]): "top" | "bottom" {
  const x = (view.width - hint.width) / 2 - HINT_CLEARANCE;
  const width = hint.width + 2 * HINT_CLEARANCE;
  const height = hint.height + 2 * HINT_CLEARANCE;
  const top = { x, y: UI_POINTER_EDGE - HINT_CLEARANCE, width, height };
  const bottom = { x, y: view.height - UI_POINTER_EDGE - hint.height - HINT_CLEARANCE, width, height };
  const covers = (box: Box) =>
    obstacles.some(
      (o) => o.x <= box.x + box.width && box.x <= o.x + o.width && o.y <= box.y + box.height && box.y <= o.y + o.height,
    );
  return covers(top) && !covers(bottom) ? "bottom" : "top";
}

/** What the label says about an element. `snippet` is null for an element with no text. */
export type LabelFacts = {
  name: string;
  selector: string;
  snippet: string | null;
  size: string;
  font: string;
  color: string;
  display: string;
};

/** The short selector the label shows: the tag with the id, test id or first class that names it. */
function shortSelector(element: Element): string {
  const tag = element.localName || "element";
  const selector = selectorOf(element);
  if (selector.startsWith("#")) return `${tag}${selector}`;
  if (selector === tag && element.classList.length > 0) return `${tag}.${element.classList[0]}`;
  return selector;
}

export function labelFacts(element: Element): LabelFacts {
  const view = element.ownerDocument.defaultView ?? window;
  const rect = element.getBoundingClientRect();
  const computed = view.getComputedStyle(element);
  const text = ((element as HTMLElement).innerText ?? element.textContent ?? "").replace(/\s+/g, " ").trim();
  return {
    name: componentOf(element) ?? (element.localName || "element"),
    selector: shortSelector(element),
    snippet: text ? (text.length > SNIPPET_LIMIT ? `${text.slice(0, SNIPPET_LIMIT - 1)}…` : text) : null,
    size: `${Math.round(rect.width)}×${Math.round(rect.height)}`,
    font: `${computed.fontSize} ${computed.fontWeight}`,
    color: computed.color,
    display: computed.display,
  };
}
