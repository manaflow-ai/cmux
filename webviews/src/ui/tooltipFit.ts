// A tooltip as narrow as its text (Leo, 2026-11-07: "you just have this, like, one, one and a half
// words on a second line, and it's like, okay, why is this even so wide in the first place?").
// Its lines wrap balanced (`text-wrap: balance`, desktop.css), but a balanced box still keeps its max
// width, so the box narrows to its widest line after layout. Every tooltip (ui/Tooltip.tsx and the
// title tooltip, ui/titleTooltips.ts) runs this once as it shows, before it is placed and painted:
// it appears at its final size, and nothing keeps watching it.

/** The union of `tip`'s text lines, left to right: each text node's line boxes, never a block
 * child's box (a `.ui-tooltip-detail` line is as wide as the tooltip). */
function linesWidth(tip: HTMLElement): number {
  const doc = tip.ownerDocument;
  const range = doc.createRange?.();
  if (!range || typeof range.getClientRects !== "function") return 0;
  const walker = doc.createTreeWalker(tip, 4 /* NodeFilter.SHOW_TEXT */);
  let left = Infinity;
  let right = -Infinity;
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent?.trim()) continue;
    range.selectNodeContents(node);
    for (const rect of range.getClientRects()) {
      if (!(rect.width > 0)) continue;
      left = Math.min(left, rect.left);
      right = Math.max(right, rect.right);
    }
  }
  range.detach?.();
  return right > left ? right - left : 0;
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
