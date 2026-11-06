import { afterEach, beforeEach, expect, test } from "bun:test";
import { aggregateAdapterAction, measureAdapterOnce } from "./adapter-measure";
import type { AdapterRun, LatencyAction } from "./measure";
import { evidenceErrors } from "../../scripts/latency/run";
type Page = Parameters<typeof measureAdapterOnce>[0];

const measured = (): AdapterRun => ({
  status: "complete",
  observations: [
    { status: "superseded", latencyMs: null, inputAt: 90, targetPaintAt: null, raw: { targetRowId: "user-1" } },
    {
      status: "painted",
      latencyMs: 20,
      inputAt: 100,
      targetPaintAt: 120,
      raw: { targetRowId: "user-2", releaseToPaintMs: 3, lastMoveToPaintMs: 20, alreadyPaintedBeforeRelease: true },
    },
  ],
  frameGaps: [8, 12],
  longTasks: [],
  reactCommits: 2,
  unsupportedReasons: {},
});
const action: LatencyAction = { id: "chat.rail.drag", name: "rail drag", metricType: "drag_target_painted" };
const spec = { page: "chat rail", engine: "chromium" };
let savedWindow: unknown;
let hadWindow = false;
beforeEach(() => {
  hadWindow = "window" in globalThis;
  savedWindow = globalThis.window;
});
afterEach(() => {
  if (hadWindow) Object.assign(globalThis, { window: savedWindow });
  else delete (globalThis as Record<string, unknown>).window;
});
function harness() {
  const events: string[] = [];
  let closed = false;
  const observers: Observer[] = [];
  class Observer {
    static supportedEntryTypes = ["longtask"];
    pending: PerformanceEntry[] = [];
    disconnected = false;
    constructor(_callback: unknown) {
      observers.push(this);
    }
    observe() {}
    takeRecords() {
      return this.pending.splice(0);
    }
    disconnect() {
      this.disconnected = true;
    }
  }
  const scope = {
    PerformanceObserver: Observer as typeof Observer | undefined,
    __latencyReactCommits: 1 as number | undefined,
    __latency: {
      stop: () => {
        events.push("probe stop");
      },
    },
  };
  Object.assign(globalThis, { window: scope });
  const page = {
    evaluate: async (fn: () => unknown) => fn(),
    close: async () => {
      closed = true;
      for (const observer of observers) observer.disconnect();
      delete (scope as Record<string, unknown>).__latencyAdapterMetrics;
      events.push("close");
    },
    isClosed: () => closed,
  } as unknown as Page;
  return { page, events, scope, observers };
}

test("autonomous sampler keeps raw superseded observations, release fields and genuine paint distribution", async () => {
  const h = harness();
  let signal: AbortSignal | undefined;
  const run = await measureAdapterOnce(
    h.page,
    {
      ...action,
      async measureRun(_page, context) {
        signal = context.signal;
        context.onCleanup(() => {
          h.events.push("sampler cleanup");
        });
        h.scope.__latencyReactCommits! += 2;
        return measured();
      },
      async settle() {
        h.events.push("settle");
      },
    },
    16.7,
  );
  expect(signal?.aborted).toBe(true);
  expect(h.events).toEqual(["probe stop", "sampler cleanup", "probe stop", "settle"]);
  const result = aggregateAdapterAction(spec, action, [run], 1, 16.7);
  expect(result.samples).toEqual([]);
  expect(result.latencyMs).toEqual({ p50: 20, p95: 20, max: 20 });
  expect(result.adapterRuns?.[0].observations[0].latencyMs).toBeNull();
  expect(result.adapterRuns?.[0].observations[1].raw).toEqual(measured().observations[1].raw);
  expect(evidenceErrors([result], [result.id], ["longTasks", "reactCommits"])).toEqual([]);
  const cadence = aggregateAdapterAction(spec, { ...action, metricType: "frame_time" }, [run], 1, 16.7);
  expect(cadence.latencyMs?.p50).toBe(10);
});

