// Where the unread "New" line lies in the gap it marks: midway between what the eye sees of the row
// above and of the row under it, not between their boxes. User, 2026-11-23, on a line centred in the
// box gap that still read off (manaflow-ai/cmux#51747): "it always must be even the position". A
// row's box ends in empty room that differs by kind: a footer row's icons sit 8 px above its bottom,
// a one-line row's words 3 px under its top, and a line of words has its font's empty ascent over its
// capitals. So the line reads the drawn content's edges: an icon or picture by its box, a box drawn
// with a fill or border by its edge, words by their glyphs (canvas font metrics), and lies halfway.

/// How far into a row, from the edge that faces the line, content can be and still count. A tall reply
/// is not walked whole: only what lies near its edge.
const NEAR = 64;

type Side = "bottom" | "top";

let context: CanvasRenderingContext2D | null | undefined;
const metrics = new Map<string, { ascent: number; descent: number; up: number; down: number }>();

/// The font's ascent and descent (its line box over and under the baseline) and the glyphs' own extent
/// above and under the baseline, for `text` set in `font`.
function glyphs(font: string, text: string) {
  const key = `${font}\u0000${text}`;
  let found = metrics.get(key);
  if (found) return found;
  context ??= document.createElement("canvas").getContext("2d");
  if (!context) return undefined;
  context.font = font;
  const m = context.measureText(text);
  found = {
    ascent: m.fontBoundingBoxAscent,
    descent: m.fontBoundingBoxDescent,
    up: m.actualBoundingBoxAscent,
    down: m.actualBoundingBoxDescent,
  };
  if (metrics.size > 256) metrics.clear();
  metrics.set(key, found);
  return found;
}

const transparent = (color: string) => color === "transparent" || /rgba\([^)]*,\s*0\)$/.test(color);

/// Whether an element draws a box of its own: a picture, or a fill or border the eye reads as an edge.
function drawsBox(element: Element, style: CSSStyleDeclaration): boolean {
  if (/^(svg|img|video|canvas|input|textarea|select)$/i.test(element.tagName)) return true;
  if (!transparent(style.backgroundColor) || style.backgroundImage !== "none") return true;
  return (
    (parseFloat(style.borderTopWidth) > 0 && !transparent(style.borderTopColor)) ||
    (parseFloat(style.borderBottomWidth) > 0 && !transparent(style.borderBottomColor))
  );
}

/// The edge of what `row` draws on its `side` (its bottom for the row above the line, its top for the
/// row under it), in viewport px, or undefined when it draws nothing there.
export function inkEdge(row: Element, side: Side): number | undefined {
  const frame = row.getBoundingClientRect();
  const near = (top: number, bottom: number) =>
    side === "bottom" ? bottom >= frame.bottom - NEAR : top <= frame.top + NEAR;
  let edge: number | undefined;
  const take = (y: number) => {
    edge = edge === undefined ? y : side === "bottom" ? Math.max(edge, y) : Math.min(edge, y);
  };
  const walk = (element: Element) => {
    const style = getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || parseFloat(style.opacity) === 0) return;
    // The row's own gap target (RowFrame) draws nothing.
    if (element.hasAttribute("data-transcript-gap")) return;
    const box = element.getBoundingClientRect();
    // A box wholly far from the facing edge holds nothing near it (a tall reply is not walked whole),
    // unless it has no box of its own (`contents`, or 0 px with children that overflow it).
    const sized = box.height > 0 && style.display !== "contents";
    if (sized && !near(box.top, box.bottom)) return;
    if (element !== row && drawsBox(element, style) && box.height > 0 && near(box.top, box.bottom)) {
      take(side === "bottom" ? box.bottom : box.top);
      if (/^(svg|img|video|canvas)$/i.test(element.tagName)) return;
    }
    for (const child of element.childNodes) {
      if (child.nodeType === Node.ELEMENT_NODE) walk(child as Element);
      else if (child.nodeType === Node.TEXT_NODE && child.textContent?.trim()) text(child as Text, style);
    }
  };
  const text = (node: Text, style: CSSStyleDeclaration) => {
    const range = document.createRange();
    range.selectNodeContents(node);
    const lines = [...range.getClientRects()].filter((r) => r.height > 0);
    const line = side === "bottom" ? lines.at(-1) : lines[0];
    if (!line || !near(line.top, line.bottom)) return;
    const font = style.font || `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const shape = glyphs(font, node.textContent!.trim());
    if (!shape || !Number.isFinite(shape.ascent) || shape.ascent <= 0 || !(shape.descent > 0)) {
      take(side === "bottom" ? line.bottom : line.top);
      return;
    }
    // The page rounds a line's text box (13 px system text: 15 px, where the canvas says 13 + 3), so
    // the baseline lies at the ascent's share of the box as laid out, not at the canvas's ascent.
    const baseline = line.top + (line.height * shape.ascent) / (shape.ascent + shape.descent);
    take(side === "bottom" ? baseline + shape.down : baseline - shape.up);
  };
  walk(row);
  return edge;
}

/// The rows the line splits: the transcript's rows are placed absolutely, so they are found by place,
/// not by order: the nearest that ends at or above the line's row, and the nearest that starts under it.
function neighbours(mark: Element): { above?: Element; under?: Element } {
  const own = mark.closest("[data-row-id]");
  const rows = own?.parentElement?.children;
  if (!own || !rows) return {};
  const top = own.getBoundingClientRect().top;
  let above: Element | undefined;
  let under: Element | undefined;
  let aboveTop = -Infinity;
  let underTop = Infinity;
  for (const row of rows) {
    if (row === own || !row.hasAttribute("data-row-id")) continue;
    const box = row.getBoundingClientRect();
    if (box.height === 0) continue;
    if (box.top < top - 0.5 && box.top > aboveTop) [above, aboveTop] = [row, box.top];
    else if (box.top >= top - 0.5 && box.top < underTop) [under, underTop] = [row, box.top];
  }
  return { above, under };
}

/// Writes `--cv-since-ink` on the mark: the line's centre, in px from the mark's top, halfway between
/// the drawn edges of the rows around it; removes it when either side draws nothing (the line then
/// keeps the gap's middle, unread.css). Returns the rows it read, for the caller to watch.
export function placeSinceLine(mark: HTMLElement): Element[] {
  const { above, under } = neighbours(mark);
  const low = above && inkEdge(above, "bottom");
  const high = under && inkEdge(under, "top");
  if (low === undefined || high === undefined || high <= low) {
    mark.style.removeProperty("--cv-since-ink");
  } else {
    const centre = (low + high) / 2 - mark.getBoundingClientRect().top;
    mark.style.setProperty("--cv-since-ink", `${Math.round(centre * 4) / 4}px`);
  }
  return [above, under].filter((row): row is Element => row !== undefined);
}
