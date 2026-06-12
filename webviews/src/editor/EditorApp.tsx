import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// Side-effect: registers the common languages (Monarch grammars + JSON service).
import "./monacoLanguages";
import { useCallback, type CSSProperties } from "react";
import type { EditorLabelResolver } from "./editorLabels";
import { EditorSaveOverlay } from "./EditorSaveOverlay";
import type { EditorSaveController } from "./saveController";

/** The native editor-save message handler, present on every editor webview
 * (token-authorized on the Swift side; absent in plain browsers). */
function editorSaveHandler():
  | { postMessage: (m: unknown) => Promise<unknown> }
  | undefined {
  return (
    window as unknown as {
      webkit?: { messageHandlers?: { cmuxEditorSave?: { postMessage: (m: unknown) => Promise<unknown> } } };
    }
  ).webkit?.messageHandlers?.cmuxEditorSave;
}

/** Fire-and-forget dirty-state mirror to the native panel (failures are benign
 * for pages without a registration). */
function notifyNativeDirty(dirty: boolean): void {
  editorSaveHandler()?.postMessage({ dirty }).catch(() => {});
}

/** Persist the editor's view state (scroll/cursor/selection/folding) to the
 * native per-token sidecar. Authorized by the page's scheme token, so it works
 * for read-only files too. Fire-and-forget. */
function persistViewState(viewState: monaco.editor.ICodeEditorViewState | null): void {
  if (!viewState) {
    return;
  }
  editorSaveHandler()?.postMessage({ viewState }).catch(() => {});
}

/** Props for a single read/edit Monaco surface, fixed for the lifetime of the mount. */
export type EditorAppProps = {
  filePath: string;
  content: string;
  themeName: string;
  options: monaco.editor.IStandaloneEditorConstructionOptions;
  labels: EditorLabelResolver;
  /** Non-null when the file is writable and the native save bridge is wired. */
  saveController: EditorSaveController | null;
  /** Status bar chrome colors derived from the active cmux theme. */
  chrome: { background?: string; foreground?: string };
  /** Monaco view state (scroll/cursor/selection/folding) restored from the
   * native sidecar after a webview unload; null on a fresh open. */
  restoredViewState?: monaco.editor.ICodeEditorViewState | null;
};

/**
 * Renders a Monaco editor. The editor is created in a callback ref (no
 * `useEffect`): the ref fires with the node on mount and with `null` on
 * unmount, where we dispose the editor and its model. Props are set once by
 * the surface bootstrap, so the callback identity is stable for the mount.
 */
