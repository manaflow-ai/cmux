import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// Side-effect: registers the common languages (Monarch grammars + JSON service).
import "./monacoLanguages";
import { useCallback, type CSSProperties } from "react";
import type { EditorLabelResolver } from "./editorLabels";
import { EditorSaveOverlay } from "./EditorSaveOverlay";
import type { EditorSaveController } from "./saveController";

/** Fire-and-forget dirty-state mirror to the native panel (token-authorized
 * on the Swift side; failures are benign for pages without a registration). */
function notifyNativeDirty(dirty: boolean): void {
  const handler = (
    window as unknown as {
      webkit?: { messageHandlers?: { cmuxEditorSave?: { postMessage: (m: unknown) => Promise<unknown> } } };
    }
  ).webkit?.messageHandlers?.cmuxEditorSave;
  handler?.postMessage({ dirty }).catch(() => {});
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
        const baseTitle = document.title.replace(/^● /, "");
        let lastNotifiedDirty: boolean | null = null;
        const syncTitle = () => {
          const dirty = saveController.getState().dirty;
          const next = dirty ? `● ${baseTitle}` : baseTitle;
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
        // No in-page shortcut: the native side routes cmux's configurable
        // save shortcut (saveFilePreview) here through this entrypoint.
        (window as unknown as { __cmuxEditorRequestSave?: () => void }).__cmuxEditorRequestSave =
          () => saveController.requestSave();
        removeSaveShortcut = () => {
          delete (window as unknown as { __cmuxEditorRequestSave?: () => void }).__cmuxEditorRequestSave;
        };
      }
      return () => {
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
    [content, filePath, themeName, options, saveController],
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
