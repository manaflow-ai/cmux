import { beforeEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import * as Effect from "effect/Effect";

import { makeHangReportsHandler } from "../app/api/hang-reports/route";
import {
  bucketCount,
  bucketRange,
  histogramCatalog,
  isWellFormedHistogramName,
  logLinearIndex,
} from "../services/hangReports/histogramCatalog";
import { HangReportsRepository, type HangReportRow, type HangReportsRepositoryShape } from "../services/hangReports/repository";
import { droppedTotals, mergeFieldHistograms, percentile, type StoredFieldReport } from "../scripts/hang-reports/histograms";

const NOW = new Date("2026-10-23T15:30:00Z");
const REPORT_ID = "7a2e4c1d-3b5f-4e6a-8c9d-1f2e3d4c5b6a";
const GOLDEN_REPORT_ID = "5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11";
/** LaunchSlices.swift's async slice id: `0x636D_7578_0000_0000 | name.rawValue`, above 2^53. */
const LAUNCH_ASYNC_ID = "7164511740472852483";

class FakeRepository implements HangReportsRepositoryShape {
  readonly rows = new Map<string, HangReportRow>();
  readonly insertWithinDailyCap: HangReportsRepositoryShape["insertWithinDailyCap"] = (row) => Effect.sync(() => {
    if (this.rows.has(row.reportId)) return "duplicate" as const;
    this.rows.set(row.reportId, row);
    return "inserted" as const;
  });
  readonly deleteReceivedBefore: HangReportsRepositoryShape["deleteReceivedBefore"] = () => Effect.succeed(0);
}

let repository = new FakeRepository();

const POST = makeHangReportsHandler({
  checkRateLimit: async () => ({ rateLimited: false }),
  reportMissingRateLimitRule: () => {},
  run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, repository))),
  reportFailure: () => {},
  now: () => NOW,
});

beforeEach(() => {
  delete process.env.VERCEL;
  repository = new FakeRepository();
});

type FieldHistogram = { name: string; unit: string; buckets: number[][]; count: number; sum: number; max: number };
type Hang = Record<string, unknown> & { source: string; kind: string; durationMs: number };
type Mutable = Record<string, unknown> & {
  counts: Record<string, unknown>;
  hangs: Hang[];
  histograms: FieldHistogram[];
  stability: Record<string, unknown>;
  blackbox: Array<Record<string, unknown>>;
  input_latency: Array<Record<string, unknown> & { buckets: number[] }>;
  input_latency_bucket_edges_ms: number[];
  scroll_jank: { histograms: Array<{ name: string; samples: Array<{ value: number; count: number }> }> };
  launch_sections: Array<Record<string, unknown> & { histograms: FieldHistogram[]; stability: Record<string, unknown> }>;
};

