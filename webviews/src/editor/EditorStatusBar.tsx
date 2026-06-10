import { useSyncExternalStore } from "react";
import type { EditorLabelResolver } from "./editorLabels";
import type { EditorSaveController, EditorSaveState } from "./saveController";

const CLEAN_STATE: EditorSaveState = { dirty: false, status: "idle", conflict: null };
const subscribeNoop = () => () => {};
const getCleanState = () => CLEAN_STATE;

export type EditorStatusBarProps = {
  fileName: string;
  labels: EditorLabelResolver;
  readOnly: boolean;
  controller: EditorSaveController | null;
};

/**
 * Slim status bar under the Monaco editor: file name, dirty indicator, save
 * progress/error text, the read-only badge, and the conflict prompt when a
 * save is refused because the file changed on disk underneath the buffer.
 */
export function EditorStatusBar({ fileName, labels, readOnly, controller }: EditorStatusBarProps) {
  const state = useSyncExternalStore(
    controller?.subscribe ?? subscribeNoop,
    controller?.getState ?? getCleanState,
  );
  return (
    <div className="cmux-editor-statusbar">
      <span className="cmux-editor-statusbar-file" title={fileName}>
        {state.dirty ? (
          <span className="cmux-editor-dirty-dot" title={labels("modified")} aria-label={labels("modified")}>
            ●
          </span>
        ) : null}
        {fileName}
      </span>
      <span className="cmux-editor-statusbar-status">{statusText(state, readOnly, labels)}</span>
      {state.conflict && controller ? (
        <span className="cmux-editor-conflict" role="alertdialog" aria-label={conflictText(state, labels)}>
          <span className="cmux-editor-conflict-message">{conflictText(state, labels)}</span>
          <button
            type="button"
            className="cmux-editor-conflict-button"
            onClick={() => controller.resolveConflictOverwrite()}
          >
            {labels("overwrite")}
          </button>
          {state.conflict.diskContent !== undefined ? (
            <button
              type="button"
              className="cmux-editor-conflict-button"
              onClick={() => controller.resolveConflictUseDisk()}
            >
              {labels("useDiskVersion")}
            </button>
          ) : null}
          <button
            type="button"
            className="cmux-editor-conflict-button"
            onClick={() => controller.dismissConflict()}
          >
            {labels("dismiss")}
          </button>
        </span>
      ) : null}
    </div>
  );
}

function conflictText(state: EditorSaveState, labels: EditorLabelResolver): string {
  return state.conflict?.fileMissing ? labels("conflictMissing") : labels("conflictChanged");
}

function statusText(state: EditorSaveState, readOnly: boolean, labels: EditorLabelResolver): string {
  if (readOnly) {
    return labels("readOnly");
  }
  if (state.conflict) {
    return "";
  }
  if (state.status === "saving") {
    return labels("saving");
  }
  if (state.status === "error") {
    const base = errorLabel(state.errorCode, labels);
    return state.errorDetail ? `${base} ${state.errorDetail}` : base;
  }
  if (state.dirty) {
    return labels("modified");
  }
  if (state.status === "saved") {
    return labels("saved");
  }
  return "";
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
