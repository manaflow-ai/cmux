// oxlint-disable import/default -- Vite `?worker` is a virtual module whose
// default export is the worker constructor; oxlint resolves the bare worker
// file (no default export) and false-positives.
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker.js?worker";
import JsonWorker from "monaco-editor/esm/vs/language/json/json.worker.js?worker";

// Every common language highlights on the main thread via its registered
// Monarch grammar (basic-languages). JSON is the one common language with no
// Monarch grammar, so we add its language service, which needs a worker. We
// deliberately do not pull in the CSS/HTML/TypeScript services: their Monarch
// grammars already highlight, and their workers (especially the ~7MB
// TypeScript worker) add IntelliSense we don't need and bloat the bundle.
// Workers are same-origin and served over the diff viewer scheme/HTTP (allowed
// by `script-src 'self'`); WebKit blocks module workers only from `file://`,
// which the editor surface does not use.
const monacoEnvironment: { getWorker: (workerId: string, label: string) => Worker } = {
  getWorker(_workerId, label) {
    if (label === "json") {
      return new JsonWorker();
    }
    return new EditorWorker();
  },
};

(globalThis as unknown as { MonacoEnvironment: typeof monacoEnvironment }).MonacoEnvironment =
  monacoEnvironment;
