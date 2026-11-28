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
