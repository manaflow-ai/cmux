import { beforeEach, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";

import { makeHangReportsHandler } from "../app/api/hang-reports/route";
import { HISTOGRAM_CATALOG, HISTOGRAM_CATALOG_VERSION, bucketRange, maxBucketIndex } from "../services/hangReports/histogramCatalog";
import { HangReportsRepository, type HangReportRow, type HangReportsRepositoryShape } from "../services/hangReports/repository";
import { MAX_BLACKBOX_EVENTS, MAX_HISTOGRAMS, MAX_HISTOGRAM_BUCKETS } from "../services/hangReports/wireSchema";

const NOW = new Date("2026-10-23T15:30:00Z");

class FakeRepository implements HangReportsRepositoryShape {
  readonly rows = new Map<string, HangReportRow>();
  readonly insertWithinDailyCap: HangReportsRepositoryShape["insertWithinDailyCap"] = (row) =>
    Effect.sync(() => {
      if (this.rows.has(row.reportId)) return "duplicate" as const;
      this.rows.set(row.reportId, row);
      return "inserted" as const;
    });
  readonly deleteReceivedBefore: HangReportsRepositoryShape["deleteReceivedBefore"] = () => Effect.succeed(0);
}

let repository = new FakeRepository();
const spans: Array<Record<string, unknown>> = [];

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
  spans.length = 0;
});

type Histogram = { name: string; unit: string; buckets: Array<[number, number]>; count: number; sum: number; max: number };

function histogram(name: string, unit = "microseconds", buckets: Array<[number, number]> = [[20, 3], [24, 1]]): Histogram {
  const count = buckets.reduce((total, [, value]) => total + value, 0);
  return { name, unit, buckets, count, sum: 4_000 * count, max: 9_000 };
}

function schema3Report() {
  return {
    schema: 3,
    reportId: "7A1C7C1E-2B9B-4A8E-9C62-0F0D2B0B8A11",
    installId: "0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20",
    day: "2026-10-23",
    app: { version: "0.71.0", build: "71001", channel: "nightly" },
    os: { version: "26.1" },
    hardware: { arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48 },
    counts: { windows: "1", workspaces: "2-5", panes: "6-10", tabs: "11-30" },
    hangs: [] as unknown[],
    catalogVersion: 1,
    histograms: [
      histogram("key.frame.terminal"),
      histogram("daemon.request.topology"),
      histogram("chromium.EventLatency.KeyPressed.TotalLatency", "chromium", [[7, 2]]),
      histogram("smoothness.dropped_pct.motion", "percent", [[0, 50], [3, 2]]),
    ] as Histogram[],
    stability: { "stability.launch": 1, "stability.unclean_exit.crash": 0, "stability.child_exit.daemon.signal": 1 } as Record<string, number>,
    blackbox: [
      { process: "app", name: "main.turn", atUs: 1_200, durUs: 900 },
      { process: "daemon", name: "daemon.request", atUs: 800, durUs: 300, value: 2 },
    ] as Array<Record<string, unknown>>,
    launches: [
      {
        app: { version: "0.70.9", build: "70901", channel: "nightly" },
        os: { version: "26.1" },
        histograms: [histogram("daemon.request.topology")],
        stability: { "stability.launch": 1, "stability.unclean_exit.killed": 1 },
      },
    ] as Array<Record<string, unknown>>,
  };
}

