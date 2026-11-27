// Whether the primary button is down in the editor (a click or a drag selecting text,
// MARKDOWN-SELECTION). Decorations that follow the selection (Obsidian syntax shown at the caret,
// the active block's source) hold still while it is: changing them mid-drag moved the text under
// the pointer, so the selection ended on other words. The release brings them up to date.
import { Plugin, PluginKey, type EditorState } from "@milkdown/kit/prose/state";
import type { EditorView } from "@milkdown/kit/prose/view";
import { $prose } from "@milkdown/kit/utils";

const pointerKey = new PluginKey<boolean>("cmuxMarkdownPointerSelect");

/** Whether the primary button is down in the editor. */
export function isPointerSelecting(state: EditorState): boolean {
  return pointerKey.getState(state) === true;
}

/** Whether `tr` pressed or released the button (decorations that held still recompute). */
export function pointerChanged(tr: { getMeta(key: PluginKey): unknown }): boolean {
  return tr.getMeta(pointerKey) !== undefined;
}

/** Marks the button down for a press the editor never saw (one in the page's padding, paddingSelect.ts). */
export function markPointerDown(view: EditorView): void {
  set(view, true);
}

function set(view: EditorView, down: boolean): void {
  if (view.isDestroyed || isPointerSelecting(view.state) === down) return;
  view.dispatch(view.state.tr.setMeta(pointerKey, down).setMeta("addToHistory", false));
}

/** Tracks the primary button: down in the editor, up anywhere (the release may be outside it). */
export const pointerSelectPlugin = $prose(
  () =>
    new Plugin<boolean>({
      key: pointerKey,
      state: {
        init: () => false,
        apply: (tr, previous) => {
          const meta = tr.getMeta(pointerKey) as boolean | undefined;
          return meta ?? previous;
        },
      },
      view(view) {
        const window = view.dom.ownerDocument.defaultView;
        const release = () => set(view, false);
        window?.addEventListener("mouseup", release, true);
        window?.addEventListener("blur", release);
        return {
          destroy() {
            window?.removeEventListener("mouseup", release, true);
            window?.removeEventListener("blur", release);
          },
        };
      },
      props: {
        handleDOMEvents: {
          mousedown(view, event) {
            if (event.button === 0) set(view, true);
            return false;
          },
          // A release the window never saw (outside a frame, a lost grab): the next move ends it.
          mousemove(view, event) {
            if (event.buttons === 0) set(view, false);
            return false;
          },
        },
      },
    }),
);
