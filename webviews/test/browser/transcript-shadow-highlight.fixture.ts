// The browser integration fixture runs on HTTP, where the pane deliberately keeps code plain.
// Supply Pierre's real portable worker only to this test server; product scheme policy is unchanged.
import { WorkerPoolManager } from "@pierre/diffs/worker";
import workerURL from "@pierre/diffs/worker/worker-portable.js?url";
import {
  AGENT_DIFF_THEME,
  AGENT_DIFF_THEME_LIGHT,
  registerAgentDiffTheme,
} from "../../src/agent-session/acpmux/diffTheme";

type Mode = "none" | "word-alt";
const pools = new Map<Mode, WorkerPoolManager>();

export function paneHighlightPool(mode: Mode = "word-alt"): WorkerPoolManager {
  let pool = pools.get(mode);
  if (!pool) {
    registerAgentDiffTheme();
    pool = new WorkerPoolManager(
      {
        workerFactory: () => {
          const worker = new Worker(workerURL, { type: "module" });
          worker.addEventListener("error", (event) => {
            document.documentElement.dataset.shadowHighlightWorker = `error: ${event.message}`;
          });
          return worker;
        },
        poolSize: 1,
      },
      {
        langs: ["typescript"],
        lineDiffType: mode,
        preferredHighlighter: "shiki-js",
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
      },
    );
    pools.set(mode, pool);
  }
  return pool;
}

export function prepareShadowHighlight(): void {
  document.documentElement.dataset.shadowHighlightWorker = "starting";
  void Promise.all([paneHighlightPool("word-alt").initialize(), paneHighlightPool("none").initialize()]).then(
    () => {
      document.documentElement.dataset.shadowHighlightWorker = "ready";
    },
    (error: unknown) => {
      document.documentElement.dataset.shadowHighlightWorker = `error: ${String(error)}`;
    },
  );
}

// The fixture waits for real painted lines and uses the test deadline for worker errors.
export const onHighlightTimeout = (_name: string, _onTimeout: () => void) => () => {};

export function clearShadowHighlight(): void {
  for (const pool of pools.values()) pool.terminate();
  pools.clear();
  delete document.documentElement.dataset.shadowHighlightWorker;
}
