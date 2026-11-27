import { afterAll, afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import type { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";

import { makeHangReportsHandler } from "../app/api/hang-reports/route";
import { makeHangReportsRetentionHandler } from "../app/api/cron/hang-reports-retention/route";
import { storageUnavailable, type HangReportFailureContext } from "../services/hangReports/errors";
import { HANG_REPORTS_PER_INSTALL_PER_DAY } from "../services/hangReports/ingest";
import { scanForLeaks } from "../services/hangReports/leakScan";
import {
  storage,
  HangReportsRepository,
  type HangReportRow,
  type HangReportsRepositoryShape,
} from "../services/hangReports/repository";
import { RETENTION_BATCH_SIZE } from "../services/hangReports/retention";

const NOW = new Date("2026-10-23T15:30:00Z");
const PLANTED_IP = "203.0.113.77";

const originalVercel = process.env.VERCEL;
const originalRuleId = process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID;
const originalCronSecret = process.env.CRON_SECRET;

/** In-memory repository with the Postgres repository's semantics. */
class FakeRepository implements HangReportsRepositoryShape {
  readonly rows = new Map<string, HangReportRow & { receivedAt: Date }>();
  receivedAt = NOW;
  readonly insertWithinDailyCap: HangReportsRepositoryShape["insertWithinDailyCap"] = (row, dailyCap) =>
    Effect.sync(() => {
      if (this.rows.has(row.reportId)) return "duplicate" as const;
      const stored = [...this.rows.values()]
        .filter((existing) => existing.installId === row.installId && existing.receivedDay === row.receivedDay).length;
      if (stored >= dailyCap) return "capped" as const;
      this.rows.set(row.reportId, { ...row, receivedAt: this.receivedAt });
      return "inserted" as const;
    });
  readonly deleteReceivedBefore: HangReportsRepositoryShape["deleteReceivedBefore"] = (cutoff, limit) =>
    Effect.sync(() => {
      const expired = [...this.rows.values()]
        .filter((row) => row.receivedAt < cutoff)
        .sort((a, b) => a.receivedAt.getTime() - b.receivedAt.getTime())
        .slice(0, limit);
      for (const row of expired) this.rows.delete(row.reportId);
      return expired.length;
    });
}

let repository = new FakeRepository();
let rateLimitResult: Awaited<ReturnType<typeof checkVercelRateLimit>> = { rateLimited: false };
const rateLimitCalls: string[] = [];
const missingRuleReports: Array<{ readonly route: string; readonly reason: string }> = [];
const reportedFailures: HangReportFailureContext[] = [];

const checkRateLimit: typeof checkVercelRateLimit = async (ruleId) => {
  rateLimitCalls.push(ruleId);
  return rateLimitResult;
};

const POST = makeHangReportsHandler({
  checkRateLimit,
  reportMissingRateLimitRule: (input) => { missingRuleReports.push(input); },
  run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, repository))),
  reportFailure: (context) => { reportedFailures.push(context); },
  now: () => NOW,
});

beforeEach(() => {
  delete process.env.VERCEL;
  process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID = "hang-reports-test";
  repository = new FakeRepository();
  rateLimitResult = { rateLimited: false };
  rateLimitCalls.length = 0;
  missingRuleReports.length = 0;
  reportedFailures.length = 0;
});

afterAll(() => {
  restoreEnv("VERCEL", originalVercel);
  restoreEnv("CMUX_HANG_REPORTS_RATE_LIMIT_ID", originalRuleId);
  restoreEnv("CRON_SECRET", originalCronSecret);
});

