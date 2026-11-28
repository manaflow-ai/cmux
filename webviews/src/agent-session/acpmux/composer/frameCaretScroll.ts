import { Plugin } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

// A typed key's caret scroll runs in the frame that draws the key, not in the key's own task.
// ProseMirror scrolls the caret into view inside every dispatch that asks for it (each typed
// character does): `coordsAtPos` and a rect per scrolling ancestor, a synchronous layout of the
// edit in WebKit. The edit's other DOM writes come after it (the composer's commit, the
// placeholder, the field's growth mark), so the frame laid the field out twice, once inside the
// key (goal typing-latency, the bench's `to_work`). Here a collapsed caret's scroll waits for the
// next animation frame and then runs ProseMirror's own scroll against that frame's layout, which
// the paint reuses: the caret is in view on the same frame as before, and the key does no layout.
// A selection (Shift-arrows, select all) keeps the immediate scroll, and an engine without
// `requestAnimationFrame` does too.

/** The plugin: defers ProseMirror's scroll-to-selection for a collapsed caret to the next frame. */
export function frameCaretScroll(): Plugin {
  let frame: number | undefined;
  let through = false;
  let target: EditorView | undefined;
  const run = () => {
    frame = undefined;
    const view = target;
    if (!view || view.isDestroyed) return;
    through = true;
    try {
      // An empty transaction that asks for the scroll: ProseMirror's own path, this time let through.
      view.dispatch(view.state.tr.scrollIntoView());
    } finally {
      through = false;
    }
  };
  return new Plugin({
    props: {
      handleScrollToSelection(view) {
        if (through || typeof requestAnimationFrame !== "function" || !view.state.selection.empty) return false;
        target = view;
        frame ??= requestAnimationFrame(run);
        return true;
      },
    },
    view: () => ({
      destroy() {
        if (frame !== undefined) cancelAnimationFrame(frame);
        frame = undefined;
        target = undefined;
      },
    }),
  });
}
