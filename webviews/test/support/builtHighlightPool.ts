// The pane's highlight pool in a production build of a test page (devHighlightWorker.ts
// `builtHighlightWorker` swaps it in for conversation/highlightPool.ts). The app starts its
// workers only on its own schemes (`usesHighlightWorker`); a test page is served over http, so this
// pool skips that check and the job watchdog and otherwise starts the same workers: the shipped
// `highlight-worker.js` beside the page (`highlightWorkerFactory`), built by the test with
// scripts/agent-pane/bundle.mjs as build-agent-pane-web.sh builds it. Everything else is the real module.
import { WorkerPoolManager } from "@pierre/diffs/worker";
import type { SupportedLanguages } from "@pierre/diffs";
import {
  AGENT_DIFF_THEME,
  AGENT_DIFF_THEME_LIGHT,
  registerAgentDiffTheme,
} from "../../src/agent-session/acpmux/diffTheme";
import { MAX_TOKENIZED_LINE } from "../../src/agent-session/acpmux/conversation/highlightLimits";
import {
  highlightWorkerFactory,
  type HighlightLineDiffType,
} from "../../src/agent-session/acpmux/conversation/highlightPool";

export * from "../../src/agent-session/acpmux/conversation/highlightPool";

const pools = new Map<HighlightLineDiffType, WorkerPoolManager>();

/// One worker pool per line-diff mode, as the app's (highlightPool.ts `paneHighlightPool`).
export function paneHighlightPool(
  lineDiffType: HighlightLineDiffType = "word-alt",
  language: string = "text",
): WorkerPoolManager | undefined {
  let pool = pools.get(lineDiffType);
  if (!pool) {
    registerAgentDiffTheme();
    pool = new WorkerPoolManager(
      { workerFactory: highlightWorkerFactory(location.href), poolSize: 2 },
      {
        langs: language === "text" ? [] : [language as SupportedLanguages],
        lineDiffType,
        theme: { dark: AGENT_DIFF_THEME, light: AGENT_DIFF_THEME_LIGHT },
        tokenizeMaxLineLength: MAX_TOKENIZED_LINE,
      },
    );
    pools.set(lineDiffType, pool);
  }
  return pool;
}
