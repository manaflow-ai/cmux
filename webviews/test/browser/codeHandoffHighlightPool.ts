// The pane's highlight pool for the code-handoff-height page (code-handoff-height.test.ts swaps it
// in for conversation/highlightPool.ts on that test's dev server only). The app's page starts
// Pierre's worker from its bundled `highlight-worker.js`; the dev server serves none, so there a
// transcript code card stays plain (#25876) and never becomes the highlighted card this page
// measures. Here the pool runs Pierre's own worker as a Vite module worker, off the main thread
// as in the app. Everything else is the real module.
import { WorkerPoolManager } from "@pierre/diffs/worker";
import type { SupportedLanguages } from "@pierre/diffs";
// Vite's `?worker` suffix gives a Worker constructor as the default export (vite/client types).
// oxlint-disable-next-line import/default
import PierreWorker from "@pierre/diffs/worker/worker.js?worker";
import {
  AGENT_DIFF_THEME,
  AGENT_DIFF_THEME_LIGHT,
  registerAgentDiffTheme,
} from "../../src/agent-session/acpmux/diffTheme";
import { MAX_TOKENIZED_LINE } from "../../src/agent-session/acpmux/conversation/highlightLimits";
import type { HighlightLineDiffType } from "../../src/agent-session/acpmux/conversation/highlightPool";

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
      { workerFactory: () => new PierreWorker(), poolSize: 2 },
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
