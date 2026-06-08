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
        automaticLayout: true,
        ...options,
      });
      node.dataset.cmuxEditorReady = "true";
      return () => {
        editor.dispose();
        model.dispose();
      };
    },
    [content, filePath, themeName, options],
  );
  return <div ref={mountEditor} className="cmux-monaco-root" />;
}
