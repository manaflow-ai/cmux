import type { WorkerPoolOptions } from "@pierre/diffs/react";

const mobileUserAgentPattern = /\b(Android|iPhone|iPad|iPod|Mobile)\b/i;

export function diffWorkerPoolSizeForUserAgent(userAgent: string | undefined): number {
  return mobileUserAgentPattern.test(userAgent ?? "") ? 1 : 3;
}

function currentDiffWorkerPoolSize(): number {
  return diffWorkerPoolSizeForUserAgent(typeof navigator === "undefined" ? undefined : navigator.userAgent);
}

// `src/diff-worker.ts` is a second Rollup entry of this bundle, emitted as
// `chunks/diff-worker.mjs`. This module lands in `chunks/diffSurface.mjs`, so
// the entry is a sibling of `import.meta.url`. Vite leaves the expression
// untouched because the file only exists after the build
// (`webviews/test/diff-worker-bundle.test.ts` pins both facts).
export const diffWorkerModuleURL = new URL(/* @vite-ignore */ "./diff-worker.mjs", import.meta.url);

/**
 * Counters for the highlight worker pool. They are mirrored onto
 * `<html data-cmux-diff-worker-*>` so a debug-socket `browser eval` (which
 * runs in an isolated world and cannot read page globals) can prove that
 * workers were spawned from the emitted entry and answered highlight
 * requests even in a hidden web view, where Pierre never paints tokens.
 */
export interface DiffWorkerPoolStats {
  workerURL: string;
  created: number;
  messages: number;
  errors: number;
}

type DatasetTarget = { dataset: DOMStringMap };

export function publishDiffWorkerPoolStats(stats: DiffWorkerPoolStats, target: DatasetTarget | undefined): void {
  if (!target) return;
  target.dataset.cmuxDiffWorkerUrl = stats.workerURL;
  target.dataset.cmuxDiffWorkersCreated = String(stats.created);
  target.dataset.cmuxDiffWorkerMessages = String(stats.messages);
  target.dataset.cmuxDiffWorkerErrors = String(stats.errors);
}

export function createDiffWorkerPoolStats(workerModuleURL: URL): DiffWorkerPoolStats {
  return { workerURL: workerModuleURL.href, created: 0, messages: 0, errors: 0 };
}

export const diffWorkerPoolStats = createDiffWorkerPoolStats(diffWorkerModuleURL);

function statsTarget(): DatasetTarget | undefined {
  return typeof document === "undefined" ? undefined : document.documentElement;
}

export function createDiffWorkerPoolOptions(
  workerModuleURL: URL = diffWorkerModuleURL,
  stats: DiffWorkerPoolStats | undefined = diffWorkerPoolStats,
  WorkerConstructor: typeof Worker = Worker,
  target: DatasetTarget | undefined = statsTarget(),
): WorkerPoolOptions {
  return {
    poolSize: currentDiffWorkerPoolSize(),
    workerFactory: () => {
      const worker = new WorkerConstructor(workerModuleURL, { type: "module" });
      if (stats) {
        stats.created += 1;
        publishDiffWorkerPoolStats(stats, target);
        worker.addEventListener("message", () => {
          stats.messages += 1;
          publishDiffWorkerPoolStats(stats, target);
        });
        worker.addEventListener("error", () => {
          stats.errors += 1;
          publishDiffWorkerPoolStats(stats, target);
        });
      }
      return worker;
    },
  };
}
