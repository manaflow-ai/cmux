import { expect, test } from "bun:test";
import {
  advanceWorkerRenderOptionsSyncState,
  synchronizeWorkerRenderOptions,
} from "../src/worker-render-options-sync";

test("the provider's initial render options do not start a competing synchronization", () => {
  const workerPool = {};
  const initial = advanceWorkerRenderOptionsSyncState({
    highlighterOptions: { langs: ["text"] },
    previous: null,
    sameOptions: (previous, next) => previous.langs.join() === next.langs.join(),
    workerPool,
  });
  expect(initial.shouldSynchronize).toBe(false);

  const unchanged = advanceWorkerRenderOptionsSyncState({
    highlighterOptions: { langs: ["text"] },
    previous: initial.next,
    sameOptions: (previous, next) => previous.langs.join() === next.langs.join(),
    workerPool,
  });
  expect(unchanged.shouldSynchronize).toBe(false);

  const changed = advanceWorkerRenderOptionsSyncState({
    highlighterOptions: { langs: ["text", "swift"] },
    previous: unchanged.next,
    sameOptions: (previous, next) => previous.langs.join() === next.langs.join(),
    workerPool,
  });
  expect(changed.shouldSynchronize).toBe(true);

  const replacementPool = advanceWorkerRenderOptionsSyncState({
    highlighterOptions: { langs: ["text", "swift"] },
    previous: changed.next,
    sameOptions: (previous, next) => previous.langs.join() === next.langs.join(),
    workerPool: {},
  });
  expect(replacementPool.shouldSynchronize).toBe(false);
});

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
