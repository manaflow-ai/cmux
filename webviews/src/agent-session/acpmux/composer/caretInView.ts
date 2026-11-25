import { Plugin, TextSelection } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import { growthHoldsText } from "./fieldGrowth";

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

// perf-hot: ProseMirror reveals the caret after every key typed (the typed text's transaction asks
// for it), and its reveal reads the caret's rect and every ancestor's box, forcing the edit's layout
// inside the key's own task: about 0.4-0.7 ms of a key's 4.9 ms on Mac WebKit (goal typing-latency,
// cmux16 split of 300 keys). A caret placed in text waits for the frame instead: the same reveal runs
// in its animation-frame callback, before that frame's layout and paint, so the frame drawn is the one
// it drew before and the layout it reads is the one the frame does anyway. Keys typed within one
// frame share one reveal. A node selection (a chip) and a range keep the reveal in the edit.
type RevealingView = EditorView & { scrollToSelection?: () => void };
const revealing = new WeakSet<EditorView>();
const waiting = new WeakSet<EditorView>();

/** Whether ProseMirror's reveal for `view` was taken to the next frame (true: it is not run now). */
export function revealInFrame(view: EditorView): boolean {
  // The reveal this module runs in the frame: ProseMirror's own.
  if (revealing.has(view)) return false;
  const selection = view.state.selection;
  const reveal = (view as RevealingView).scrollToSelection;
  if (!(selection instanceof TextSelection) || !selection.empty) return false;
  if (typeof reveal !== "function" || typeof requestAnimationFrame !== "function") return false;
  if (waiting.has(view)) return true;
  waiting.add(view);
  requestAnimationFrame(() => {
    waiting.delete(view);
    if (view.isDestroyed) return;
    // A growth that started meanwhile holds the text on the field's edge (fieldGrowth.ts).
    const scroller = view.dom.closest<HTMLElement>(".acpmux-md-field");
    if (scroller && growthHoldsText(scroller)) return;
    revealing.add(view);
    try {
      reveal.call(view);
    } finally {
      revealing.delete(view);
    }
  });
  return true;
}

/** The plugin: watches the text column's width and the scroller's height, both of which move the
 *  caret's line without an edit. `margin` is ProseMirror's own `scrollMargin` for this field. */
export function caretInView(margin: number): Plugin {
  return new Plugin({
    props: {
      // Before fieldGrowth's: a growth that holds the text keeps holding it (its own prop says so).
      handleScrollToSelection(view) {
        const scroller = view.dom.closest<HTMLElement>(".acpmux-md-field");
        if (scroller && growthHoldsText(scroller)) return false;
        return revealInFrame(view);
      },
    },
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
          // A move holds the text on the field's bottom edge (fieldGrowth.ts): the
          // caret's line comes into view with it.
          if (growthHoldsText(scroller)) return;
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
