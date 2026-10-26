import { beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import * as Effect from "effect/Effect";

import { makeHangReportsHandler } from "../app/api/hang-reports/route";
import {
  bucketCount,
  bucketRange,
  histogramCatalog,
  logLinearIndex,
} from "../services/hangReports/histogramCatalog";
import { HangReportsRepository, type HangReportRow, type HangReportsRepositoryShape } from "../services/hangReports/repository";
import { droppedTotals, mergeFieldHistograms, percentile, type StoredFieldReport } from "../scripts/hang-reports/histograms";

const NOW = new Date("2026-10-23T15:30:00Z");
const REPORT_ID = "7a2e4c1d-3b5f-4e6a-8c9d-1f2e3d4c5b6a";

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

type Mutable = Record<string, unknown> & {
  histograms: Array<{ name: string; buckets: number[][] }>;
  stability: Record<string, number>;
  blackbox: Array<Record<string, unknown>>;
  sections: Array<{ histograms: Array<{ name: string; buckets: number[][] }>; stability: Record<string, number> }>;
};

function fixture(): Mutable {
  return JSON.parse(readFileSync(new URL("./fixtures/hang-report-schema3.json", import.meta.url), "utf8")) as Mutable;
}

function request(body: unknown): Request {
  return new Request("https://cmux.test/api/hang-reports", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function storedPayload(): Record<string, unknown> | undefined {
  return repository.rows.get(REPORT_ID)?.payload;
}

describe("POST /api/hang-reports schema 3", () => {
  test("answers 204 for the golden schema 3 fixture and stores its field data", async () => {
    const body = readFileSync(new URL("./fixtures/hang-report-schema3.json", import.meta.url), "utf8");
    const response = await POST(request(body));
    expect(response.status).toBe(204);
    const payload = storedPayload();
    expect(payload).toMatchObject({
      schema: 3,
      catalog_version: 1,
      active_seconds: 5400,
      dropped: { histograms: 0, stability: 0, blackbox: 0 },
    });
    expect((payload?.histograms as unknown[]).length).toBe(4);
    expect((payload?.blackbox as unknown[]).length).toBe(3);
    expect((payload?.sections as Array<{ profile: unknown }>)[0]?.profile).toEqual({
      app: { build: "2123456789011", channel: "nightly", version: "0.69.9" },
      os: { version: "15.7.4" },
    });
    expect((payload?.launches as { completionReasons: unknown[] }).completionReasons.length).toBe(2);
    expect((payload?.intervals as Array<{ category: string }>).map((interval) => interval.category)).toContain("main");
  });

  test("answers 204 and drops and counts unknown histogram names and stability keys", async () => {
    const report = fixture();
    report.histograms.push({ name: "key.frame.future_target", buckets: [[44, 3]] });
    report.stability["child_exit.future_kind.clean"] = 2;
    report.sections[0]!.histograms.push({ name: "brand.new.histogram", buckets: [[9999, 1]] });
    const response = await POST(request(report));
    expect(response.status).toBe(204);
    const payload = storedPayload();
    expect(payload?.dropped).toEqual({ histograms: 2, stability: 1, blackbox: 0 });
    const names = (payload?.histograms as Array<{ name: string }>).map((histogram) => histogram.name);
    expect(names).not.toContain("key.frame.future_target");
    expect(Object.keys(payload?.stability as object)).not.toContain("child_exit.future_kind.clean");
    expect(JSON.stringify(payload)).not.toContain("brand.new.histogram");
  });

  test("drops key, PTY, per-input and flow records from the black box and counts them", async () => {
    const report = fixture();
    const planted = [
      { name: "key.down", phase: "I" },
      { name: "holder.pty.read", phase: "I" },
      { name: "remote.input", phase: "I" },
      { name: "action.dispatch", phase: "s" },
    ];
    for (const event of planted) report.blackbox.push({ arg0: 1, arg1: 2, process: "app", t_ns: 5, ...event });
    expect((await POST(request(report))).status).toBe(204);
    const payload = storedPayload();
    expect(payload?.dropped).toMatchObject({ blackbox: 4 });
    expect((payload?.blackbox as unknown[]).length).toBe(3);
    expect(JSON.stringify(payload?.blackbox)).not.toContain("key.down");
  });

  test("answers 400 for a bad shape", async () => {
    const cases: Array<(report: Mutable) => void> = [
      (report) => { report.histograms[0]!.name = "Key.Frame.View"; },
      (report) => { report.histograms[0]!.name = "chromium.Made.Up.Histogram"; },
      (report) => { report.histograms[0]!.name = "x".repeat(65); },
      (report) => { report.histograms[0]!.buckets = [[45, 1], [44, 1]]; },
      (report) => { report.histograms[0]!.buckets = [[44, 1, 3]]; },
      (report) => { report.histograms[0]!.buckets = [[5, 1]]; },
      (report) => { report.histograms[1]!.buckets = [[102, 1]]; },
      (report) => { report.histograms[2]!.buckets = [[5, 1]]; },
      (report) => { report.histograms.push({ ...report.histograms[0]! }); },
      (report) => { report.histograms[0]!.buckets = Array.from({ length: 25 }, (_, index) => [8 + index, 1]); },
      (report) => { report.stability["Launch"] = 1; },
      (report) => { report.stability.launch = -1; },
      (report) => { report.blackbox[0]!.process = "renderer"; },
      (report) => { report.blackbox[0]!.arg0 = 2 ** 60; },
      (report) => { report.blackbox[0]!.name = "/Users/alice"; },
      (report) => { delete report.catalog_version; },
      (report) => { report.catalog_version = 0; },
      (report) => { report.extra = true; },
      (report) => { report.sections[0]!.stability = { "launch": 1.5 }; },
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

  test("names the bucket reason for a catalog histogram with a bucket its layout cannot hold", async () => {
    const report = fixture();
    report.histograms[0]!.buckets = [[200, 1]];
    const response = await POST(request(report));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_report", reason: "histogram_bucket" });
  });

  test("answers 413 for a schema 3 body over 64 KiB", async () => {
    const report = fixture();
    report.blackbox = Array.from({ length: 512 }, (_, index) => ({
      arg0: Number.MAX_SAFE_INTEGER, arg1: Number.MAX_SAFE_INTEGER, name: "action.dispatch.with_a_long_catalog_name",
      phase: "I", process: "chromium-host", t_ns: Number.MAX_SAFE_INTEGER - index,
    }));
    const response = await POST(request(report));
    expect(response.status).toBe(413);
    expect(repository.rows.size).toBe(0);
  });

  test("still answers 204 for schema 2 and refuses schema 3 keys in a schema 2 body", async () => {
    const schema2 = readFileSync(new URL("./fixtures/hang-report-schema2.json", import.meta.url), "utf8");
    expect((await POST(request(schema2))).status).toBe(204);
    expect(repository.rows.get("5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11")?.payload.dropped).toBeUndefined();
    const mixed = { ...JSON.parse(schema2), reportId: crypto.randomUUID(), catalog_version: 1 };
    expect((await POST(request(mixed))).status).toBe(400);
    const mainInterval = JSON.parse(schema2) as { intervals: Array<{ category: string }>; reportId: string };
    mainInterval.reportId = crypto.randomUUID();
    mainInterval.intervals[0]!.category = "main";
    expect((await POST(request(mainInterval))).status).toBe(400);
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
    for (const name of names) expect(/^[a-z0-9_.]{1,64}$/.test(name) || name.startsWith("chromium.")).toBe(true);
    expect(names).toContain("key.frame.view");
    expect(names).toContain("daemon.request.terminal_io");
    expect(names).toContain("webview.inp.home");
    expect(names).toContain("chromium.EventLatency.KeyPressed.TotalLatency");
  });
});

describe("hang report histogram merge", () => {
  const stored = (installId: string, day: string, payload: StoredFieldReport["payload"]): StoredFieldReport =>
    ({ installId, receivedDay: day, appVersion: payload.app?.version ?? null, payload });

  test("sums buckets per name, version and day, sections under their own version", () => {
    const reports = [
      stored("a", "2026-10-22", {
        schema: 3, app: { version: "0.70.0" },
        histograms: [{ name: "key.frame.view", buckets: [[40, 90], [48, 10]] }],
        sections: [{ profile: { app: { version: "0.69.9" } }, histograms: [{ name: "key.frame.view", buckets: [[44, 5]] }] }],
        dropped: { histograms: 2, stability: 1, blackbox: 0 },
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
    expect(droppedTotals(reports)).toEqual({ histograms: 2, stability: 1, blackbox: 0 });
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
