// l10n-allow-file: detector diagnostics, not shipped UI.
// The hard-clip detector: text a box cuts mid-word with nothing to say it was cut. Leo, 2026-11-22,
// on the composer hat's "… · 8 done · 5 stc" (its "5 stopped" cut by the strip's overflow): "this
// should not be cutting off so harshly like this. we basically never want that kinda shit"; and on
// the started line's "✧ M… , ✧ iO… , ✧ i…": "this is so fucking awkward as ui".
//
// `findHardClips` runs in the page (Playwright's `page.evaluate`), over every text node under `root`:
// - a text node partly inside and partly outside the box of an ancestor that clips it (overflow other
//   than visible) is HARD-CLIPPED, unless that ancestor ends its text in an ellipsis (`text-overflow:
//   ellipsis` on a block box, where it applies; on a flex or grid container it does nothing) or a mask
//   fades it out (`mask-image` on the way up). A node wholly outside (a whole segment dropped onto a
//   hidden line) is fine: nothing is cut mid-word.
// - an ellipsized name that keeps fewer than `minChars` of its characters (Leo's "M…", "iO…") is
//   ILLEGIBLE: an ellipsis that leaves a letter or two says nothing.
// It is one function with no closure, so `page.evaluate` can ship it to the page as it is.

export type ClipFinding = {
  kind: "hard-clip" | "illegible";
  /** The text node's text. */
  text: string;
  /** About how many of its characters are seen. */
  visibleChars: number;
  /** The clipping box, as `tag.class.class`. */
  clipper: string;
};

export function findHardClips(args: { root?: string; minChars?: number }): ClipFinding[] {
  const minChars = args.minChars ?? 4;
  const root = (args.root ? document.querySelector(args.root) : document.body) ?? document.body;
  const describe = (element: Element) =>
    `${element.tagName.toLowerCase()}${[...element.classList].map((name) => `.${name}`).join("")}`;
  const hidden = (element: Element): boolean => {
    for (let node: Element | null = element; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return true;
    }
    return false;
  };
  const findings: ClipFinding[] = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = node.textContent ?? "";
    if (!text.trim()) continue;
    const parent = node.parentElement;
    if (!parent || hidden(parent)) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()].filter((rect) => rect.width > 0.5 && rect.height > 0.5);
    if (!rects.length) continue;
    const left = Math.min(...rects.map((rect) => rect.left));
    const right = Math.max(...rects.map((rect) => rect.right));
    const top = Math.min(...rects.map((rect) => rect.top));
    const bottom = Math.max(...rects.map((rect) => rect.bottom));
    const width = right - left;
    // Walk up: the visible part of the text after each clipping ancestor, and the first that cuts it.
    let seenLeft = left;
    let seenRight = right;
    let seenTop = top;
    let seenBottom = bottom;
    let cutter: Element | undefined;
    let faded = false;
    for (
      let element: Element | null = parent;
      element && element !== document.documentElement;
      element = element.parentElement
    ) {
      const style = getComputedStyle(element);
      const mask = style.maskImage || (style as unknown as { webkitMaskImage?: string }).webkitMaskImage || "none";
      if (mask !== "none") faded = true;
      if (style.overflowX === "visible" && style.overflowY === "visible") continue;
      const box = element.getBoundingClientRect();
      // A screen-reader-only box (1px, clipped) is no visible text.
      if (box.width <= 1 || box.height <= 1) {
        seenRight = seenLeft;
        break;
      }
      const before = { seenLeft, seenRight, seenTop, seenBottom };
      seenLeft = Math.max(seenLeft, box.left);
      seenRight = Math.min(seenRight, box.right);
      seenTop = Math.max(seenTop, box.top);
      seenBottom = Math.min(seenBottom, box.bottom);
      if (
        !cutter &&
        (seenLeft > before.seenLeft + 1 || seenRight < before.seenRight - 1) &&
        seenRight > seenLeft &&
        seenBottom > seenTop
      )
        cutter = element;
    }
    // Wholly out of sight above or below (a dropped segment on a hidden line): nothing cut mid-word.
    if (seenBottom <= seenTop + 0.5) continue;
    // On its line but cut away side to side: an ellipsized chip that keeps nothing (Leo's started line
    // at seven names drew empty chips) is illegible; anything else is scrolled out of view.
    const emptied = seenRight <= seenLeft + 0.5;
    const chars = text.trim().length;
    const seenChars = Math.round((chars * (seenRight - seenLeft)) / Math.max(width, 1));
    // Ellipsis draws inside the box that overflows (no rect change); find it on the way up to the cutter
    // or, with no cutter, on the parent whose own scroll width shows it cut.
    let ellipsized: Element | undefined;
    for (
      let element: Element | null = parent;
      element && element !== document.documentElement;
      element = element.parentElement
    ) {
      const style = getComputedStyle(element);
      const block = !/flex|grid/.test(style.display);
      if (style.textOverflow === "ellipsis" && block && style.overflowX !== "visible") {
        if (element.scrollWidth > element.clientWidth + 1) ellipsized = element;
        break;
      }
      if (element === cutter) break;
    }
    if (emptied) {
      // Only when the ellipsized box itself has no room for `minChars` letters (an empty chip); text
      // scrolled out of a box that shows words is fine.
      const room = ellipsized?.getBoundingClientRect().width ?? Infinity;
      const letter = ellipsized ? parseFloat(getComputedStyle(ellipsized).fontSize) * 0.6 : 0;
      if (ellipsized && room < minChars * letter && text.trim().length > minChars)
        findings.push({ kind: "illegible", text: text.trim(), visibleChars: 0, clipper: describe(ellipsized) });
      continue;
    }
    if (ellipsized) {
      // The text the ellipsis leaves: the box's room over the text's full width.
      const room = ellipsized.getBoundingClientRect().width;
      const kept = Math.max(0, Math.round((chars * room) / Math.max(ellipsized.scrollWidth, 1)) - 1);
      if (chars > minChars && kept < minChars)
        findings.push({ kind: "illegible", text: text.trim(), visibleChars: kept, clipper: describe(ellipsized) });
      continue;
    }
    if (cutter && !faded)
      findings.push({ kind: "hard-clip", text: text.trim(), visibleChars: seenChars, clipper: describe(cutter) });
  }
  return findings;
}
