export type WorkerRendererPhase = "initializing" | "ready" | "failed";

export type WorkerRendererInitializer = {
  initialize(): Promise<void>;
};

export type WorkerRendererInitializationResult =
  | { phase: "ready" }
  | { phase: "failed"; error: unknown };

export async function initializeWorkerRenderer(
  workerPool: WorkerRendererInitializer,
  workerFailure: Promise<unknown> = new Promise(() => {}),
): Promise<WorkerRendererInitializationResult> {
  return Promise.race([
    workerPool.initialize()
      .then<WorkerRendererInitializationResult>(() => ({ phase: "ready" }))
      .catch<WorkerRendererInitializationResult>((error: unknown) => ({ phase: "failed", error })),
    workerFailure.then<WorkerRendererInitializationResult>((error) => ({ phase: "failed", error })),
  ]);
}
