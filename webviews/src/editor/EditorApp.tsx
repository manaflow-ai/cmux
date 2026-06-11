import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// Side-effect: registers the common languages (Monarch grammars + JSON service).
import "./monacoLanguages";
import { useCallback, type CSSProperties } from "react";
import type { EditorLabelResolver } from "./editorLabels";
import { EditorSaveOverlay } from "./EditorSaveOverlay";
import type { EditorSaveController } from "./saveController";

/** Fire-and-forget dirty-state mirror to the native panel (token-authorized
 * on the Swift side; failures are benign for pages without a registration).
 * When the host opted into content mirroring (the markdown panel), the
 * message also carries the live buffer so the native model stays in sync. */
function notifyNativeDirty(dirty: boolean, content?: string): void {
  const handler = (
    window as unknown as {
      webkit?: { messageHandlers?: { cmuxEditorSave?: { postMessage: (m: unknown) => Promise<unknown> } } };
    }
  ).webkit?.messageHandlers?.cmuxEditorSave;
  handler?.postMessage(content === undefined ? { dirty } : { dirty, content }).catch(() => {});
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
  /** When true (the markdown panel host), dirty messages carry the live
   * buffer and content changes are mirrored (debounced) to the native side. */
  mirrorContent: boolean;
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
  mirrorContent,
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
      // Autofocus so the user can type immediately on open without a click.
      // Focusing Monaco inside a non-key webview does not steal OS focus, so
      // when the tab becomes key the editor already holds the caret. Deferred
      // one frame so focus lands after the initial layout/paint.
      requestAnimationFrame(() => editor.focus());

      // Host hooks that are independent of the save bridge: the native side
      // pulls the live buffer (markdown preview toggle), jumps to a global
      // search needle, and toggles soft wrap live. Installed for read-only
      // pages too so hosts behave uniformly.
      const win = window as unknown as Record<string, unknown>;
      win.__cmuxEditorGetContent = () => model.getValue();
      win.__cmuxEditorRevealNeedle = (needle: unknown) => {
        if (typeof needle !== "string") {
          return false;
        }
        const trimmed = needle.trim();
        if (trimmed === "") {
          return false;
        }
        const match = model.findMatches(trimmed, false, false, false, null, false, 1)[0];
        if (!match) {
          return false;
        }
        editor.setSelection(match.range);
        editor.revealRangeInCenter(match.range, monaco.editor.ScrollType.Immediate);
        return true;
      };
      win.__cmuxEditorSetWordWrap = (wrap: unknown) => {
        editor.updateOptions({ wordWrap: wrap === true ? "on" : "off" });
      };
      // Making the WKWebView first responder does not give Monaco a caret;
      // the host invokes this after taking first responder so typing lands
      // in the buffer immediately (parity with makeFirstResponder(textView)).
      win.__cmuxEditorFocus = () => editor.focus();
      // Native hosts push the on-disk state here when the file changes under
      // a clean buffer (file watcher) or the user reverts to the disk
      // version. The save controller decides whether to replace the buffer,
      // just re-baseline the conflict sha (identical text, different bytes),
      // or no-op (this host's own save echo). Installed for read-only pages
      // too so their buffer keeps following the file watcher.
      win.__cmuxEditorAdoptDiskContent = (nextContent: unknown, sha256: unknown) => {
        if (typeof nextContent !== "string") {
          return;
        }
        if (saveController) {
          saveController.adoptDiskContent(nextContent, typeof sha256 === "string" ? sha256 : null);
        } else if (model.getValue() !== nextContent) {
          model.setValue(nextContent);
        }
      };
      const removeHostHooks = () => {
        delete win.__cmuxEditorGetContent;
        delete win.__cmuxEditorRevealNeedle;
        delete win.__cmuxEditorSetWordWrap;
        delete win.__cmuxEditorFocus;
        delete win.__cmuxEditorAdoptDiskContent;
      };

      let contentListener: monaco.IDisposable | null = null;
      let removeSaveShortcut: (() => void) | null = null;
      let removeTitleSync: (() => void) | null = null;
      let mirrorTimer: ReturnType<typeof setTimeout> | null = null;
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
            notifyNativeDirty(dirty, mirrorContent ? model.getValue() : undefined);
          }
        };
        // Attach the document BEFORE the first sync: the controller's dirty
        // state (including a host-seeded `initiallyDirty`) is only valid once
        // a document is attached, and an early clean mirror would re-baseline
        // the native panel against unsaved content.
        saveController.attachDocument({
          getValue: () => model.getValue(),
          getVersionId: () => model.getAlternativeVersionId(),
          replaceWith: (next) => {
            model.setValue(next);
            return model.getAlternativeVersionId();
          },
        });
        removeTitleSync = saveController.subscribe(syncTitle);
        syncTitle();
        contentListener = model.onDidChangeContent(() => {
          saveController.noteContentChanged();
          if (mirrorContent) {
            // Debounced live-buffer mirror so the native model (preview
            // rendering, global search indexing) tracks unsaved edits the way
            // the previous NSTextView editor did on every keystroke.
            if (mirrorTimer !== null) {
              clearTimeout(mirrorTimer);
            }
            mirrorTimer = setTimeout(() => {
              mirrorTimer = null;
              notifyNativeDirty(saveController.getState().dirty, model.getValue());
            }, 150);
          }
        });
        // No in-page shortcuts: the native side routes cmux's save shortcut
        // and the standard undo/redo chords here, so the app's Edit menu can
        // never shadow Monaco's own model undo (WKWebView's native undo: does
        // nothing useful for a Monaco buffer).
        win.__cmuxEditorRequestSave = () => saveController.requestSave();
        win.__cmuxEditorUndo = () => editor.trigger("cmuxMenu", "undo", null);
        win.__cmuxEditorRedo = () => editor.trigger("cmuxMenu", "redo", null);
        removeSaveShortcut = () => {
          delete win.__cmuxEditorRequestSave;
          delete win.__cmuxEditorUndo;
          delete win.__cmuxEditorRedo;
        };
      }
      // Replay native host calls that arrived before the hooks were installed
      // (the Swift side parks them; page boot spans module imports + Monaco
      // setup, well past WebKit's didFinish).
      const pendingCalls = win.__cmuxEditorPendingCalls as [string, unknown[]][] | undefined;
      delete win.__cmuxEditorPendingCalls;
      if (Array.isArray(pendingCalls)) {
        for (const pendingCall of pendingCalls) {
          const [name, args] = pendingCall;
          const fn = win[name];
          if (typeof fn === "function" && Array.isArray(args)) {
            (fn as (...callArgs: unknown[]) => void)(...args);
          }
        }
      }

      return () => {
        if (mirrorTimer !== null) {
          clearTimeout(mirrorTimer);
        }
        removeTitleSync?.();
        removeSaveShortcut?.();
        removeHostHooks();
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
    [content, filePath, themeName, options, saveController, mirrorContent],
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
