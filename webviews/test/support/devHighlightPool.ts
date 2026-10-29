// The pane's highlight pool for browser tests on a dev server (devHighlightWorker.ts swaps it in for
// conversation/highlightPool.ts): Pierre's own worker as a Vite module worker. Everything else is
// the real module.
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