describe("POST /api/hang-reports", () => {
  test("stores a realistic schema 2 report and answers 204", async () => {
    const response = await POST(reportRequest(realisticReport()));
    expect(response.status).toBe(204);
    expect(response.headers.get("cache-control")).toBe("no-store");
    const row = repository.rows.get("5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11");
    expect(row).toMatchObject({
      installId: "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20",
      receivedDay: "2026-10-23",
      appVersion: "0.70.0-nightly.2123456789012",
      appBuild: "2123456789012",
      channel: "nightly",
      osVersion: "15.7.4",
      arch: "arm64",
      chip: "Apple M4 Pro",
      cores: 14,
      memoryGb: 48,
      counts: { windows: "1", workspaces: "11-30", panes: "6-10", tabs: "31-100" },
    });
    expect((row?.payload.hangs as unknown[]).length).toBe(2);
  });

  test("accepts absent optionals and arrays, the way JSONEncoder omits nil", async () => {
    const minimal = {
      schema: 2,
      reportId: "11111111-2222-4333-8444-555555555555",
      installId: "66666666-7777-4888-9999-AAAAAAAAAAAA",
      day: "2026-10-22",
      app: { version: "0.70.0", build: "70123", channel: "nightly" },
      os: { version: "26.0" },
      hardware: { arch: "arm64", chip: "Apple M1", cores: 8, memoryGB: 16 },
      counts: { windows: "0", workspaces: "0", panes: "0", tabs: "0" },
      hangs: [{ source: "watchdog", kind: "stall", durationMs: 400, frames: [{ image: "other" }, { image: "AppKit", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 12 }] }],
    };
    expect((await POST(reportRequest(minimal))).status).toBe(204);
    const row = repository.rows.get("11111111-2222-4333-8444-555555555555");
    expect(row?.installId).toBe("66666666-7777-4888-9999-aaaaaaaaaaaa");
    expect(row?.payload.intervals).toEqual([]);
  });

  test("accepts the Swift client's version, build and macOS forms, and arch other", async () => {
    const cases = [
      { version: "0.70.0", build: "70123", os: "15.7.4", arch: "arm64" },
      { version: "0", build: "0", os: "0", arch: "other" },
      { version: "1.2.3.4", build: "1.2.3.4", os: "26.0.1.2", arch: "x86_64" },
    ];
    for (const value of cases) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      report.app = { ...report.app, version: value.version, build: value.build };
      report.os = { version: value.os };
      report.hardware = { ...report.hardware, arch: value.arch, chip: "Intel" };
      expect((await POST(reportRequest(report))).status).toBe(204);
    }
    for (const bad of [{ version: "0.70.0.1.2" }, { build: "70123a" }, { os: "15.7.4-beta" }, { arch: "arm64e" }]) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      if (bad.version) report.app = { ...report.app, version: bad.version };
      if (bad.build) report.app = { ...report.app, build: bad.build };
      if (bad.os) report.os = { version: bad.os };
      if (bad.arch) report.hardware = { ...report.hardware, arch: bad.arch };
      expect((await POST(reportRequest(report))).status).toBe(400);
    }
  });

  test("accepts a report with only metrics, and one with every section empty", async () => {
    const base = realisticReport();
    const metricsOnly = {
      ...base,
      reportId: crypto.randomUUID(),
      hangs: [],
      cpuExceptions: [],
      intervals: [],
      stallHistogram: [],
    };
    expect((await POST(reportRequest(metricsOnly))).status).toBe(204);
    const empty: Record<string, unknown> = { ...base, reportId: crypto.randomUUID() };
    for (const key of ["hangs", "cpuExceptions", "intervals", "stallHistogram", "metrics"]) delete empty[key];
    expect((await POST(reportRequest(empty))).status).toBe(204);
    expect(repository.rows.size).toBe(2);
  });

  test("rejects an unknown key at any depth", async () => {
    const top = { ...realisticReport(), extra: true };
    expect((await POST(reportRequest(top))).status).toBe(400);
    const nested = realisticReport();
    (nested.hardware as Record<string, unknown>).hostName = "alices-mac";
    expect((await POST(reportRequest(nested))).status).toBe(400);
    expect(repository.rows.size).toBe(0);
  });

  test("rejects a path in an image name", async () => {
    const report = realisticReport();
    report.hangs[0]!.frames[0] = { image: "/Users/alice/x", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 1 };
    const response = await POST(reportRequest(report));
    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain("alice");
  });

  test("refuses schema 1, the format of Nightlies without the review privacy fixes", async () => {
    const old = { ...realisticReport(), schema: 1 };
    const response = await POST(reportRequest(old));
    // 400 is final for the client: it drops the report from its outbox.
    expect(response.status).toBe(400);
    expect(repository.rows.size).toBe(0);
  });

  test("accepts only the chip families and memory sizes the client can send", async () => {
    // A new install id per report: the per-install daily cap (8) must not be what answers.
    for (const chip of ["Apple M1", "Apple M4 Pro", "Apple M2 Max", "Apple M3 Ultra", "Apple M10", "Intel", "other"]) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      report.hardware = { ...report.hardware, chip };
      expect((await POST(reportRequest(report))).status).toBe(204);
    }
    for (const memoryGB of [4, 18, 36, 512]) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      report.hardware = { ...report.hardware, memoryGB };
      expect((await POST(reportRequest(report))).status).toBe(204);
    }
    const stored = repository.rows.size;
    for (const chip of ["Alice Liddell", "alices-macbook-pro", "Apple M4 Pro Max", "Apple M4 pro", "apple m1", "Intel(R) Core(TM) i9", "Other", "Apple M123", " Apple M1"]) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      report.hardware = { ...report.hardware, chip };
      const response = await POST(reportRequest(report));
      expect(response.status).toBe(400);
      expect(await response.text()).not.toContain("Alice");
    }
    for (const memoryGB of [0, 1, 17, 47, 1024, 16_384]) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
      report.hardware = { ...report.hardware, memoryGB };
      expect((await POST(reportRequest(report))).status).toBe(400);
    }
    expect(repository.rows.size).toBe(stored);
  });

  test("rejects an email and a URL", async () => {
    const email = realisticReport();
    email.hardware.chip = "alice@example.com";
    expect((await POST(reportRequest(email))).status).toBe(400);
    const url = realisticReport();
    url.intervals[0]!.name = "https://example.com";
    expect((await POST(reportRequest(url))).status).toBe(400);
    expect(repository.rows.size).toBe(0);
  });

  test("rejects a frame of image other that carries a UUID or offset", async () => {
    const report = realisticReport();
    report.hangs[0]!.frames.push({ image: "other", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 9 });
    expect((await POST(reportRequest(report))).status).toBe(400);
  });

  test("answers 413 for a body over 64 KiB", async () => {
    const report = realisticReport();
    const body = JSON.stringify({ ...report, padding: "x".repeat(70 * 1024) });
    const response = await POST(new Request("https://cmux.test/api/hang-reports", {
      method: "POST",
      headers: { "content-type": "application/json", "content-length": String(body.length) },
      body,
    }));
    expect(response.status).toBe(413);
  });

  test("answers 413 for a streamed body over 64 KiB with no content length", async () => {
    const chunk = new TextEncoder().encode("x".repeat(16 * 1024));
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let index = 0; index < 5; index += 1) controller.enqueue(chunk);
        controller.close();
      },
    });
    const response = await POST(new Request("https://cmux.test/api/hang-reports", { method: "POST", body: stream }));
    expect(response.status).toBe(413);
  });

  test("rejects invalid JSON and a day outside server UTC today-15 ... today+1", async () => {
    const invalid = await POST(new Request("https://cmux.test/api/hang-reports", { method: "POST", body: "{nope" }));
    expect(invalid.status).toBe(400);
    for (const day of ["2026-10-07", "2026-10-25", "2026-02-30", "26-10-23"]) {
      const report = { ...realisticReport(), day };
      expect((await POST(reportRequest(report))).status).toBe(400);
    }
    for (const day of ["2026-10-08", "2026-10-24"]) {
      const report = { ...realisticReport(), day, reportId: crypto.randomUUID() };
      expect((await POST(reportRequest(report))).status).toBe(204);
    }
  });

  test("rejects more than 64 frames, 20 hangs and out-of-bounds numbers", async () => {
    const frames = realisticReport();
    frames.hangs[0]!.frames = Array.from({ length: 65 }, () => ({ image: "AppKit", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 1 }));
    expect((await POST(reportRequest(frames))).status).toBe(400);
    const hangs = realisticReport();
    hangs.hangs = Array.from({ length: 21 }, () => hangs.hangs[1]!);
    expect((await POST(reportRequest(hangs))).status).toBe(400);
    const duration = realisticReport();
    duration.hangs[0]!.durationMs = 86_400_001;
    expect((await POST(reportRequest(duration))).status).toBe(400);
    const bucket = realisticReport();
    bucket.counts.tabs = "12";
    expect((await POST(reportRequest(bucket))).status).toBe(400);
    expect(repository.rows.size).toBe(0);
  });

  test("stores a duplicate reportId once and still answers 204", async () => {
    expect((await POST(reportRequest(realisticReport()))).status).toBe(204);
    expect((await POST(reportRequest(realisticReport()))).status).toBe(204);
    expect(repository.rows.size).toBe(1);
  });

  test("caps one install at 8 reports per server UTC day", async () => {
    // One install id (realisticReport's) for every report: the cap is per install.
    for (let index = 0; index < HANG_REPORTS_PER_INSTALL_PER_DAY; index += 1) {
      const report = { ...realisticReport(), reportId: crypto.randomUUID() };
      expect((await POST(reportRequest(report))).status).toBe(204);
    }
    const capped = await POST(reportRequest({ ...realisticReport(), reportId: crypto.randomUUID() }));
    expect(capped.status).toBe(429);
    expect(Number(capped.headers.get("retry-after"))).toBeGreaterThanOrEqual(60);
    expect(repository.rows.size).toBe(HANG_REPORTS_PER_INSTALL_PER_DAY);
    // Another install is not affected.
    const other = { ...realisticReport(), reportId: crypto.randomUUID(), installId: crypto.randomUUID() };
    expect((await POST(reportRequest(other))).status).toBe(204);
  });

  test("answers 429 with retry-after 60 when the Vercel firewall limits the client", async () => {
    process.env.VERCEL = "1";
    rateLimitResult = { rateLimited: true };
    const response = await POST(reportRequest(realisticReport()));
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
    expect(rateLimitCalls).toEqual(["hang-reports-test"]);
    expect(repository.rows.size).toBe(0);
  });

  test("answers 503 and reports it when the firewall rule is unset or not found on Vercel", async () => {
    process.env.VERCEL = "1";
    delete process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID;
    const unset = await POST(reportRequest(realisticReport()));
    expect(unset.status).toBe(503);
    expect(await unset.json()).toEqual({ error: "rate_limit_unavailable" });
    expect(rateLimitCalls).toEqual([]);

    process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID = "hang-reports-test";
    rateLimitResult = { rateLimited: false, error: "not-found" };
    expect((await POST(reportRequest(realisticReport()))).status).toBe(503);
    expect(missingRuleReports).toEqual([
      { route: "/api/hang-reports", reason: "unset" },
      { route: "/api/hang-reports", reason: "not-found" },
    ]);
    expect(repository.rows.size).toBe(0);
  });

  test("skips the firewall check off Vercel", async () => {
    delete process.env.CMUX_HANG_REPORTS_RATE_LIMIT_ID;
    expect((await POST(reportRequest(realisticReport()))).status).toBe(204);
    expect(missingRuleReports).toEqual([]);
  });

  test("answers 503 for a storage failure and 500 for a defect, without echoing the body", async () => {
    const handlerWith = (insertWithinDailyCap: HangReportsRepositoryShape["insertWithinDailyCap"]) => makeHangReportsHandler({
      checkRateLimit,
      reportMissingRateLimitRule: () => {},
      run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, {
        insertWithinDailyCap,
        deleteReceivedBefore: () => Effect.succeed(0),
      }))),
      reportFailure: (context) => { reportedFailures.push(context); },
      now: () => NOW,
    });
    const unavailable = await handlerWith(() =>
      Effect.fail(storageUnavailable("insert", new Error("connection reset"))),
    )(reportRequest(realisticReport()));
    expect(unavailable.status).toBe(503);
    expect(await unavailable.text()).toBe(JSON.stringify({ error: "storage_unavailable" }));

    const defect = await handlerWith(() => Effect.die(new Error("bug")))(reportRequest(realisticReport()));
    expect(defect.status).toBe(500);
    expect(await defect.text()).toBe(JSON.stringify({ error: "internal_error" }));
    expect(reportedFailures).toEqual([
      { operation: "insert", tag: "Error", sqlstate: null },
      { operation: "defect", tag: "Error", sqlstate: null },
    ]);
  });

  test("reports a storage failure as operation, tag and SQLSTATE only, never the query parameters", async () => {
    const installId = "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20";
    // The shape drizzle's EffectDrizzleQueryError has: the message and fields
    // carry every parameter, and the driver error below it has the SQLSTATE.
    const queryError = Object.assign(new Error(`Failed query: insert into "hang_reports"\nparams: ${installId},{"schema":1}`), {
      _tag: "EffectDrizzleQueryError",
      query: 'insert into "hang_reports"',
      params: [installId, '{"schema":1}'],
      cause: Object.assign(new Error(`duplicate key ${installId}`), { code: "53300" }),
    });
    const handler = makeHangReportsHandler({
      checkRateLimit,
      reportMissingRateLimitRule: () => {},
      run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, {
        insertWithinDailyCap: () => storage("insert", () => Effect.fail(queryError)),
        deleteReceivedBefore: () => Effect.succeed(0),
      }))),
      reportFailure: (context) => { reportedFailures.push(context); },
      now: () => NOW,
    });
    const logged: unknown[] = [];
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((method) =>
      spyOn(console, method).mockImplementation((...args: unknown[]) => { logged.push(args); }));
    let response: Response;
    try {
      response = await handler(reportRequest(realisticReport()));
    } finally {
      for (const spy of consoleSpies) spy.mockRestore();
    }
    expect(response.status).toBe(503);
    expect(reportedFailures).toEqual([{ operation: "insert", tag: "EffectDrizzleQueryError", sqlstate: "53300" }]);
    expect(JSON.stringify(reportedFailures).toLowerCase()).not.toContain(installId);
    expect(JSON.stringify(logged).toLowerCase()).not.toContain(installId);
    expect((await response.text()).toLowerCase()).not.toContain(installId);
  });

  test("stores the golden schema 2 fixture the Swift client round-trips", async () => {
    const fixture = readFileSync(new URL("./fixtures/hang-report-schema2.json", import.meta.url), "utf8");
    const body = fixture.replace('"day":"2026-10-23"', `"day":"${NOW.toISOString().slice(0, 10)}"`);
    const response = await POST(new Request("https://cmux.test/api/hang-reports", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    }));
    expect(response.status).toBe(204);
    const row = repository.rows.get("5f1c7c1e-2b9b-4a8e-9c62-0f0d2b0b8a11");
    expect(row).toMatchObject({ appBuild: "2123456789012", channel: "nightly", chip: "Apple M4 Pro" });
    expect((row?.payload.intervals as Array<{ category: string }>)[0]?.category).toBe("motion");
  });

  test("never reads a client address header or the user agent, and never stores or logs one", async () => {
    process.env.VERCEL = "1";
    const request = reportRequest(realisticReport(), {
      "x-forwarded-for": PLANTED_IP,
      "x-real-ip": PLANTED_IP,
      "x-vercel-forwarded-for": PLANTED_IP,
      "cf-connecting-ip": PLANTED_IP,
      forwarded: `for=${PLANTED_IP}`,
      "user-agent": "cmux-hang-reports/1",
    });
    const readHeaders: string[] = [];
    const headers = request.headers;
    const get = headers.get.bind(headers);
    const has = headers.has.bind(headers);
    spyOn(headers, "get").mockImplementation((name: string) => { readHeaders.push(name.toLowerCase()); return get(name); });
    spyOn(headers, "has").mockImplementation((name: string) => { readHeaders.push(name.toLowerCase()); return has(name); });
    const iterated = [
      spyOn(headers, "entries"),
      spyOn(headers, "forEach"),
      spyOn(headers, "keys"),
      spyOn(headers, "values"),
    ];
    const logged: unknown[] = [];
    const consoleSpies = (["log", "info", "warn", "error", "debug"] as const).map((method) =>
      spyOn(console, method).mockImplementation((...args: unknown[]) => { logged.push(args); }));
    try {
      expect((await POST(request)).status).toBe(204);
    } finally {
      for (const spy of consoleSpies) spy.mockRestore();
    }
    const addressHeaders = ["x-forwarded-for", "x-real-ip", "x-vercel-forwarded-for", "cf-connecting-ip", "forwarded", "user-agent"];
    // The spy sees header reads: the bounded body read checks content-length.
    expect(readHeaders).toContain("content-length");
    expect(readHeaders.filter((name) => addressHeaders.includes(name))).toEqual([]);
    for (const spy of iterated) expect(spy).not.toHaveBeenCalled();
    expect(JSON.stringify([...repository.rows.values()])).not.toContain(PLANTED_IP);
    expect(JSON.stringify(logged)).not.toContain(PLANTED_IP);
    expect(JSON.stringify(reportedFailures)).not.toContain(PLANTED_IP);
  });
});

