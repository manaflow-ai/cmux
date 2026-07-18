import { expect, test } from "bun:test";
import { synchronizeWorkerRenderOptions } from "../src/worker-render-options-sync";

test("worker render options wait for the code view lifecycle", async () => {
  const calls: string[] = [];
  const workerPool = {
    async setRenderOptions() {
      calls.push("options");
    },
  };

  const deferred = await synchronizeWorkerRenderOptions({
    codeViewReady: false,
    highlighterOptions: { langs: ["text"] },
    render: () => calls.push("render"),
    workerPool,
  });
  expect(deferred).toBe(false);
  expect(calls).toEqual([]);

  const synchronized = await synchronizeWorkerRenderOptions({
    codeViewReady: true,
    highlighterOptions: { langs: ["text"] },
    render: () => calls.push("render"),
    workerPool,
  });
  expect(synchronized).toBe(true);
  expect(calls).toEqual(["options", "render"]);
});
