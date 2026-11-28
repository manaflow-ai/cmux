import { useEffect } from "react";
import type { DiffFindController } from "./useDiffFind";

export type FindKeyboardBridge = {
  open: boolean;
  controller: DiffFindController;
};

/**
 * Document-level find keys. Inside cmux the native app intercepts the
 * configured Find shortcut and forwards it through the viewer-navigation
 * bridge, so this listener mostly serves Cmd+G/Shift+Cmd+G (which cmux
 * routes into web content first) and any non-embedded (plain browser)
 * serving of the diff viewer. Cmd+Shift+F is left alone: that is cmux's
 * find-in-directory shortcut.
 */
export function useFindKeyboard(
  dispatch: React.Dispatch<{ type: "request-find" }>,
  bridgeRef: React.MutableRefObject<FindKeyboardBridge>,
): void {
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const meta = event.metaKey || event.ctrlKey;
      const key = event.key.toLowerCase();
      if (meta && !event.shiftKey && !event.altKey && key === "f") {
        event.preventDefault();
        dispatch({ type: "request-find" });
        return;
      }
      const bridge = bridgeRef.current;
      if (!bridge.open) {
        return;
      }
      if (meta && !event.altKey && key === "g") {
        event.preventDefault();
        if (event.shiftKey) {
          bridge.controller.goToPrevious();
        } else {
          bridge.controller.goToNext();
        }
        return;
      }
      if (event.key === "Escape") {
        // Only close when the key belongs to the viewer or the find bar;
        // other overlays (file search, options menu) own their own Escape.
        const target = event.target;
        if (target instanceof Element && target.closest("#viewer, #diff-find-bar") != null) {
          bridge.controller.closeFind();
        }
      }
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [dispatch, bridgeRef]);
}
