export type WorkerRendererPhase = "initializing" | "ready" | "failed";

export type WorkerRendererInitializer = {
  initialize(): Promise<void>;
};

export type WorkerRendererInitializationResult =
  | { phase: "ready" }
  | { phase: "failed"; error: unknown };

export const workerRendererInitializationTimeoutMilliseconds = 1_000;

export class WorkerRendererInitializationTimeoutError extends Error {
  constructor(timeoutMilliseconds: number) {
    super(`Diff worker initialization timed out after ${timeoutMilliseconds}ms`);
    this.name = "WorkerRendererInitializationTimeoutError";
  }
}

export async function initializeWorkerRenderer(
  workerPool: WorkerRendererInitializer,
  workerFailure: Promise<unknown> = new Promise(() => {}),
  timeoutMilliseconds = workerRendererInitializationTimeoutMilliseconds,
): Promise<WorkerRendererInitializationResult> {
  let timeoutHandle: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<WorkerRendererInitializationResult>((resolve) => {
    timeoutHandle = setTimeout(() => {
      resolve({
        phase: "failed",
        error: new WorkerRendererInitializationTimeoutError(timeoutMilliseconds),
      });
    }, timeoutMilliseconds);
  });
  try {
    return await Promise.race([
      workerPool.initialize()
        .then<WorkerRendererInitializationResult>(() => ({ phase: "ready" }))
        .catch<WorkerRendererInitializationResult>((error: unknown) => ({ phase: "failed", error })),
      workerFailure.then<WorkerRendererInitializationResult>((error) => ({ phase: "failed", error })),
      deadline,
    ]);
  } finally {
    if (timeoutHandle !== undefined) clearTimeout(timeoutHandle);
  }
}