describe("hang report leak scan", () => {
  test("finds each planted shape and passes realistic values", () => {
    expect(scanForLeaks(realisticReport())).toBeNull();
    expect(scanForLeaks({ a: ["LocalAuthenticationEmbeddedUI", "GenerativeModelsFoundation"] })).toBeNull();
    expect(scanForLeaks({ a: "~/Library/Input Methods" })).toBe("path");
    expect(scanForLeaks({ a: "bob@example.com" })).toBe("email");
    expect(scanForLeaks({ a: "ssh://host" })).toBe("url");
    expect(scanForLeaks({ a: "10.0.0.12" })).toBe("ip_address");
    expect(scanForLeaks({ a: "fe80::1" })).toBe("ip_address");
    expect(scanForLeaks({ a: "0123456789abcdef0123456789abcdef" })).toBe("token");
    expect(scanForLeaks({ a: "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6" })).toBe("token");
    // Same threshold as the Swift client: 31 mixed characters, or 40 letters only, pass.
    expect(scanForLeaks({ a: "0123456789abcdef0123456789abcde" })).toBeNull();
    expect(scanForLeaks({ a: "abcdefghijabcdefghijabcdefghijabcdefghij" })).toBeNull();
    expect(scanForLeaks({ a: "8B1E5C0A-1D4F-3B2E-A6C7-9F8E7D6C5B4A" })).toBeNull();
  });
});

