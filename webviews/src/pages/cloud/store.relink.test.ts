// The Cloud page reads again the moment the host says the owner link is back (`cmux.page.connection`),
// not at its next backoff step (Leo, 2026-11-14: "load faster/percievably load faster / whatever it
// takes"). The backoff (1 s doubling to 10 s) stays for a host that never says.
//
// It also measures, over drops of 10 s and 60 s (each with its start spread over the backoff's steps),
// the time from the link coming back to the page connected again, and prints p50 and p95: with the
// stream that is the reads' own time; without it, the rest of the backoff step.
import { afterEach, expect, jest, test } from "bun:test";
import { MockPageStreams } from "../shared/pageStreams";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { CloudStore } from "./store";

const settle = async () => {
  for (let i = 0; i < 60; i++) await Promise.resolve();
};

afterEach(() => jest.useRealTimers());

/** The mock Cloud server plus the host's page streams, as the app serves both on one bridge. */
class LinkedProvider extends MockCloudProvider {
  readonly streams = new MockPageStreams();
  constructor(private readonly says: boolean) {
    super();
  }
  override async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.says) {
      const stop = this.streams.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
      if (stop) return stop;
    }
    return super.subscribe<E>(stream, onEvent);
  }
  /** The daemon goes away (every call fails as a transport error) and the host says so. */
  drop(): void {
    this.offline = true;
    this.streams.setConnected(false);
  }
  back(): void {
    this.offline = false;
    this.streams.setConnected(true);
  }
}

/** A live page whose link drops under a read, stays down `downMs`, then comes back: ms until connected. */
async function recovery(says: boolean, downMs: number): Promise<number> {
  jest.useFakeTimers();
  const provider = new LinkedProvider(says);
  const store = new CloudStore(provider);
  const stop = store.subscribe(() => undefined);
  try {
    await settle();
    expect(store.getSnapshot().connection).toBe("connected");
    provider.drop();
    await store.select(sampleMachines()[0].id);
    await settle();
    expect(store.getSnapshot().connection).toBe("disconnected");
    // Down for `downMs`, in 100 ms steps so the backoff's reads run and fail as they would.
    for (let t = 0; t < downMs; t += 100) {
      jest.advanceTimersByTime(100);
      await settle();
    }
    provider.back();
    await settle();
    let waited = 0;
    while (store.getSnapshot().connection !== "connected" && waited < 30_000) {
      jest.advanceTimersByTime(10);
      waited += 10;
      await settle();
    }
    return waited;
  } finally {
    stop();
    jest.useRealTimers();
  }
}

test("the host's word that the link is back reads again at once, with no backoff wait", async () => {
  expect(await recovery(true, 10_000)).toBeLessThanOrEqual(10);
  expect(await recovery(true, 60_000)).toBeLessThanOrEqual(10);
});

test("a host that never says still comes back on the backoff", async () => {
  const waited = await recovery(false, 10_000);
  expect(waited).toBeGreaterThan(0);
  expect(waited).toBeLessThanOrEqual(10_000);
});

test("measure: link back to connected, 10 s and 60 s drops, with and without the host's word", async () => {
  const pct = (values: number[], q: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.round(q * (sorted.length - 1)))];
  };
  for (const base of [10_000, 60_000]) {
    for (const says of [false, true]) {
      const samples: number[] = [];
      // The drop's length spread across one backoff step (0 to 10 s in 500 ms steps), so where the
      // link comes back within a step is spread too.
      for (let extra = 0; extra < 10_000; extra += 500) samples.push(await recovery(says, base + extra));
      console.log(
        `cloud_page.relink drop=${base / 1000}s host_says=${says} n=${samples.length} p50=${pct(samples, 0.5)}ms p95=${pct(samples, 0.95)}ms`,
      );
      if (says) expect(pct(samples, 0.95)).toBeLessThanOrEqual(10);
    }
  }
}, 120_000);