function reportRequest(body: unknown): Request {
  return new Request("https://cmux.test/api/hang-reports", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function storedPayload(reportId = "7a1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11") {
  return repository.rows.get(reportId)?.payload as ReturnType<typeof schema3Report> & {
    ingest: { catalogVersion: number; unknownHistograms: number; mismatchedHistograms: number; unknownStabilityKeys: number };
  };
}

describe("POST /api/hang-reports schema 3", () => {
  test("stores a schema 3 report with its histograms, stability, black box and launches (204)", async () => {
    const response = await POST(reportRequest(schema3Report()));
    expect(response.status).toBe(204);
    const payload = storedPayload();
    expect(payload.schema).toBe(3);
    expect(payload.catalogVersion).toBe(1);
    expect(payload.histograms.map((entry) => entry.name)).toEqual([
      "key.frame.terminal",
      "daemon.request.topology",
      "chromium.EventLatency.KeyPressed.TotalLatency",
      "smoothness.dropped_pct.motion",
    ]);
    expect(payload.stability).toEqual({ "stability.launch": 1, "stability.unclean_exit.crash": 0, "stability.child_exit.daemon.signal": 1 });
    expect(payload.blackbox).toHaveLength(2);
    expect(payload.launches).toHaveLength(1);
    expect(payload.ingest).toEqual({ catalogVersion: HISTOGRAM_CATALOG_VERSION, unknownHistograms: 0, mismatchedHistograms: 0, unknownStabilityKeys: 0 });
  });

  test("accepts a minimal schema 3 report, the way JSONEncoder omits empty optionals", async () => {
    const minimal: Record<string, unknown> = { ...schema3Report() };
    for (const key of ["hangs", "histograms", "stability", "blackbox", "launches"]) delete minimal[key];
    expect((await POST(reportRequest(minimal))).status).toBe(204);
    const payload = storedPayload();
    expect(payload.histograms).toEqual([]);
    expect(payload.stability).toEqual({});
  });

  test("drops and counts unknown histogram names and stability keys, still 204", async () => {
    const report = schema3Report();
    report.histograms.push(histogram("key.frame.future_target"), histogram("brand_new.metric"));
    report.stability["stability.child_exit.future_kind.clean"] = 3;
    (report.launches[0]!.histograms as Histogram[]).push(histogram("old.removed_name"));
    const response = await POST(reportRequest(report));
    expect(response.status).toBe(204);
    const payload = storedPayload();
    const names = [...payload.histograms, ...(payload.launches[0]!.histograms as Histogram[])].map((entry) => entry.name);
    expect(names).not.toContain("key.frame.future_target");
    expect(names).not.toContain("brand_new.metric");
    expect(names).not.toContain("old.removed_name");
    expect(payload.histograms).toHaveLength(4);
    expect(Object.keys(payload.stability)).not.toContain("stability.child_exit.future_kind.clean");
    expect(payload.ingest).toEqual({ catalogVersion: HISTOGRAM_CATALOG_VERSION, unknownHistograms: 3, mismatchedHistograms: 0, unknownStabilityKeys: 1 });
  });

  test("drops and counts a catalog name sent with another unit or a bucket past its layout", async () => {
    const report = schema3Report();
    report.histograms.push(histogram("main.turn", "milliseconds"));
    const last = maxBucketIndex(HISTOGRAM_CATALOG.get("smoothness.dropped_pct.scroll")!.layout)!;
    report.histograms.push(histogram("smoothness.dropped_pct.scroll", "percent", [[last + 1, 1]]));
    expect((await POST(reportRequest(report))).status).toBe(204);
    const payload = storedPayload();
    expect(payload.histograms.map((entry) => entry.name)).not.toContain("main.turn");
    expect(payload.ingest.mismatchedHistograms).toBe(2);
  });

  test("answers 400 for a bad shape", async () => {
    const shapes: Array<(report: ReturnType<typeof schema3Report>) => void> = [
      (report) => { report.histograms.push(histogram("Key.Frame")); },
      (report) => { report.histograms.push(histogram("a".repeat(65))); },
      (report) => { report.histograms.push(histogram("key-frame")); },
      (report) => { report.histograms[0]!.unit = "seconds"; },
      (report) => { report.histograms[0]!.buckets = [[24, 1], [20, 3]]; },
      (report) => { report.histograms[0]!.buckets = [[20, 1], [20, 3]]; },
      (report) => { report.histograms[0]!.count = 1; },
      (report) => { report.histograms[0]!.buckets = [[20, -1]]; },
      (report) => { report.histograms[0]!.buckets = Array.from({ length: MAX_HISTOGRAM_BUCKETS + 1 }, (_, index) => [index, 1]); report.histograms[0]!.count = 100; },
      (report) => { report.histograms = Array.from({ length: MAX_HISTOGRAMS + 1 }, () => histogram("main.turn")); },
      (report) => { (report.histograms[0] as Record<string, unknown>).extra = 1; },
      (report) => { report.stability["Stability.Launch"] = 1; },
      (report) => { report.stability["stability.launch"] = 1.5; },
      (report) => { report.blackbox.push({ process: "kernel", name: "main.turn", atUs: 1 }); },
      (report) => { report.blackbox.push({ process: "app", name: "main.turn", atUs: 1, text: "hello" }); },
      (report) => { report.blackbox = Array.from({ length: MAX_BLACKBOX_EVENTS + 1 }, () => ({ process: "app", name: "main.turn", atUs: 1 })); },
      (report) => { delete (report as Record<string, unknown>).catalogVersion; },
      (report) => { report.launches[0]!.app = { version: "0.70.9", build: "70901", channel: "beta" }; },
    ];
    for (const [index, mutate] of shapes.entries()) {
      const report = { ...schema3Report(), reportId: crypto.randomUUID() };
      mutate(report);
      const response = await POST(reportRequest(report));
      expect({ index, status: response.status }).toEqual({ index, status: 400 });
    }
    expect(repository.rows.size).toBe(0);
  });

  test("refuses a key-category record in the black box", async () => {
    for (const name of ["key.frame", "key.echo.host_pty_read", "key"]) {
      const report = { ...schema3Report(), reportId: crypto.randomUUID() };
      report.blackbox.push({ process: "host", name, atUs: 10 });
      const response = await POST(reportRequest(report));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_report", reason: "blackbox_key_record" });
    }
    expect(repository.rows.size).toBe(0);
  });

  test("schema 3 fields on a schema 2 report are a bad shape", async () => {
    const report = { ...schema3Report(), schema: 2 };
    expect((await POST(reportRequest(report))).status).toBe(400);
  });

  test("scans earlier launches for leaks but not their four-part versions", async () => {
    const versions = schema3Report();
    versions.launches[0]!.app = { version: "1.2.3.4", build: "1.2.3.4", channel: "nightly" };
    expect((await POST(reportRequest(versions))).status).toBe(204);
    const leak = { ...schema3Report(), reportId: crypto.randomUUID() };
    leak.stability["stability.a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7"] = 1;
    expect((await POST(reportRequest(leak))).status).toBe(400);
  });

  test("answers 413 for a schema 3 body over 64 KiB", async () => {
    const report = schema3Report();
    report.blackbox = Array.from({ length: MAX_BLACKBOX_EVENTS }, (_, index) => ({
      process: "app",
      name: "frame.commit.with_a_long_catalog_name_for_padding_only",
      atUs: index,
      durUs: 1_000_000 + index,
      value: 9_007_199_254_740 + index,
    }));
    const body = JSON.stringify(report);
    expect(body.length).toBeGreaterThan(64 * 1024);
    const response = await POST(reportRequest(body));
    expect(response.status).toBe(413);
    expect(repository.rows.size).toBe(0);
  });
});

describe("histogram catalog", () => {
  test("has the families the program records and Chromium's own names", () => {
    for (const name of [
      "key.frame.view", "key.echo_frame.cloud", "input.frame.ime_commit", "main.congestion.queue.steady",
      "hang.thread_hung.chromium_host_main", "action.cmd_t", "action.missed_frames.cmd_w", "launch.first_frame.cold",
      "memory.renderer_kib", "cpu.gpu_pct", "webview.inp.home", "daemon.request.terminal_io",
      "stability.child_exit.webkit", "chromium.Stability.Counts2", "blocking.violations",
    ]) expect(HISTOGRAM_CATALOG.has(name)).toBe(true);
    for (const name of HISTOGRAM_CATALOG.keys()) expect(name.length).toBeLessThanOrEqual(64);
  });

  test("log-linear buckets have 4 sub-buckets per power of two and end in an overflow bucket", () => {
    const layout = { kind: "logLinear", maximum: 1_000_000 } as const;
    expect(bucketRange(layout, 0)).toEqual({ low: 0, high: 1 });
    expect(bucketRange(layout, 1)).toEqual({ low: 1, high: 1.25 });
    expect(bucketRange(layout, 5)).toEqual({ low: 2, high: 2.5 });
    expect(bucketRange(layout, 8)).toEqual({ low: 3.5, high: 4 });
    const last = maxBucketIndex(layout)!;
    expect(bucketRange(layout, last - 1)!.high).toBeGreaterThanOrEqual(1_000_000);
    expect(bucketRange(layout, last)!.high).toBe(Infinity);
    expect(bucketRange(layout, last + 1)).toBeNull();
    expect(bucketRange({ kind: "chromium" }, 0)).toBeNull();
  });
});
