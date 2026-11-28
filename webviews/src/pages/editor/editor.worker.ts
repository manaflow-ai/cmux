// Monaco's editor worker (word-based suggestions, links, diff computation off the main thread).
// An entry of the webviews-app build, emitted as `chunks/editor-worker.mjs` next to the editor's
// Monaco chunk (view.ts spawns it as a module worker, same origin, under the strict PageCSP).
import "monaco-editor/editor/editor.worker.js";