test("deadline cancels sampler resources, closes its page and keeps a null timeout observation", async () => {
  const h = harness();
  let aborted = false;
  const run = await measureAdapterOnce(
    h.page,
    {
      ...action,
      async measureRun(_page, context) {
        context.signal.addEventListener(
          "abort",
          () => {
            aborted = true;
          },
          { once: true },
        );
        context.onCleanup(() => {
          h.events.push("sampler cleanup");
        });
        return new Promise<AdapterRun>(() => {});
      },
    },
    16.7,
    5,
  );
  expect(aborted).toBe(true);
  expect(h.events).toEqual(["probe stop", "close", "sampler cleanup"]);
  expect(run.status).toBe("timeout");
  expect(run.observations[0].latencyMs).toBeNull();
  const result = aggregateAdapterAction(spec, action, [run], 1, 16.7);
  expect(result.latencyMs).toBeNull();
  expect(result.pass).toBe(false);
});

test("wrapper drains queued Long Tasks before disconnect and counts actual profiling counter deltas", async () => {
  const h = harness();
  const run = await measureAdapterOnce(
    h.page,
    {
      ...action,
      async measureRun() {
        h.observers[0].pending.push({ startTime: performance.now(), duration: 55 } as PerformanceEntry);
        h.scope.__latencyReactCommits! += 3;
        return measured();
      },
    },
    16.7,
  );
  expect(run.longTasks).toEqual([55]);
  expect(run.reactCommits).toBe(3);
  expect(h.observers[0].disconnected).toBe(true);
  expect((h.scope as Record<string, unknown>).__latencyAdapterMetrics).toBeUndefined();
});

test("wrapper keeps missing observer and commit sources null rather than trusting adapter zeroes", async () => {
  const h = harness();
  h.scope.PerformanceObserver = undefined;
  h.scope.__latencyReactCommits = undefined;
  const run = await measureAdapterOnce(h.page, { ...action, measureRun: async () => measured() }, 16.7);
  expect(run.longTasks).toBeNull();
  expect(run.reactCommits).toBeNull();
  const result = aggregateAdapterAction(spec, action, [run], 1, 16.7);
  expect(evidenceErrors([result], [result.id], ["longTasks", "reactCommits"]).length).toBe(2);
});

test("failed cleanup preserves raw observations but prevents a successful result", async () => {
  const h = harness();
  const run = await measureAdapterOnce(
    h.page,
    {
      ...action,
      async measureRun(_page, context) {
        context.onCleanup(() => {
          throw new Error("cleanup failed");
        });
        return measured();
      },
    },
    16.7,
  );
  expect(h.page.isClosed()).toBe(true);
  expect(run.observations).toEqual(measured().observations);
  expect(aggregateAdapterAction(spec, action, [run], 1, 16.7).pass).toBe(false);
});

test("missing instrumentation, missing cadence, bad causal timestamps and unpainted latencies fail closed", () => {
  const run = measured();
  run.longTasks = null;
  run.reactCommits = null;
  run.frameGaps = null;
  const result = aggregateAdapterAction(spec, action, [run], 1, 16.7);
  expect(evidenceErrors([result], [result.id], ["longTasks", "reactCommits"])).toContain(
    `${result.id}: required longTasks unsupported`,
  );
  expect(evidenceErrors([result], [result.id], ["longTasks", "reactCommits"])).toContain(
    `${result.id}: required reactCommits unsupported`,
  );
  expect(aggregateAdapterAction(spec, { ...action, metricType: "frame_time" }, [run], 1, 16.7).pass).toBe(false);
  run.observations[0].latencyMs = 0;
  run.observations[1].targetPaintAt = 90;
  expect(aggregateAdapterAction(spec, action, [run], 1, 16.7).errors).toContain(
    "unpainted adapter observation has a latency",
  );
  expect(aggregateAdapterAction(spec, action, [run], 1, 16.7).errors).toContain(
    "adapter paint lacks valid causal input/postpaint timestamps",
  );
});
