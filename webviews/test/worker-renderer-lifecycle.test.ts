import { expect, test } from "bun:test";
import {
  initializeWorkerRenderer,
  WorkerRendererInitializationTimeoutError,
} from "../src/worker-renderer-lifecycle";

test("the renderer stays pending until the worker pool initialization completes", async () => {
  let release: (() => void) | undefined;
  const initialization = initializeWorkerRenderer({
    initialize: () => new Promise<void>((resolve) => {
      release = resolve;
    }),
  });
  let settled = false;
  void initialization.then(() => {
    settled = true;
  });

  await Promise.resolve();
  expect(settled).toBe(false);
  release?.();
  expect(await initialization).toEqual({ phase: "ready" });
});

test("worker initialization failure selects the explicit fallback phase", async () => {
  const error = new Error("worker unavailable");
  expect(await initializeWorkerRenderer({
    initialize: async () => {
      throw error;
    },
  })).toEqual({ phase: "failed", error });
});

test("a worker error selects fallback even when pool initialization never settles", async () => {
  const error = new Error("worker load failed");
  expect(await initializeWorkerRenderer(
    { initialize: () => new Promise<void>(() => {}) },
    Promise.resolve(error),
  )).toEqual({ phase: "failed", error });
});

test("a worker initialization deadline selects fallback when no lifecycle signal arrives", async () => {
  const result = await initializeWorkerRenderer(
    { initialize: () => new Promise<void>(() => {}) },
    new Promise(() => {}),
    0,
  );

  expect(result.phase).toBe("failed");
  if (result.phase === "failed") {
    expect(result.error).toBeInstanceOf(WorkerRendererInitializationTimeoutError);
  }
});
