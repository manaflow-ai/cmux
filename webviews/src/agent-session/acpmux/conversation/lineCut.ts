// Stop an agent preview between rendered lines and atomic chips/code, never under a fade.
export type Span = { top: number; bottom: number };

export function cutBetween(spans: readonly Span[], limit: number): number {
  let cut = limit;
  for (let moved = true; moved;) {
    moved = false;
    for (const span of spans) {
      if (span.top < cut && span.bottom > cut) {
        cut = Math.max(0, span.top);
        moved = cut > 0;
      }
    }
  }
  // An oversized first block leaves only Show more; never fall back to clipping it.
  return cut;
}

export function wholeLineCut(box: HTMLElement, limit: number): number {
  const bounds = box.getBoundingClientRect();
  // DOM rectangles include CSS zoom; max-height and line-height are unzoomed CSS pixels.
  const width = parseFloat(box.ownerDocument.defaultView!.getComputedStyle(box).width);
  const scale = width > 0 ? bounds.width / width : 1;
  const top = bounds.top - box.scrollTop * scale;
  const spans: Span[] = [];
  const add = (rects: DOMRectList) => {
    for (const rect of rects)
      if (rect.height > 0 && (rect.top - top) / scale < limit)
        spans.push({ top: (rect.top - top) / scale, bottom: (rect.bottom - top) / scale });
  };
  const range = box.ownerDocument.createRange();
  const walker = box.ownerDocument.createTreeWalker(box, 4 /* SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.nodeValue?.trim()) continue;
    range.selectNodeContents(node);
    add(range.getClientRects());
  }
  // Code-card host bounds include both the header and the body inside any shadow root.
  for (const element of box.querySelectorAll(
    "img, svg, video, canvas, code, kbd, button, input, tr, .cv-chip, .cv-codeblock, diffs-container",
  ))
    add(element.getClientRects());
  return cutBetween(spans, limit);
}
