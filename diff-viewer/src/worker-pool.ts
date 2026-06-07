import type { WorkerPoolOptions } from "@pierre/diffs/react";

const mobileUserAgentPattern = /\b(Android|iPhone|iPad|iPod|Mobile)\b/i;

export function diffWorkerPoolSizeForUserAgent(userAgent: string | undefined): number {
  return mobileUserAgentPattern.test(userAgent ?? "") ? 1 : 3;
}

function currentDiffWorkerPoolSize(): number {
  return diffWorkerPoolSizeForUserAgent(typeof navigator === "undefined" ? undefined : navigator.userAgent);
}

export function createDiffWorkerPoolOptions(workerModuleURL: URL): WorkerPoolOptions {
  return {
    poolSize: currentDiffWorkerPoolSize(),
    workerFactory: () => new Worker(workerModuleURL, { type: "module" }),
  };
}
