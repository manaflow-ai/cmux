// Vite `?worker` is a virtual module whose default export is the worker
// constructor; oxlint resolves the bare worker file (no default export) and
// false-positives, so suppress that one rule on the import line.
// oxlint-disable-next-line import/default
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker.js?worker";

// Monaco needs one base worker for its editor services. We ship only this
// worker for v1 (no ts/json/css/html language-service workers, so no
// IntelliSense yet); syntax highlighting runs on the main thread via Monarch.
// The editor surface is served through the diff viewer custom scheme rather
// than file://, because WebKit blocks module workers from file:// origins.
// Importing this module for its side effect installs `MonacoEnvironment`
// before any editor is created.
const monacoEnvironment: { getWorker: () => Worker } = {
  getWorker() {
    return new EditorWorker();
  },
};

(globalThis as unknown as { MonacoEnvironment: typeof monacoEnvironment }).MonacoEnvironment =
  monacoEnvironment;
