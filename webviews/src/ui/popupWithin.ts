// While a popup is open, its opener carries `data-popup-open` (Base UI's trigger attribute, or ours on
// an imperative opener), and every ancestor of the opener up to its transcript row carries
// `data-popup-within`, so a row keeps its actions shown with a plain attribute rule
// (`.acpmux-turnSummary[data-popup-within] .cv-turn-actions`) where it used
// `:has([data-popup-open])`. Chromium evaluated that `:has()` by walking the whole row for each
// element the rule could style, on every row a page of an older chat mounted: about 250 ms of style
// recalc for 24 older pages (transcript-scroll-up.bench.ts TRACE=3). Each mark counts, so two open
// popups in one row clear only when both close. Every open path pairs with a close: a hook's cleanup
// clears the mark on close and on unmount, and an imperative opener keeps the function it was given.
import { useLayoutEffect } from "react";

export const POPUP_WITHIN = "data-popup-within";
/// Where the marks stop going up: the transcript row (inclusive). Outside a row they go to the root.
const STOP = ".acpmux-row";

const marks = new WeakMap<Element, number>();

/// Marks `opener`'s ancestors; returns the one function that clears them (idempotent).
export function markPopupWithin(opener: Element | null | undefined): () => void {
  const marked: Element[] = [];
  for (let node = opener?.parentElement; node; node = node.parentElement) {
    const count = marks.get(node) ?? 0;
    marks.set(node, count + 1);
    if (count === 0) node.setAttribute(POPUP_WITHIN, "");
    marked.push(node);
    if (node.matches(STOP)) break;
  }
  let cleared = false;
  return () => {
    if (cleared) return;
    cleared = true;
    for (const node of marked) {
      const count = (marks.get(node) ?? 1) - 1;
      if (count > 0) {
        marks.set(node, count);
        continue;
      }
      marks.delete(node);
      node.removeAttribute(POPUP_WITHIN);
    }
  };
}

/// The opener of an imperative popup: sets or clears its `data-popup-open` and its ancestors' marks.
/// Holds one opener per owner: `open` on another clears the last.
export function popupOpener() {
  let current: { opener: Element; clear: () => void } | undefined;
  return {
    open(opener: Element) {
      this.close();
      opener.setAttribute("data-popup-open", "");
      current = { opener, clear: markPopupWithin(opener) };
    },
    close() {
      if (!current) return;
      current.opener.removeAttribute("data-popup-open");
      current.clear();
      current = undefined;
    },
    get opener() {
      return current?.opener;
    },
  };
}

/// For an opener whose `data-popup-open` React renders: marks its ancestors while `open`, before paint
/// (in the same frame as the attribute), and clears them on close and on unmount.
export function usePopupWithin(opener: Element | null | undefined, open: boolean) {
  useLayoutEffect(() => {
    if (!open || !opener) return;
    return markPopupWithin(opener);
  }, [opener, open]);
}