describe("GET /api/cron/hang-reports-retention", () => {
  test("requires the cron secret and deletes rows older than 90 days in batches", async () => {
    process.env.CRON_SECRET = "cron-secret";
    const handler = makeHangReportsRetentionHandler({
      run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, repository))),
      now: () => NOW,
      reportFailure: (context) => { reportedFailures.push(context); },
    });
    const old = new Date(NOW.getTime() - 91 * 86_400_000);
    const recent = new Date(NOW.getTime() - 89 * 86_400_000);
    for (let index = 0; index < RETENTION_BATCH_SIZE + 5; index += 1) {
      repository.rows.set(`old-${index}`, { ...rowStub(`old-${index}`), receivedAt: old });
    }
    repository.rows.set("recent", { ...rowStub("recent"), receivedAt: recent });

    const unauthorized = await handler(new Request("https://cmux.test/api/cron/hang-reports-retention"));
    expect(unauthorized.status).toBe(401);
    expect(repository.rows.size).toBe(RETENTION_BATCH_SIZE + 6);

    const response = await handler(new Request("https://cmux.test/api/cron/hang-reports-retention", {
      headers: { authorization: "Bearer cron-secret" },
    }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, deleted: RETENTION_BATCH_SIZE + 5, complete: true });
    expect([...repository.rows.keys()]).toEqual(["recent"]);
  });

  test("reports a failed run as operation, tag and SQLSTATE only", async () => {
    process.env.CRON_SECRET = "cron-secret";
    const installId = "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20";
    const handler = makeHangReportsRetentionHandler({
      run: (program) => Effect.runPromiseExit(program.pipe(Effect.provideService(HangReportsRepository, {
        insertWithinDailyCap: () => Effect.succeed("inserted"),
        deleteReceivedBefore: () => storage("deleteReceivedBefore", () =>
          Effect.fail(Object.assign(new Error(`params: ${installId}`), { code: "57014" }))),
      }))),
      now: () => NOW,
      reportFailure: (context) => { reportedFailures.push(context); },
    });
    const response = await handler(new Request("https://cmux.test/api/cron/hang-reports-retention", {
      headers: { authorization: "Bearer cron-secret" },
    }));
    expect(response.status).toBe(500);
    expect(reportedFailures).toEqual([{ operation: "deleteReceivedBefore", tag: "Error", sqlstate: "57014" }]);
  });
});

