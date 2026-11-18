// A Vite plugin for browser tests whose page draws highlighted code cards. The app's page starts
// Pierre's worker from its bundled `highlight-worker.js`; a dev server serves none, so there a
// transcript code card stays plain (#25876) and never becomes the highlighted card a test measures.
// The plugin swaps conversation/highlightPool.ts for devHighlightPool.ts, whose pool runs Pierre's
// own worker as a Vite module worker, off the main thread as in the app.
import path from "node:path";
import type { Plugin } from "vite";

const webviews = path.resolve(import.meta.dir, "../..");
const REAL_POOL = path.join(webviews, "src/agent-session/acpmux/conversation/highlightPool.ts");
const DEV_POOL = path.join(webviews, "test/support/devHighlightPool.ts");
const BUILT_POOL = path.join(webviews, "test/support/builtHighlightPool.ts");

/// The plugin; pass it in the test's `createServer({ plugins: [devHighlightWorker()] })`.
export function devHighlightWorker(): Plugin {
  return swapPool("dev-highlight-worker", DEV_POOL);
}

/// For a production build of a test page served over http: builtHighlightPool.ts, whose pool starts
/// the shipped `highlight-worker.js` (scripts/agent-pane/bundle.mjs) beside the page, as the app's.
export function builtHighlightWorker(): Plugin {
  return swapPool("built-highlight-worker", BUILT_POOL);
}

function swapPool(name: string, pool: string): Plugin {
  return {
    name,
    enforce: "pre",
    async resolveId(source, importer, options) {
      if (!importer || importer === pool || !source.endsWith("/highlightPool")) return null;
      const resolved = await this.resolve(source, importer, { ...options, skipSelf: true });
      return resolved?.id === REAL_POOL ? pool : null;
    },
  };
}
