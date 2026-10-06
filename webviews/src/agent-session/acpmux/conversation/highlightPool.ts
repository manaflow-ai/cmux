// The pane's code highlighting runs off the main thread: Pierre's worker pool, its workers
// started from `highlight-worker.js` beside the bundled page (Pierre's worker with the pane's
// trimmed shiki, built by scripts/cmux-next/build-agent-pane-web.sh). A worker takes its policy from its own response,
// so both hosts serve it with one that allows no network (AgentPaneSchemeHandler, PageCSP).
// The dev server serves no built worker: there, and if the workers fail to start, Pierre
// highlights on the main thread, still under the limits in highlightLimits.ts.
import { WorkerPoolManager } from "@pierre/diffs/worker";
import { AGENT_DIFF_THEME, AGENT_DIFF_THEME_LIGHT, registerAgentDiffTheme } from "../diffTheme";
import { MAX_TOKENIZED_LINE } from "./highlightLimits";

/// The worker's file, beside the page.
export const HIGHLIGHT_WORKER_FILE = "highlight-worker.js";
/// Two workers: a fence stuck in one grammar leaves the other for the rest of the reply.
const POOL_SIZE = 2;

/// Whether a page at `protocol` is the bundled page, which ships the worker.
export function usesHighlightWorker(protocol: string): boolean {
  return protocol === "cmux-agent:" || protocol === "cmux-page:";
}

/// Starts one module worker from the page's own origin (`base` is the page's URL).
export function highlightWorkerFactory(base: string, WorkerConstructor: typeof Worker = Worker): () => Worker {
  return () => new WorkerConstructor(new URL(HIGHLIGHT_WORKER_FILE, base), { type: "module" });
}

let pool: WorkerPoolManager | null | undefined;

/// The pane's pool, made on first use; undefined where the page has no worker.
export function paneHighlightPool(): WorkerPoolManager | undefined {
  if (pool === undefined) {
    const page = typeof location === "undefined" ? undefined : location;
    if (!page || typeof Worker === "undefined" || !usesHighlightWorker(page.protocol)) pool = null;
    else {
      registerAgentDiffTheme();
      pool = new WorkerPoolManager(
        { workerFactory: highlightWorkerFactory(page.href), poolSize: POOL_SIZE },
        { theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT }, tokenizeMaxLineLength: MAX_TOKENIZED_LINE },
      );
    }
  }
  return pool ?? undefined;
}
