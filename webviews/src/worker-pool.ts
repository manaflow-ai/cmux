import type { WorkerPoolOptions } from "@pierre/diffs/react";

const mobileUserAgentPattern = /\b(Android|iPhone|iPad|iPod|Mobile)\b/i;

export function diffWorkerPoolSizeForUserAgent(userAgent: string | undefined): number {
  return mobileUserAgentPattern.test(userAgent ?? "") ? 1 : 3;
}

function currentDiffWorkerPoolSize(): number {
  return diffWorkerPoolSizeForUserAgent(typeof navigator === "undefined" ? undefined : navigator.userAgent);
}

export type DiffWorkerPoolRuntime = {
  failure: Promise<unknown>;
  poolOptions: WorkerPoolOptions;
};

export function createDiffWorkerPoolRuntime(workerModuleURL: URL): DiffWorkerPoolRuntime {
  let reportFailure: (error: unknown) => void = () => {};
  const failure = new Promise<unknown>((resolve) => {
    reportFailure = resolve;
  });
  const poolOptions: WorkerPoolOptions = {
    poolSize: currentDiffWorkerPoolSize(),
    workerFactory: () => {
      const worker = new Worker(workerModuleURL, { type: "module" });
      worker.addEventListener("error", (event) => {
        reportFailure(event.error ?? new Error(event.message || "Diff worker failed"));
      }, { once: true });
      return worker;
    },
  };
  return { failure, poolOptions };
}
