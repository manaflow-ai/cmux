import { expect, test } from "bun:test";
import { RAIL_DRAG_PAGE } from "./latency/actions";
import { aggregateAction, distribution, type LatencySample } from "./latency/measure";
import { actionInstrumentation, evidenceErrors, parseOptions, sampleIdle } from "../scripts/latency/run";

test("quantiles retain the tail, empty/nonfinite evidence has no distribution", () => {
  expect(distribution([1, 2, 3, 100])?.p50).toBe(2.5);
  expect(distribution([1, 2, 3, 100])?.p95).toBeCloseTo(85.45);
  expect(distribution([1, 2, 3, 100])?.max).toBe(100);
  expect(distribution([])).toBeNull();
  expect(distribution([NaN])).toBeNull();
});
test("CI is strict, report-only explicit, invalid selectors/values fail before launch", () => {
  expect(parseOptions(["--ci"]).noFail).toBe(false);
  expect(parseOptions(["--ci", "--no-fail"]).noFail).toBe(true);
  for (const args of [["--engine", "missing"], ["--runs", "0"], ["--runs", "NaN"], ["--json"]])
    expect(() => parseOptions(args)).toThrow();
});
test("aggregation labels scroll frames and evidence gate rejects gaps and required unavailable data", () => {
  const sample: LatencySample = {
    work: 2,
    paint: 20,
    frames: 2,
    maxFrameGap: 16,
    frameGaps: [4, 16],
    longTasks: [],
    input: "wheel",
    eventTiming: [],
    reactCommits: 0,
    instrumentation: { longTasks: true, eventTiming: true },
  };
  const result = aggregateAction(
    { page: "chat", engine: "chromium" },
    { name: "scroll", metricType: "scroll_frame_time" } as Parameters<typeof aggregateAction>[1],
    [sample],
    [],
    1,
    16.7,
  );
  expect(result.latencyMs?.p50).toBe(10);
  expect(result.latencyMs?.p95).toBeCloseTo(15.4);
  expect(evidenceErrors([result], [result.id], ["longTasks", "reactCommits"])).toEqual([]);
  expect(evidenceErrors([result], [result.id, "missing"], [])).toContain("missing or duplicate case: missing");
  expect(evidenceErrors([result], [result.id], ["wakeups"])).toContain(`${result.id}: required wakeups unsupported`);
  sample.paint = Infinity;
  expect(evidenceErrors([result], [result.id], []).some((error) => error.includes("invalid numeric"))).toBe(true);
});
test("idle uses real CPU ticks after disposal and reports wakeups unsupported", async () => {
  let disposed = false;
  let read = 0;
  const page = {
    evaluate: async () => {
      disposed = true;
    },
  } as unknown as Parameters<typeof sampleIdle>[0];
  const idle = await sampleIdle(page, 2, async () => {
    expect(disposed).toBe(true);
    return { ThreadTime: ++read / 1000 };
  });
  expect(idle.cpuDurationMs).toBe(1);
  expect(idle.wakeups).toBeNull();
  expect(idle.unsupportedReasons.wakeups).toContain("not wakeups");
});

test("WebKit flow evidence allows missing Long Tasks while Chromium and explicit requirements reject it", () => {
  const action = RAIL_DRAG_PAGE.actions[0];
  const sample: LatencySample = {
    work: 2,
    paint: 20,
    frames: 2,
    maxFrameGap: 16,
    frameGaps: [4, 16],
    longTasks: [],
    input: "pointermove",
    eventTiming: [],
    reactCommits: 1,
    instrumentation: { longTasks: false, eventTiming: false },
  };
  const result = aggregateAction({ page: "chat rail", engine: "webkit" }, action, [sample], [], 1, 16.7);
  expect(result.longTasks).toBeNull();
  expect(evidenceErrors([result], [result.id], actionInstrumentation(action, "webkit"))).toEqual([]);
  expect(evidenceErrors([result], [result.id], actionInstrumentation(action, "chromium"))).toContain(
    `${result.id}: required longTasks unsupported`,
  );
  expect(evidenceErrors([result], [result.id], ["longTasks"])).toContain(
    `${result.id}: required longTasks unsupported`,
  );
});
