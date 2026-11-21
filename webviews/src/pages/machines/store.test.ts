// The Machines section's first rows: the snapshot read starts with the subscribe, so the rows land
// while the subscribe is still on its way, and one more read follows once the stream is on.
import { expect, test } from "bun:test";
import type { PageClient } from "../shared/pageClient";
import { sampleSnapshot } from "./mockProvider";
import { MachinesStore } from "./store";
import { MachinesOps } from "./types";

test("the first rows land before the subscribe answers, and one more read follows it", async () => {
  const calls: string[] = [];
  let answerSubscribe: (stop: () => void) => void = () => undefined;
  const client: PageClient = {
    call: async <R>(op: string) => {
      calls.push(op);
      return sampleSnapshot as R;
    },
    subscribe: () => new Promise<() => void>((resolve) => (answerSubscribe = resolve)),
    handle: () => () => undefined,
  };
  const store = new MachinesStore(client);
  const started = store.start();
  await Promise.resolve();
  await Promise.resolve();
  expect(store.getSnapshot().snapshot).toEqual(sampleSnapshot);
  expect(calls).toEqual([MachinesOps.snapshot]);

  answerSubscribe(() => undefined);
  await started;
  expect(calls).toEqual([MachinesOps.snapshot, MachinesOps.snapshot]);
  store.stop();
});