export function EditorApp({
  filePath,
  content,
  themeName,
  options,
  labels,
  saveController,
  chrome,
  restoredViewState,
}: EditorAppProps) {
  const mountEditor = useCallback(
    (node: HTMLDivElement | null) => {
      if (!node) {
        return;
      }
      const model = monaco.editor.createModel(
        content,
        undefined,
        monaco.Uri.file(filePath || "untitled.txt"),
      );
      const editor = monaco.editor.create(node, {
        model,
        theme: themeName,
        ...options,
      });
      // Drive layout from a ResizeObserver instead of Monaco's
      // `automaticLayout`. The cmux WKWebView pane can report 0 height when the
      // editor is created (before the pane lays out), and Monaco's internal
      // observer occasionally misses that first sizing, leaving the editor
      // rendering zero lines. Observing the node ourselves fires immediately and
      // on every resize, so the editor lays out as soon as the pane has a size.
      const resizeObserver = new ResizeObserver(() => editor.layout());
      resizeObserver.observe(node);
      // Force synchronous tokenization, then re-render. Monaco tokenizes lazily
      // via a throttled async scheduler (timers/idle callbacks); cmux's
      // offscreen-IOSurface WKWebView starves that scheduler, so files render
      // plain non-deterministically even though the grammar is registered.
      // Forcing tokenization up front makes highlighting deterministic.
      const tokenization = (
        model as unknown as { tokenization?: { forceTokenization?: (line: number) => void } }
      ).tokenization;
      tokenization?.forceTokenization?.(Math.min(model.getLineCount(), 2000));
      editor.render(true);
      node.dataset.cmuxEditorReady = "true";
      // Restore scroll/cursor/selection/folding from before the last webview
      // unload, before first paint so there is no visible jump.
      if (restoredViewState) {
        editor.restoreViewState(restoredViewState);
      }
      // Persist view state whenever the page is being torn down (tab switch,
      // navigation, app quit). `pagehide` is the reliable teardown signal in
      // WKWebView; `visibilitychange`->hidden covers backgrounding before an
      // unannounced unload. Both capture the live state to the native sidecar.
      const captureViewState = () => persistViewState(editor.saveViewState());
      const onVisibility = () => {
        if (document.visibilityState === "hidden") {
          captureViewState();
        }
      };
      window.addEventListener("pagehide", captureViewState);
      document.addEventListener("visibilitychange", onVisibility);
      // Autofocus so the user can type immediately on open without a click.
      // Focusing Monaco inside a non-key webview does not steal OS focus, so
      // when the tab becomes key the editor already holds the caret. Deferred
      // one frame so focus lands after the initial layout/paint.
      requestAnimationFrame(() => editor.focus());

      let contentListener: monaco.IDisposable | null = null;
      let removeSaveShortcut: (() => void) | null = null;
      let removeTitleSync: (() => void) | null = null;
      if (saveController) {
        saveController.onSaveUnavailable = () => {
          editor.updateOptions({ readOnly: true });
        };
        // The editor has no persistent chrome; dirty state rides the page
        // title's leading dot (shown in the tab) and is mirrored to the
        // native panel so closing the tab confirms unsaved changes.
        const baseTitle = document.title.replace(/^[●•] /, "");
        let lastNotifiedDirty: boolean | null = null;
        const syncTitle = () => {
          const dirty = saveController.getState().dirty;
          const next = dirty ? `• ${baseTitle}` : baseTitle;
          if (document.title !== next) {
            document.title = next;
          }
          if (lastNotifiedDirty !== dirty) {
            lastNotifiedDirty = dirty;
            notifyNativeDirty(dirty);
          }
        };
        removeTitleSync = saveController.subscribe(syncTitle);
        syncTitle();
        saveController.attachDocument({
          getValue: () => model.getValue(),
          getVersionId: () => model.getAlternativeVersionId(),
          replaceWith: (next) => {
            model.setValue(next);
            return model.getAlternativeVersionId();
          },
        });
        contentListener = model.onDidChangeContent(() => {
          saveController.noteContentChanged();
        });
        // No in-page shortcuts: the native side routes cmux's save shortcut
        // and the standard undo/redo chords here, so the app's Edit menu can
        // never shadow Monaco's own model undo (WKWebView's native undo: does
        // nothing useful for a Monaco buffer).
        const win = window as unknown as Record<string, unknown>;
        win.__cmuxEditorRequestSave = () => saveController.requestSave();
        win.__cmuxEditorUndo = () => editor.trigger("cmuxMenu", "undo", null);
        win.__cmuxEditorRedo = () => editor.trigger("cmuxMenu", "redo", null);
        removeSaveShortcut = () => {
          delete win.__cmuxEditorRequestSave;
          delete win.__cmuxEditorUndo;
          delete win.__cmuxEditorRedo;
        };
      }
      return () => {
        // Capture once more on React unmount (covers in-app surface teardown
        // that does not fire pagehide), then detach listeners.
        captureViewState();
        window.removeEventListener("pagehide", captureViewState);
        document.removeEventListener("visibilitychange", onVisibility);
        removeTitleSync?.();
        removeSaveShortcut?.();
        contentListener?.dispose();
        if (saveController) {
          saveController.onSaveUnavailable = null;
        }
        saveController?.detachDocument();
        resizeObserver.disconnect();
        editor.dispose();
        model.dispose();
      };
    },
    [content, filePath, themeName, options, saveController, restoredViewState],
  );
  return (
    <div
      className="cmux-editor-shell"
      style={{
        "--cmux-editor-chrome-bg": chrome.background ?? "transparent",
        "--cmux-editor-chrome-fg": chrome.foreground ?? "inherit",
      } as CSSProperties}
    >
      <div ref={mountEditor} className="cmux-monaco-root" />
      <EditorSaveOverlay labels={labels} controller={saveController} />
    </div>
  );
}
