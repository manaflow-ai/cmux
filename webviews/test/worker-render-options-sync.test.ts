import { expect, test } from "bun:test";
import { synchronizeWorkerRenderOptions } from "../src/worker-render-options-sync";

test("worker render options finish before the code view render", async () => {
  const calls: string[] = [];
  const workerPool = {
    async setRenderOptions() {
      calls.push("options");
    },
  };

  const synchronized = await synchronizeWorkerRenderOptions({
    highlighterOptions: { langs: ["text"] },
    render: () => calls.push("render"),
    workerPool,
  });
  expect(synchronized).toBe(true);
  expect(calls).toEqual(["options", "render"]);
});
