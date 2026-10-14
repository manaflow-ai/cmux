// Second Rollup entry of the webviews bundle: the `@pierre/diffs` highlight
// worker. Building it in the same Rollup graph as `main.mjs` (instead of a
// separate Vite worker build or a vendored prebuilt copy) lets it share the
// `shiki-core` chunk and the lazy `shiki-wasm` chunk with the main thread.
import "@pierre/diffs/worker/worker.js";