function fixtureText(name: string): string {
  return readFileSync(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
}

function fixture(): Mutable {
  return JSON.parse(fixtureText("hang-report-schema3.json")) as Mutable;
}

function request(body: unknown): Request {
  return new Request("https://cmux.test/api/hang-reports", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function storedPayload(reportId = REPORT_ID): Record<string, unknown> | undefined {
  return repository.rows.get(reportId)?.payload;
}

async function expectStored(body: unknown): Promise<Record<string, unknown>> {
  const response = await POST(request(body));
  expect(response.status).toBe(204);
  const payload = storedPayload();
  expect(payload).toBeDefined();
  return payload ?? {};
}

describe("POST /api/hang-reports schema 3", () => {
  test("answers 204 for every field the client's schema 3 writes and stores them", async () => {
    const payload = await expectStored(fixtureText("hang-report-schema3.json"));
    expect(payload).toMatchObject({
      schema: 3,
      active_seconds: 5400,
      counts: { userBlockingWaitP99Ms: "4-8" },
      dropped: { histograms: 0, stability: 0, blackbox: 0, labels: 0 },
    });
    const hangs = payload.hangs as Hang[];
    expect(hangs[0]).toMatchObject({ source: "detector", kind: "blocking", durationMs: 0, blocking: { kind: "file-io", context: "main" } });
    expect(hangs[1]?.task).toEqual({ class: "visible", owner: "SidebarRows" });
    expect((payload.input_latency_bucket_edges_ms as number[]).length).toBe(13);
    expect((payload.input_latency as Array<{ buckets: number[] }>)[0]?.buckets.length).toBe(14);
    expect((payload.scroll_jank as { presented_frames: number }).presented_frames).toBe(240);
    expect((payload.histograms as FieldHistogram[]).map((histogram) => [histogram.name, histogram.unit, histogram.max]))
      .toEqual([["key.frame.terminal", "us", 60_000_000], ["smoothness.dropped_pct.motion", "pct", 100], ["cef.helper_exit", "enum", 256]]);
    expect(payload.stability).toEqual({
      active_seconds: 5400, child_exit: { renderer: { signal: 1 } }, daemon_unresponsive: { terminal_io: 1 }, launch: 2,
      unclean_exit: { crash: 1 },
    });
    expect((payload.blackbox as unknown[]).length).toBe(5);
    expect((payload.launch_sections as Array<{ id: string; profile: unknown }>)[0]).toMatchObject({
      id: "6f1d2c3b-4a59-4e8d-9c7b-0a1b2c3d4e5f",
      profile: { build: "2123456789011", build_day: "2026-10-21", channel: "nightly", os: "15.7.4", version: "0.69.9" },
    });
    expect((payload.launches as { completionReasons: unknown[] }).completionReasons.length).toBe(2);
    expect((payload.intervals as Array<{ category: string }>).map((interval) => interval.category)).toContain("main");
  });

  test("accepts a black-box argument above 2^53 (an async launch slice id)", async () => {
    const body = fixtureText("hang-report-schema3.json");
    expect(body).toContain(`"arg1":${LAUNCH_ASYNC_ID}`);
    const payload = await expectStored(body);
    const launch = (payload.blackbox as Array<{ phase: string; arg1?: number }>).find((event) => event.phase === "b");
    expect(launch?.arg1).toBe(Number(LAUNCH_ASYNC_ID));
  });

  // The client's goldens (HangReportWireFormatTests.swift on perf/chrome-parity), copied byte for byte.
  for (const [name, reportId] of [
    ["hang-report-schema3-field-data.json", GOLDEN_REPORT_ID],
    ["hang-report-schema3-main-thread.json", GOLDEN_REPORT_ID],
    ["hang-report-schema3-blocking.json", GOLDEN_REPORT_ID],
  ] as const) {
    test(`answers 204 for the client's golden ${name}`, async () => {
      const response = await POST(request(fixtureText(name)));
      expect(response.status).toBe(204);
      expect(storedPayload(reportId)?.schema).toBe(3);
      expect((storedPayload(reportId)?.dropped as { histograms: number }).histograms).toBe(0);
    });
  }

  test("keeps every field of the client's field-data golden", async () => {
    await POST(request(fixtureText("hang-report-schema3-field-data.json")));
    const payload = storedPayload(GOLDEN_REPORT_ID) ?? {};
    expect(payload.blackbox).toEqual([
      { name: "main.turn", phase: "B", process: "app", t_us: 0 },
      { arg0: 7, name: "daemon.request", phase: "E", process: "daemon", t_us: 1250 },
    ]);
    expect(payload.stability).toEqual({
      active_seconds: 5400, child_exit: { daemon: { clean: 1 } }, daemon_unresponsive: { terminal_io: 1 }, launch: 1,
    });
    expect((payload.launch_sections as Array<{ stability: unknown }>)[0]?.stability).toEqual({ launch: 1, unclean_exit: { crash: 1 } });
  });

  const swiftGoldens = new URL(
    "../../Packages/macOS/CmuxNext/Tests/CmuxNextHangReportsTests/HangReportWireFormatTests.swift",
    import.meta.url,
  );
  (existsSync(swiftGoldens) ? test : test.skip)("the fixtures are the Swift client's goldens, byte for byte", () => {
    const swift = readFileSync(swiftGoldens, "utf8");
    const literal = (name: string): string | undefined => new RegExp(`static let ${name} = #"(.*?)"#\\n`).exec(swift)?.[1];
    expect(literal("golden3FieldData")).toBe(fixtureText("hang-report-schema3-field-data.json"));
    expect(literal("golden3MainThread")).toBe(fixtureText("hang-report-schema3-main-thread.json"));
    const golden3 = (literal("golden") ?? "")
      .replace("\"hangs\":[", `"hangs":[${literal("blockingSample") ?? ""},`)
      .replace("\"schema\":2", "\"schema\":3");
    expect(golden3).toBe(fixtureText("hang-report-schema3-blocking.json"));
  });

  test("answers 204 and drops and counts unknown histogram names, Chromium ones too, and stability names", async () => {
    const report = fixture();
    const unknown = (name: string): FieldHistogram => ({ name, unit: "us", buckets: [[44, 3]], count: 3, sum: 9, max: 60_000_000 });
    report.histograms.push(unknown("key.frame.future_target"));
    report.histograms.push({ ...unknown("chromium.Made.Up.Histogram"), unit: "chromium", buckets: [[9999, 1]], max: 0 });
    report.stability.future_count = 2;
    (report.stability.child_exit as Record<string, unknown>).future_kind = { clean: 2, signal: 1 };
    (report.stability.unclean_exit as Record<string, number>).future_exit = 4;
    report.launch_sections[0]!.histograms.push(unknown("brand.new.histogram"));
    report.launch_sections[0]!.stability.daemon_unresponsive = { future_class: 1 };
    const payload = await expectStored(report);
    expect(payload.dropped).toEqual({ histograms: 3, stability: 5, blackbox: 0, labels: 0 });
    const names = (payload.histograms as FieldHistogram[]).map((histogram) => histogram.name);
    expect(names).toEqual(["key.frame.terminal", "smoothness.dropped_pct.motion", "cef.helper_exit"]);
    expect(payload.stability).toEqual({
      active_seconds: 5400, child_exit: { renderer: { signal: 1 } }, daemon_unresponsive: { terminal_io: 1 }, launch: 2,
      unclean_exit: { crash: 1 },
    });
    expect(JSON.stringify(payload)).not.toContain("brand.new.histogram");
    expect(JSON.stringify(payload)).not.toContain("future_");
  });

  test("answers 204 and drops and counts samples, rows and histograms with a label this server does not know", async () => {
    const report = fixture();
    report.hangs.push({ ...report.hangs[0]!, blocking: { kind: "gpu-wait", context: "main" } });
    report.hangs.push({ ...report.hangs[1]!, task: { class: "futureClass", owner: "SidebarRows" } });
    report.input_latency.push({ ...report.input_latency[0]!, kind: "stylusPress" });
    report.scroll_jank.histograms.push({ name: "Event.ScrollJank.FutureMetric.PerScroll", samples: [{ value: 1, count: 1 }] });
    report.blackbox.push({ name: "action.dispatch", phase: "I", process: "future_host", t_us: 9 });
    report.blackbox.push({ name: "action.dispatch", phase: "X", process: "app", t_us: 9 });
    const payload = await expectStored(report);
    expect(payload.dropped).toEqual({ histograms: 0, stability: 0, blackbox: 2, labels: 4 });
    const hangs = payload.hangs as Hang[];
    expect(hangs.length).toBe(5);
    expect(hangs[4]?.task).toBeNull();
    expect((payload.input_latency as unknown[]).length).toBe(2);
    expect((payload.scroll_jank as { histograms: unknown[] }).histograms.length).toBe(2);
  });

  test("drops key, PTY, per-input and flow records from the black box and counts them", async () => {
    const report = fixture();
    const planted = [
      { name: "key.down", phase: "I" },
      { name: "holder.pty.read", phase: "I" },
      { name: "remote.input", phase: "I" },
      { name: "action.dispatch", phase: "s" },
    ];
    for (const event of planted) report.blackbox.push({ arg0: 1, arg1: 2, process: "app", t_us: 5, ...event });
    const payload = await expectStored(report);
    expect(payload.dropped).toMatchObject({ blackbox: 4 });
    expect((payload.blackbox as unknown[]).length).toBe(5);
    expect(JSON.stringify(payload.blackbox)).not.toContain("key.down");
  });

  test("accepts an optional catalog_version", async () => {
    const report = fixture();
    report.catalog_version = 2;
    const payload = await expectStored(report);
    expect(payload.catalog_version).toBe(2);
  });

  test("answers 400 for a bad shape", async () => {
    const cases: Array<(report: Mutable) => void> = [
      (report) => { report.histograms[0]!.name = "Key.Frame.View"; },
      (report) => { report.histograms[0]!.name = `chromium.${"A".repeat(56)}`; },
      (report) => { report.histograms[0]!.name = "chromium.Bad-Name"; },
      (report) => { report.histograms[0]!.name = "x".repeat(65); },
      (report) => { report.histograms[0]!.buckets = [[45, 1], [44, 1]]; },
      (report) => { report.histograms[0]!.buckets = [[44, 1, 3]]; },
      (report) => { report.histograms[0]!.count = -1; },
      (report) => { delete (report.histograms[0] as Partial<FieldHistogram>).unit; },
      (report) => { report.histograms.push({ ...report.histograms[0]! }); },
      (report) => { report.histograms[0]!.buckets = Array.from({ length: 25 }, (_, index) => [8 + index, 1]); },
      (report) => { report.stability.Launch = 1; },
      (report) => { report.stability.launch = -1; },
      (report) => { report.stability.child_exit = { renderer: { signal: { deeper: 1 } } }; },
      (report) => { report.launch_sections[0]!.stability = { launch: 1.5 }; },
      (report) => { report.blackbox[0]!.process = "Renderer"; },
      (report) => { report.blackbox[0]!.phase = "BB"; },
      (report) => { report.blackbox[1]!.arg0 = -1; },
      (report) => { report.blackbox[1]!.arg0 = 1.5; },
      (report) => { report.blackbox[0]!.name = "/Users/alice"; },
      (report) => { report.blackbox[0]!.t_ns = 0; },
      (report) => { report.hangs[0]!.durationMs = 5; },
      (report) => { delete report.hangs[0]!.blocking; },
      (report) => { report.hangs[3]!.blocking = { kind: "file-io", context: "main" }; },
      (report) => { report.hangs[3]!.task = { class: "visible", owner: "SidebarRows" }; },
      (report) => { report.hangs[1]!.task = { class: "visible", owner: "cmux config" }; },
      (report) => { report.hangs[0]!.blocking = { kind: "File IO", context: "main" }; },
      (report) => { report.counts.userBlockingWaitP99Ms = "9-10"; },
      (report) => { report.input_latency[0]!.buckets = [1, 2]; },
      (report) => { delete (report as Partial<Mutable>).input_latency_bucket_edges_ms; },
      (report) => { report.input_latency_bucket_edges_ms = [2, 1]; },
      (report) => { (report.input_latency[0]!.display as Record<string, unknown>).refresh_hz = 5000; },
      (report) => { report.scroll_jank.histograms[0]!.samples = [{ value: 101, count: 1 }]; },
      (report) => { delete report.launch_sections[0]!.id; },
      (report) => { report.launch_sections[0]!.profile = { app: { build: "1", channel: "nightly", version: "0.69.9" }, os: { version: "15.7.4" } }; },
      (report) => { report.launch_sections.push({ ...report.launch_sections[0]! }); },
      (report) => { report.sections = []; },
      (report) => { report.catalog_version = 0; },
      (report) => { report.extra = true; },
      (report) => { (report.launches as Record<string, unknown>).launchFirstFrame = [{ temperature: "hot", count: 1, buckets: [] }]; },
    ];
    for (const [index, mutate] of cases.entries()) {
      const report = fixture();
      mutate(report);
      const response = await POST(request(report));
      expect({ index, status: response.status }).toEqual({ index, status: 400 });
    }
    expect(repository.rows.size).toBe(0);
  });

  test("names the reason for a catalog histogram whose bucket, unit or ceiling disagrees with its layout", async () => {
    const cases: Array<[(report: Mutable) => void, string]> = [
      [(report) => { report.histograms[0]!.buckets = [[200, 1]]; }, "histogram_bucket"],
      [(report) => { report.histograms[0]!.buckets = [[5, 1]]; }, "histogram_bucket"],
      [(report) => { report.histograms[1]!.buckets = [[102, 1]]; }, "histogram_bucket"],
      [(report) => { report.launch_sections[0]!.histograms[0]!.buckets = [[6, 1]]; }, "histogram_bucket"],
      [(report) => { report.histograms[0]!.unit = "ms"; }, "histogram_layout"],
      [(report) => { report.histograms[2]!.max = 4; }, "histogram_layout"],
    ];
    for (const [mutate, reason] of cases) {
      const report = fixture();
      mutate(report);
      const response = await POST(request(report));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_report", reason });
    }
  });

  test("answers 413 for a schema 3 body over 64 KiB", async () => {
    const report = fixture();
    report.blackbox = Array.from({ length: 512 }, (_, index) => ({
      arg0: Number.MAX_SAFE_INTEGER, arg1: Number.MAX_SAFE_INTEGER, name: "action.dispatch.with_a_long_catalog_name",
      phase: "I", process: "chromium_host", t_us: Number.MAX_SAFE_INTEGER - index,
    }));
    const response = await POST(request(report));
    expect(response.status).toBe(413);
    expect(repository.rows.size).toBe(0);
  });

  test("still answers 204 for schema 2 and refuses schema 3 fields in a schema 2 body", async () => {
    const schema2 = fixtureText("hang-report-schema2.json");
    expect((await POST(request(schema2))).status).toBe(204);
    expect(repository.rows.get(GOLDEN_REPORT_ID)?.payload.dropped).toBeUndefined();
    const v3 = fixture();
    const mutations: Array<(report: Record<string, unknown> & { counts: Record<string, unknown>; hangs: Hang[]; intervals: Array<{ category: string }> }) => void> = [
      (report) => { report.catalog_version = 1; },
      (report) => { report.input_latency = v3.input_latency; report.input_latency_bucket_edges_ms = v3.input_latency_bucket_edges_ms; },
      (report) => { report.scroll_jank = v3.scroll_jank; },
      (report) => { report.histograms = v3.histograms; },
      (report) => { report.counts.userBlockingWaitP99Ms = "4-8"; },
      (report) => { report.hangs.unshift(v3.hangs[0]!); },
      (report) => { report.hangs[0]!.task = { class: "visible", owner: "SidebarRows" }; },
      (report) => { report.intervals[0]!.category = "main"; },
    ];
    for (const [index, mutate] of mutations.entries()) {
      const report = { ...JSON.parse(schema2), reportId: crypto.randomUUID() };
      mutate(report);
      expect({ index, status: (await POST(request(report))).status }).toEqual({ index, status: 400 });
    }
  });
});

describe("histogram catalog", () => {
  test("mirrors the client's log-linear bucket math", () => {
    expect([0, 1, 3, 4, 5, 6, 7, 8, 12, 16, 1000, 3000, 60_000_000].map(logLinearIndex))
      .toEqual([0, 1, 3, 8, 9, 10, 11, 12, 14, 16, 39, 45, 103]);
    for (let value = 4; value < 5000; value += 1) {
      const index = logLinearIndex(value);
      const range = bucketRange({ kind: "logLinear", maximum: 1_000_000 }, index);
      expect(range && range.low <= value && value <= (range.high ?? Infinity)).toBe(true);
    }
    expect(bucketCount({ kind: "logLinear", maximum: 60_000_000 })).toBe(105);
    expect(bucketRange({ kind: "logLinear", maximum: 60_000_000 }, 104)).toEqual({ low: 60_000_001, high: null });
    expect(bucketRange({ kind: "logLinear", maximum: 60_000_000 }, 6)).toBeNull();
    expect(bucketRange({ kind: "enumeration", valueCount: 4 }, 4)).toEqual({ low: 4, high: null });
  });

  test("lists every catalog name in the wire shape, Chromium's spelling aside", () => {
    const names = [...histogramCatalog().keys()];
    expect(names.length).toBe(new Set(names).size);
    for (const name of names) expect(isWellFormedHistogramName(name)).toBe(true);
    expect(names).toContain("key.frame.view");
    expect(names).toContain("daemon.request.terminal_io");
    expect(names).toContain("webview.inp.home");
    expect(names).toContain("chromium.EventLatency.KeyPressed.TotalLatency");
  });

  test("takes any bounded UMA-spelled Chromium name as well formed", () => {
    expect(isWellFormedHistogramName("chromium.Made.Up.Histogram")).toBe(true);
    expect(isWellFormedHistogramName(`chromium.${"A".repeat(55)}`)).toBe(true);
    expect(isWellFormedHistogramName(`chromium.${"A".repeat(56)}`)).toBe(false);
    expect(isWellFormedHistogramName("Chromium.EventLatency")).toBe(false);
    expect(isWellFormedHistogramName("Key.Frame.View")).toBe(false);
  });
});

describe("hang report histogram merge", () => {
  const stored = (installId: string, day: string, payload: StoredFieldReport["payload"]): StoredFieldReport =>
    ({ installId, receivedDay: day, appVersion: payload.app?.version ?? null, payload });
  const section = { id: "6F1D2C3B-4A59-4E8D-9C7B-0A1B2C3D4E5F", profile: { version: "0.69.9" } };

  test("sums buckets per name, version and day, sections under their own version and once per id", () => {
    const reports = [
      stored("a", "2026-10-22", {
        schema: 3, app: { version: "0.70.0" },
        histograms: [{ name: "key.frame.view", buckets: [[40, 90], [48, 10]] }],
        launch_sections: [{ ...section, histograms: [{ name: "key.frame.view", buckets: [[44, 5]] }] }],
        dropped: { histograms: 2, stability: 1, blackbox: 0, labels: 3 },
      }),
      // The same section again: the client resent it after an upload it did not see succeed.
      stored("a", "2026-10-22", {
        schema: 3, app: { version: "0.70.0" },
        launch_sections: [{ ...section, id: section.id.toLowerCase(), histograms: [{ name: "key.frame.view", buckets: [[44, 5]] }] }],
      }),
      stored("b", "2026-10-22", { schema: 3, app: { version: "0.70.0" }, histograms: [{ name: "key.frame.view", buckets: [[40, 10]] }] }),
      stored("c", "2026-10-22", { schema: 2, app: { version: "0.70.0" } }),
    ];
    const merged = mergeFieldHistograms(reports);
    expect(merged.map((row) => [row.name, row.version, row.day, row.count, row.installs])).toEqual([
      ["key.frame.view", "0.69.9", "2026-10-22", 5, 1],
      ["key.frame.view", "0.70.0", "2026-10-22", 110, 2],
    ]);
    const current = merged[1]!;
    expect(current.buckets).toEqual([[40, 100], [48, 10]]);
    // Bucket 40 is 1024..1279 us, bucket 48 is 4096..5119 us: p50 and p95 read upper bounds.
    expect(current.p50).toEqual({ value: 1279, atLeast: false });
    expect(current.p95).toEqual({ value: 5119, atLeast: false });
    expect(droppedTotals(reports)).toEqual({ histograms: 2, stability: 1, blackbox: 0, labels: 3 });
  });

  test("marks overflow and Chromium percentiles as lower bounds and skips enumerations", () => {
    expect(percentile("hang.over250.per_hour", [[logLinearIndex(1_000_000) + 1, 3]], 0.5))
      .toEqual({ value: 1_000_001, atLeast: true });
    expect(percentile("chromium.EventLatency.KeyPressed.TotalLatency", [[1000, 3], [2000, 1]], 0.99))
      .toEqual({ value: 2000, atLeast: true });
    expect(percentile("stability.unclean_exit", [[0, 1]], 0.5)).toBeNull();
    expect(percentile("not.in.catalog", [[8, 1]], 0.5)).toBeNull();
  });
});
