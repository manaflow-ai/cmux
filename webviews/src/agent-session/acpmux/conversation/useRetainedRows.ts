// Virtualization must not remove the DOM nodes owned by browser selection or keyboard focus.
// Retain only intersected, already-mounted rows; release them when the interaction ends.
import { useLayoutEffect, useState, type RefObject } from "react";

export function useRetainedRows(scroller: RefObject<HTMLDivElement | null>): ReadonlySet<string> {
  const [retained, setRetained] = useState<Set<string>>(() => new Set());
  useLayoutEffect(() => {
    const root = scroller.current;
    if (!root) return;
    const doc = root.ownerDocument;
    const update = () => {
      const next = new Set<string>();
      const selection = doc.getSelection();
      for (const row of root.querySelectorAll<HTMLElement>("[data-row-id]")) {
        if (row.contains(doc.activeElement)) next.add(row.dataset.rowId!);
        if (!selection || selection.isCollapsed) continue;
        for (let index = 0; index < selection.rangeCount; index += 1) {
          if (selection.getRangeAt(index).intersectsNode(row)) next.add(row.dataset.rowId!);
        }
      }
      setRetained((previous) =>
        previous.size === next.size && [...next].every((id) => previous.has(id)) ? previous : next,
      );
    };
    doc.addEventListener("selectionchange", update);
    doc.addEventListener("focusin", update);
    doc.addEventListener("focusout", update);
    return () => {
      doc.removeEventListener("selectionchange", update);
      doc.removeEventListener("focusin", update);
      doc.removeEventListener("focusout", update);
    };
  }, [scroller]);
  return retained;
}
