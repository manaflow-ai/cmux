import { Plugin } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";

// The prompt's caret stays in view when the draft rewraps under it (https://github.com/manaflow-ai/cmux/issues/28672).
// ProseMirror scrolls the caret into view when a transaction asks for it, against the layout of
// that moment. The draft can rewrap later without a transaction: the actions beside it change width
// (Send takes the mic's place on the first character, Stop comes with a turn) and their padding
// (composerScrollLane.ts) narrows the text column, the pane is resized, or the field's height cap
// changes with the window. The caret's line then moved, often below the field's bottom edge, and
// stayed hidden until the next key. This keeps it in view across those changes, while the field has
// focus and the person has not scrolled the draft away from the caret since their last edit.

/** Scrolls `scroller` the least that shows `view`'s caret, `margin` px clear of its edges where the
 *  field is tall enough for that. */
export function revealCaret(view: EditorView, scroller: HTMLElement, margin: number): void {
  let caret: { top: number; bottom: number };
  try {
    // The side ProseMirror's own reveal reads (scrollToSelection), so both agree at a soft wrap.
    caret = view.coordsAtPos(view.state.selection.head, 1);
  } catch {
    return;
  }
  const top = scroller.getBoundingClientRect().top + scroller.clientTop;
  const bottom = top + scroller.clientHeight;
  // A field only a few lines tall keeps the caret's line whole before it keeps the margin.
  const clear = Math.max(0, Math.min(margin, (scroller.clientHeight - (caret.bottom - caret.top)) / 2));
  if (caret.bottom > bottom - clear) scroller.scrollTop += caret.bottom - (bottom - clear);
  else if (caret.top < top + clear) scroller.scrollTop -= top + clear - caret.top;
}

/** The plugin: watches the text column's width and the scroller's height, both of which move the
 *  caret's line without an edit. `margin` is ProseMirror's own `scrollMargin` for this field. */
export function caretInView(margin: number): Plugin {
  return new Plugin({
    view(view) {
      if (typeof ResizeObserver !== "function") return {};
      // Set when the person scrolls the draft themselves (wheel, touch, the scrollbar); an edit or a
      // caret move clears it. While set, a rewrap leaves the scroll where they put it.
      let away = false;
      let stop: (() => void) | undefined;
      // The editor may be made before its element joins the field: it attaches on the first update
      // that finds the field around it.
      const attach = () => {
        const scroller = view.dom.closest<HTMLElement>(".acpmux-md-field");
        if (!scroller) return;
        const leave = () => {
          away = true;
        };
        // A press on the scrollbar's lane at the field's right edge, not on its padding (a padding
        // press places the caret, which clears `away` again).
        const scrollbarPress = (event: PointerEvent) => {
          if (event.target === scroller && event.offsetX >= scroller.clientWidth) away = true;
        };
        scroller.addEventListener("wheel", leave, { passive: true });
        scroller.addEventListener("touchmove", leave, { passive: true });
        scroller.addEventListener("pointerdown", scrollbarPress);
        let width = -1;
        let height = -1;
        const observer = new ResizeObserver(() => {
          const nextWidth = view.dom.clientWidth;
          const nextHeight = scroller.clientHeight;
          if (nextWidth === width && nextHeight === height) return;
          const first = width < 0;
          width = nextWidth;
          height = nextHeight;
          if (first || away || !view.hasFocus()) return;
          revealCaret(view, scroller, margin);
        });
        observer.observe(view.dom);
        observer.observe(scroller);
        stop = () => {
          observer.disconnect();
          scroller.removeEventListener("wheel", leave);
          scroller.removeEventListener("touchmove", leave);
          scroller.removeEventListener("pointerdown", scrollbarPress);
        };
      };
      attach();
      return {
        update(next, previous) {
          if (!stop) attach();
          if (!next.state.doc.eq(previous.doc) || !next.state.selection.eq(previous.selection)) away = false;
        },
        destroy() {
          stop?.();
        },
      };
    },
  });
}
