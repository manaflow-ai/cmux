import * as monaco from "monaco-editor/esm/vs/editor/editor.api.js";
// Monarch grammars for every common language (Go, Rust, Python, Java, C/C++,
// C#, PHP, Ruby, Swift, Kotlin, SQL, YAML, XML, HTML, CSS/SCSS/LESS, shell,
// Dockerfile, Markdown, TypeScript/JavaScript, and ~50 more) — main thread, no
// workers.
import "monaco-editor/esm/vs/basic-languages/_.contribution.js";
// JSON has no Monarch grammar; its language service provides `.json`
// highlighting (its worker is wired in `monacoEnvironment`).
import "monaco-editor/esm/vs/language/json/monaco.contribution.js";
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
