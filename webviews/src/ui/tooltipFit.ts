// A tooltip as narrow as its text (Leo, 2026-11-07: "you just have this, like, one, one and a half
// words on a second line, and it's like, okay, why is this even so wide in the first place?").
// Its lines wrap balanced (`text-wrap: balance`, desktop.css), but a balanced box still keeps its max
// width, so the box narrows to its widest line after layout. Every tooltip (ui/Tooltip.tsx and the
// title tooltip, ui/titleTooltips.ts) runs this once as it shows, before it is placed and painted:
// it appears at its final size, and nothing keeps watching it.

/** The width of `tip`'s widest text line: each text node's line boxes, never a block child's box (a
 * `.ui-tooltip-detail` line is as wide as the tooltip). The shortcut's keycap (`.ui-tooltip-hint`)
 * floats to the end of the box, so where it lands says nothing about the text: it counts as its
 * margin box beside the lines it sits next to, never as the span from the text to the box's far
 * edge (https://github.com/manaflow-ai/cmux/issues/49650: "Opus 5.5 ⌃⌘M" drew at the whole max width, wider than the model chip). */
function linesWidth(tip: HTMLElement): number {
  const doc = tip.ownerDocument;
  const range = doc.createRange?.();
  if (!range || typeof range.getClientRects !== "function") return 0;
  const hint = tip.querySelector<HTMLElement>(".ui-tooltip-hint");
  const walker = doc.createTreeWalker(tip, 4 /* NodeFilter.SHOW_TEXT */);
  const lines: { left: number; right: number; top: number; bottom: number }[] = [];
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent?.trim() || hint?.contains(node)) continue;
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) {
      if (!(rect.width > 0)) continue;
      lines.push({ left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom ?? rect.top });
    }
  }
  range.detach?.();
  let keycap: { width: number; top: number; bottom: number } | undefined;
  if (hint) {
    const box = hint.getBoundingClientRect();
    const style = doc.defaultView?.getComputedStyle(hint);
    const margins = style ? (parseFloat(style.marginLeft) || 0) + (parseFloat(style.marginRight) || 0) : 0;
    if (box.width > 0) keycap = { width: Math.max(0, box.width + margins), top: box.top, bottom: box.bottom };
  }
  if (!lines.length) return keycap?.width ?? 0;
  // Each line from its own start (right-aligned in a right-to-left page, the keycap then on its left);
  // lines beside the keycap (its first line, and any other it reaches down to) make room for it.
  // With none measured beside it, it floats beside the first line.
  const first = Math.min(...lines.map((line) => line.top));
  const overlaps = (line: { top: number; bottom: number }) =>
    !!keycap && line.top < keycap.bottom && Math.max(line.bottom, line.top + 1) > keycap.top;
  const anyBeside = lines.some(overlaps);
  const beside = (line: { top: number; bottom: number }) =>
    !!keycap && (anyBeside ? overlaps(line) : line.top === first);
  const widest = Math.max(...lines.map((line) => line.right - line.left + (beside(line) ? keycap!.width : 0)));
  return widest > 0 ? widest : 0;
}

/**
 * Narrows `tip` to the widest of its lines, at most `max` px wide (its max width; the computed
 * `max-width` when not given). A tooltip on one line is as wide as its text; a wrapped one keeps its
 * line count and loses the empty room beside its lines. Measured off any place on the page (an
 * explicit width, not the room left of the tooltip's last place: #22693, never a break inside a
 * word at the window's edge). A width that would wrap one more line is never kept.
 */
export function fitTooltipWidth(tip: HTMLElement, max?: number): void {
  const win = tip.ownerDocument.defaultView;
  tip.style.removeProperty("width");
  if (!win) return;
  const style = win.getComputedStyle(tip);
  const limit = max ?? parseFloat(style.maxWidth);
  if (!(limit > 0) || !Number.isFinite(limit)) return;
  const px = (value: string) => parseFloat(value) || 0;
  const chrome =
    style.boxSizing === "border-box"
      ? px(style.paddingLeft) + px(style.paddingRight) + px(style.borderLeftWidth) + px(style.borderRightWidth)
      : 0;
  tip.style.width = `${limit}px`;
  const height = tip.getBoundingClientRect().height;
  const lines = linesWidth(tip);
  // Rounded up a pixel: a line measured at a fraction narrower than it lays out would wrap again.
  const tight = Math.ceil(lines + chrome) + 1;
  if (!(lines > 0) || tight >= limit) return;
  tip.style.width = `${tight}px`;
  if (tip.getBoundingClientRect().height > height + 0.5) tip.style.width = `${limit}px`;
}
