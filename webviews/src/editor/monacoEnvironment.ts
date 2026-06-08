// oxlint-disable import/default -- Vite `?worker` is a virtual module whose
// default export is the worker constructor; oxlint resolves the bare worker
// file (no default export) and false-positives.
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker.js?worker";

// Monaco needs one base editor worker. All languages (including JSON) highlight
// on the main thread via their registered Monarch grammars, so no language-
// service workers are wired. The base worker is same-origin and served over the
// diff viewer scheme/HTTP (allowed by `script-src 'self'`).
const monacoEnvironment: { getWorker: () => Worker } = {
  getWorker() {
    return new EditorWorker();
  },
};

(globalThis as unknown as { MonacoEnvironment: typeof monacoEnvironment }).MonacoEnvironment =
  monacoEnvironment;
