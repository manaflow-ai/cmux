import { useCallback, useRef, useSyncExternalStore } from "react";
import type { EditorLabelResolver } from "./editorLabels";
import type { EditorSaveController, EditorSaveState } from "./saveController";

const CLEAN_STATE: EditorSaveState = { dirty: false, status: "idle", conflict: null };
const subscribeNoop = () => () => {};
const getCleanState = () => CLEAN_STATE;

export type EditorSaveOverlayProps = {
  labels: EditorLabelResolver;
  controller: EditorSaveController | null;
};

/**
 * Transient floating card over the editor, rendered ONLY when a save needs
 * attention: the on-disk conflict prompt (Overwrite / Use disk version /
 * Dismiss) or a save error. The editor has no persistent chrome; routine
 * state (dirty, saved) is carried by the page title's dot, which cmux shows
 * in the surface tab.
 *
 * The conflict prompt is a modal-ish `alertdialog`: Monaco captures Tab for
 * editing, so without moving focus a keyboard user could never reach the
 * actions. The dialog grabs focus when it appears (callback ref, no effect)
 * and restores it to whatever was focused before on close, and Escape maps to
 * Dismiss.
 */
export function EditorSaveOverlay({ labels, controller }: EditorSaveOverlayProps) {
  const state = useSyncExternalStore(
    controller?.subscribe ?? subscribeNoop,
    controller?.getState ?? getCleanState,
  );

  // Focus the dialog's first action when it mounts and restore the prior
  // focus (the Monaco textarea) when it unmounts. A callback ref fires with
  // the node on mount and `null` on unmount, so no `useEffect` is needed.
  const restoreFocusTo = useRef<HTMLElement | null>(null);
  const focusManagedRef = useCallback((node: HTMLButtonElement | null) => {
    if (node) {
      restoreFocusTo.current = node.ownerDocument.activeElement as HTMLElement | null;
      node.focus();
    } else {
      const target = restoreFocusTo.current;
      restoreFocusTo.current = null;
      // Only restore if focus is still inside a now-detached dialog; if the
      // user already moved on, leave their focus alone.
      target?.focus?.();
    }
  }, []);

  if (!controller) {
    return null;
  }

  if (state.conflict) {
    const message = state.conflict.fileMissing ? labels("conflictMissing") : labels("conflictChanged");
    const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
      if (event.key === "Escape") {
        event.preventDefault();
        controller.dismissConflict();
      }
    };
    return (
      // An alertdialog is an interactive container that owns Escape-to-dismiss;
      // the a11y heuristic that flags handlers on "non-interactive" elements
      // does not model dialog role, so suppress it here.
      // eslint-disable-next-line jsx-a11y/no-noninteractive-element-interactions
      <div className="cmux-editor-overlay" role="alertdialog" aria-label={message} onKeyDown={onKeyDown}>
        <span className="cmux-editor-overlay-message">{message}</span>
        <button
          ref={focusManagedRef}
          type="button"
          className="cmux-editor-overlay-button"
          onClick={() => controller.resolveConflictOverwrite()}
        >
          {labels("overwrite")}
        </button>
        {state.conflict.diskContent !== undefined ? (
          <button
            type="button"
            className="cmux-editor-overlay-button"
            onClick={() => controller.resolveConflictUseDisk()}
          >
            {labels("useDiskVersion")}
          </button>
        ) : null}
        <button
          type="button"
          className="cmux-editor-overlay-button"
          onClick={() => controller.dismissConflict()}
        >
          {labels("dismiss")}
        </button>
      </div>
    );
  }
  if (state.status === "error") {
    const base = errorLabel(state.errorCode, labels);
    const message = state.errorDetail ? `${base} ${state.errorDetail}` : base;
    return (
      <div className="cmux-editor-overlay" role="alert">
        <span className="cmux-editor-overlay-message">{message}</span>
      </div>
    );
  }
  return null;
}

function errorLabel(code: string | undefined, labels: EditorLabelResolver): string {
  switch (code) {
    case "permission_denied":
      return labels("savePermissionDenied");
    case "unavailable":
      return labels("saveUnavailable");
    default:
      return labels("saveFailed");
  }
}
