// Finds every label + disclosure chevron pair on a page and measures the room between them: from the
// right edge of the last readable words before the chevron (cut to any box that clips them, so an
// ellipsis counts where it ends) to the left edge of the chevron's ink (its path's box, or a text
// glyph's own box), on the same line, inside one control. design/chevrons.md.
//
// A chevron is a registry glyph `disclosure.*`, the composer's ChevronIcon path, a box whose class
// names a chevron or caret, or a text "⌄"; it counts only when words sit before it in the same
// button, menu trigger or summary (a standalone chevron button has no label to keep apart from).
import type { Page } from "playwright";

export type ChevronPair = {
  /** The control's class and the first words of its text, for a failure message. */
  control: string;
  /** Chevron ink left minus the words' right edge, CSS px: negative is an overlap. */
  gap: number;
  /** Whether the chevron's ink is cut by a box around it (clipped). */
  clipped: boolean;
  /** How the chevron is drawn: `svg` or `text`. */
  kind: "svg" | "text";
};

export const measureDisclosureChevrons = (page: Page): Promise<ChevronPair[]> =>
  page.evaluate(() => {
    const CHEVRON_PATHS = new Set(["M4.6 6.3 8 9.6l3.4-3.3"]);
    const TRIGGER = "button, [role='button'], [aria-haspopup], summary, .acpmux-picker-button";
    const readable = (element: Element) => {
      for (let node: Element | null = element; node; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
      }
      return true;
    };
    const isChevron = (element: Element) => {
      if (element.matches("[data-icon^='disclosure'], [data-icon='chevron']")) return true;
      if (
        element.matches("svg") &&
        [...element.querySelectorAll("path")].some((p) => CHEVRON_PATHS.has(p.getAttribute("d") ?? ""))
      )
        return true;
      const name = typeof element.className === "string" ? element.className : (element.getAttribute("class") ?? "");
      if (/(^|[\s_-])(chevron|caret)([\s_-]|$)/i.test(name) && !/submenu/.test(name)) return true;
      return element.childElementCount === 0 && element.textContent?.trim() === "⌄";
    };
    /** The ink box: an svg's drawn paths, or a text glyph's range. */
    const ink = (element: Element): DOMRect | null => {
      const svg = element.matches("svg") ? element : element.querySelector("svg");
      if (svg) {
        const parts = [...svg.querySelectorAll("path, polyline, line")].map((p) => p.getBoundingClientRect());
        if (parts.length === 0) return svg.getBoundingClientRect();
        const left = Math.min(...parts.map((r) => r.left));
        const right = Math.max(...parts.map((r) => r.right));
        const top = Math.min(...parts.map((r) => r.top));
        const bottom = Math.max(...parts.map((r) => r.bottom));
        return new DOMRect(left, top, right - left, bottom - top);
      }
      const text = [...element.childNodes].find((n) => n.nodeType === Node.TEXT_NODE && n.textContent?.trim());
      if (text) {
        const range = document.createRange();
        range.selectNodeContents(text);
        return range.getBoundingClientRect();
      }
      // A CSS-drawn chevron (a mask or a border): the element's own box.
      return element.getBoundingClientRect();
    };
    /** The right edge `right` is cut to by the clipping boxes between `from` and `top`. */
    const clippedRight = (from: Element, top: Element, right: number) => {
      let edge = right;
      for (let node: Element | null = from; node && node !== top.parentElement; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.display === "contents") continue;
        if (style.overflowX !== "visible" || style.textOverflow === "ellipsis")
          edge = Math.min(edge, node.getBoundingClientRect().right);
      }
      return edge;
    };
    const out: ChevronPair[] = [];
    const seen = new Set<Element>();
    for (const candidate of document.querySelectorAll("svg, span, i, div")) {
      if (!isChevron(candidate) || !readable(candidate)) continue;
      // The outermost chevron box (a span around an svg counts once).
      let chevron: Element = candidate;
      while (chevron.parentElement && isChevron(chevron.parentElement)) chevron = chevron.parentElement;
      if (seen.has(chevron)) continue;
      seen.add(chevron);
      // Its control, or (a transcript row's chevron beside its toggle) the box it sits in.
      const trigger =
        chevron.parentElement?.closest(TRIGGER) ?? (chevron.closest(".acpmux-row") ? chevron.parentElement : null);
      if (!trigger) continue;
      const glyph = ink(chevron);
      if (!glyph || glyph.width === 0 || glyph.height === 0) continue;
      const middle = (glyph.top + glyph.bottom) / 2;
      /** The right edge of the last words before the chevron on its line inside `scope`. */
      const wordsEnd = (scope: Element) => {
        let end: number | null = null;
        const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!parent || !node.textContent?.trim() || chevron.contains(parent) || !readable(parent)) continue;
          if (parent.closest(".visually-hidden, .sr-only")) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.width === 0 || rect.top > middle || rect.bottom < middle) continue;
            // Words that start after the chevron are its trail, not its label.
            if (rect.left >= glyph.left + glyph.width / 2) continue;
            // Words far before it (another column of the row) are not its label.
            if (glyph.left - rect.right > 24) continue;
            const right = clippedRight(parent, scope, rect.right);
            if (end === null || right > end) end = right;
          }
        }
        return end;
      };
      // A chevron alone in its button (a row's toggle after a sender's chip) reads the line around it.
      let end: number | null = null;
      for (
        let scope: Element | null = trigger, up = 0;
        scope && up < 4 && end === null;
        scope = scope.parentElement, up++
      )
        end = wordsEnd(scope);
      if (end === null) continue;
      // The chevron's ink cut by a clipping box around it inside the control.
      let clipped = false;
      for (let node = chevron.parentElement; node && node !== trigger.parentElement; node = node.parentElement) {
        const style = getComputedStyle(node);
        if (style.overflowX === "visible") continue;
        const box = node.getBoundingClientRect();
        if (glyph.right > box.right + 0.5 || glyph.left < box.left - 0.5) clipped = true;
      }
      out.push({
        control: `${(typeof trigger.className === "string" ? trigger.className : "") || trigger.tagName} | ${(trigger.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 40)}`,
        gap: Math.round((glyph.left - end) * 100) / 100,
        clipped,
        kind: chevron.querySelector("svg") || chevron.matches("svg") ? "svg" : "text",
      });
    }
    return out;
  });
