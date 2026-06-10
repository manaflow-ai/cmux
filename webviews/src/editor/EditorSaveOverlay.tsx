import { useSyncExternalStore } from "react";
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
 */
export function EditorSaveOverlay({ labels, controller }: EditorSaveOverlayProps) {
  const state = useSyncExternalStore(
    controller?.subscribe ?? subscribeNoop,
    controller?.getState ?? getCleanState,
  );
  if (!controller) {
    return null;
  }
  if (state.conflict) {
    const message = state.conflict.fileMissing ? labels("conflictMissing") : labels("conflictChanged");
    return (
      <div className="cmux-editor-overlay" role="alertdialog" aria-label={message}>
        <span className="cmux-editor-overlay-message">{message}</span>
        <button
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
