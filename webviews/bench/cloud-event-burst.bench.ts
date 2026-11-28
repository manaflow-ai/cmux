// l10n-allow-file: benchmark output, not shipped UI.
// A burst of machine watch events on the Cloud page's store (pages/cloud/store.ts): N machines,
// then one upsert for each (a spending-cap pause marks every running machine at once), each event
// in its own task as the socket delivers them. Frames tick every 16.7 ms. Per run:
//   draws     listener calls (each one is a React render of the page)
//   writes    writes of the kept machine list to storage (each one serializes all N machines)
//   ms        main-thread time inside the store's event handling for the whole burst
// Prints p50 and the spread (min..max) of RUNS runs.
//   bun bench/cloud-event-burst.bench.ts [machines] [runs] [eventsPerFrame]   (default 200 5 50)
/// <reference types="bun" />
import { MockCloudProvider } from "../src/pages/cloud/mockProvider";
import type { CloudMachine } from "../src/pages/cloud/model";
import { CloudStore } from "../src/pages/cloud/store";

const [machinesArg, runsArg, perFrameArg] = process.argv.slice(2).map(Number);
const N = machinesArg || 200;
const RUNS = runsArg || 5;
const PER_FRAME = perFrameArg || 50;
const FRAME_MS = 1000 / 60;

// A 60 Hz frame clock for the store's requestAnimationFrame.
let frameId = 0;
const frames = new Map<number, ReturnType<typeof setTimeout>>();
globalThis.requestAnimationFrame = ((run: FrameRequestCallback) => {
  const id = ++frameId;
  frames.set(
    id,
    setTimeout(() => {
      frames.delete(id);
      run(performance.now());
    }, FRAME_MS),
  );
  return id;
}) as typeof requestAnimationFrame;
globalThis.cancelAnimationFrame = ((id: number) => {
  clearTimeout(frames.get(id));
  frames.delete(id);
}) as typeof cancelAnimationFrame;

class CountingStorage {
  writes = 0;
  readonly items = new Map<string, string>();
  getItem(key: string): string | null {
    return this.items.get(key) ?? null;
  }
  setItem(key: string, value: string): void {
    this.writes += 1;
    this.items.set(key, value);
  }
  removeItem(key: string): void {
    this.items.delete(key);
  }
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const settle = async () => {
  for (let i = 0; i < 40; i++) await Promise.resolve();
  await sleep(100);
};

function fleet(template: CloudMachine): CloudMachine[] {
  return Array.from({ length: N }, (_, i) => ({ ...template, id: `m_${i}`, name: `machine ${i}`, status: "running" }));
}

async function run(): Promise<{ draws: number; writes: number; ms: number }> {
  const provider = new MockCloudProvider();
  provider.machines = fleet(provider.machines[0]!);
  const storage = new CountingStorage();
  const store = new CloudStore(provider, { cache: storage });
  let draws = 0;
  const stop = store.subscribe(() => (draws += 1));
  await settle();
  if (store.getSnapshot().machines.length !== N) throw new Error(`listed ${store.getSnapshot().machines.length}`);
  draws = 0;
  storage.writes = 0;
  let ms = 0;
  const machines = provider.machines.slice();
  // PER_FRAME events per frame, one task each.
  for (let i = 0; i < machines.length; i++) {
    await sleep(i % PER_FRAME === 0 ? FRAME_MS : 0);
    const start = performance.now();
    provider.emitUpsert({ ...machines[i]!, status: "pausing" });
    ms += performance.now() - start;
  }
  await settle();
  const paused = store.getSnapshot().machines.filter((machine) => machine.status === "pausing").length;
  if (paused !== N) throw new Error(`mirror shows ${paused} of ${N} pausing`);
  stop();
  return { draws, writes: storage.writes, ms };
}

const results = [];
for (let i = 0; i < RUNS; i++) results.push(await run());
const stat = (key: "draws" | "writes" | "ms") => {
  const values = results.map((result) => result[key]).sort((a, b) => a - b);
  const fmt = (v: number) => (key === "ms" ? v.toFixed(2) : String(v));
  return `${fmt(values[Math.floor(values.length / 2)]!)} (${fmt(values[0]!)}..${fmt(values.at(-1)!)})`;
};
console.log(`cloud event burst: ${N} machines, ${N} upserts at ${PER_FRAME}/frame, p50 (min..max) of ${RUNS} runs`);
console.log(`  draws  ${stat("draws")}`);
console.log(`  writes ${stat("writes")}`);
console.log(`  ms     ${stat("ms")}`);
