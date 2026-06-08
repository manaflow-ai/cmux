import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// Side-effect: registers the common languages (Monarch grammars + JSON service).
import "./monacoLanguages";
import { useCallback } from "react";

/** Props for a single read/edit Monaco surface, fixed for the lifetime of the mount. */
export type EditorAppProps = {
  filePath: string;
  content: string;
  themeName: string;
  options: monaco.editor.IStandaloneEditorConstructionOptions;
};

/**
 * Renders a Monaco editor. The editor is created in a callback ref (no
 * `useEffect`): the ref fires with the node on mount and with `null` on
 * unmount, where we dispose the editor and its model. Props are set once by
 * the surface bootstrap, so the callback identity is stable for the mount.
 */
export function EditorApp({ filePath, content, themeName, options }: EditorAppProps) {
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
      return () => {
        resizeObserver.disconnect();
        editor.dispose();
        model.dispose();
      };
    },
    [content, filePath, themeName, options],
  );
  return <div ref={mountEditor} className="cmux-monaco-root" />;
}