afterEach(() => {
  delete process.env.VERCEL;
});

function rowStub(reportId: string): HangReportRow {
  return {
    reportId,
    installId: "0b8d4a51-6c9e-4f0f-8f53-3c2d7b4f9e20",
    receivedDay: "2026-07-01",
    appVersion: "0.70.0",
    appBuild: "70123",
    channel: "nightly",
    osVersion: "15.7.4",
    arch: "arm64",
    chip: "Apple M4 Pro",
    cores: 14,
    memoryGb: 48,
    counts: {},
    payload: {},
  };
}

function reportRequest(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://cmux.test/api/hang-reports", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function realisticReport() {
  return {
    schema: 2 as const,
    reportId: "5F1C7C1E-2B9B-4A8E-9C62-0F0D2B0B8A11",
    installId: "0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20",
    day: "2026-10-23",
    app: { version: "0.70.0-nightly.2123456789012", build: "2123456789012", channel: "nightly" },
    os: { version: "15.7.4" },
    hardware: { arch: "arm64", chip: "Apple M4 Pro", cores: 14, memoryGB: 48 },
    counts: { windows: "1", workspaces: "11-30", panes: "6-10", tabs: "31-100" },
    hangs: [
      {
        source: "metrickit",
        kind: "hang",
        durationMs: 2340,
        cpuMs: null as number | null,
        frames: [
          { image: "libsystem_kernel.dylib", uuid: "A1B2C3D4-0000-1111-2222-333344445555", offset: 4_660 },
          { image: "CoreFoundation", uuid: "B1B2C3D4-0000-1111-2222-333344445555", offset: 512_000 },
          { image: "cmux NEXT", uuid: "C1B2C3D4-0000-1111-2222-333344445555", offset: 1_234_567 },
          { image: "other" },
          { image: "Chromium Embedded Framework", uuid: "D1B2C3D4-0000-1111-2222-333344445555", offset: 99_000_123 },
        ] as Array<{ image: string; uuid?: string; offset?: number }>,
      },
      {
        source: "watchdog",
        kind: "stall",
        durationMs: 480,
        frames: [
          { image: "AppKit", uuid: "8B1E0C5A-1111-2222-3333-444455556666", offset: 1_234 },
          { image: "GhosttyKit", uuid: "E1B2C3D4-0000-1111-2222-333344445555", offset: 77 },
        ] as Array<{ image: string; uuid?: string; offset?: number }>,
      },
    ],
    cpuExceptions: [{ cpuMs: 90_000, sampledMs: 180_000, frames: [] }],
    stallHistogram: [{ lowMs: 50, highMs: 100, count: 12 }, { lowMs: 100, highMs: 250, count: 3 }],
    metrics: {
      hangTime: [{ lowMs: 0, highMs: 100, count: 40 }],
      launchFirstDraw: [],
      launchResume: [],
      launchOptimizedFirstDraw: [],
      launchExtended: [],
      scrollHitchMsPerS: 1.5,
      hitchMsPerS: null,
    },
    intervals: [
      { category: "motion", name: "motion.frame", count: 1200, buckets: [{ lowMs: 0, highMs: 10, count: 1100 }], hitchMsPerS: 0.4 },
    ],
  };
}

function restoreEnv(name: string, value: string | undefined): void {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}
