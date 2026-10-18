import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PNG } from "pngjs";
import { captureReceipt, deleteLedgerIds, diffPng, parseManifest, pauseLedgerIds, renderIndex, scenarioFingerprint, settleSummary, shardCases, undeletedLedgerIds, withTimeout, writeLedger } from "./runner";

test("summarizes settled interaction latency and ignores missing samples", () => {
  expect(settleSummary([30, 10, 20, null, "slow", Number.NaN])).toEqual({ count: 3, p50: 20, p95: 30, max: 30 });
  expect(settleSummary([])).toEqual({ count: 0, p50: 0, p95: 0, max: 0 });
});

test("ordinary matrix cards include settled interaction latency", () => {
  const html = renderIndex([{ id: "case", engine: "chromium", screenshot: "case.png", play: { steps: [{ settleMs: 10 }, { settleMs: 20 }, { settleMs: 30 }] } }]);
  expect(html).toContain('"latency":{"count":3,"p50":20,"p95":30,"max":30}');
  expect(html).toContain("latencyCell");
  expect(html).toContain("playCells(r)");
});

test("matrix index embeds only triage play fields, not raw frame payloads", () => {
  const html = renderIndex([
    {
      id: "large-play",
      engine: "chromium",
      screenshot: "large-play.png",
      params: { entry: "agent-pane.composer" },
      play: {
        status: "pass",
        steps: [{ status: "pass", step: "click", layoutShift: 0, longFrames: [], problems: [], png: "raw-step-image" }],
        rawTrace: "raw-experiment-trace",
      },
    },
  ]);
  expect(html).toContain("large-play.png");
  expect(html).toContain('"step":"click"');
  expect(html).not.toContain("raw-step-image");
  expect(html).not.toContain("raw-experiment-trace");
});

test("matrix index escapes untrusted card text and play details", () => {
  const html = renderIndex([
    {
      id: "<img src=x onerror=alert(1)>",
      engine: "chromium",
      screenshot: "capture.png",
      params: { variant: "<script>alert(1)</script>" },
      play: { status: "fail", steps: [{ status: "fail", step: "<b>click</b>", layoutShift: 0, longFrames: [], problems: ["<svg>"] }] },
    },
  ]);
  expect(html).toContain("\\u003cimg src=x onerror=alert(1)>");
  expect(html).toContain("\\u003cscript>alert(1)\\u003c/script>");
  expect(html).not.toContain("<img src=x onerror");
  expect(html).not.toContain("<b>click</b>");
});

test("matrix index exposes receipt metadata and triage state filtering", () => {
  const html = renderIndex(
    [{ id: "broken", engine: "chromium", screenshot: "broken.png", ready: "error" }],
    {
      schemaVersion: 1,
      captureId: "capture-a",
      capturedAt: "2026-10-18T00:00:00.000Z",
      scenario: { count: 1, fingerprint: "0123456789012345678901234567890123456789012345678901234567890123" },
      results: { count: 1, expected: 1, status: "complete" },
      quality: "fail",
      revisions: { shas: ["head-a"], sources: ["src/a.gallery.tsx"] },
    },
  );
  expect(html).toContain('data-capture-id="capture-a"');
  expect(html).toContain('href="receipt.json"');
  expect(html).toContain("src/a.gallery.tsx");
  expect(html).toContain("1/1 results");
  expect(html).toContain("2026-10-18T00:00:00.000Z");
  expect(html).toContain('data-filter="state"');
  expect(html).toContain("play-failed");
});

test("matrix index marks missing revision data as provenance-failed", () => {
  const html = renderIndex([{ id: "unbound", engine: "chromium", screenshot: "unbound.png", ready: "1" }]);
  expect(html).toContain("provenance-failed");
});

test("matrix index marks mixed-head cards as provenance-failed", () => {
  const html = renderIndex(
    [{ id: "mixed", engine: "chromium", screenshot: "mixed.png", ready: "1", revision: { sha: "head-b", source: "src/mixed.gallery.tsx" } }],
    {
      schemaVersion: 1,
      captureId: "capture-mixed",
      capturedAt: "2026-10-18T00:00:00.000Z",
      scenario: { count: 1, fingerprint: "0".repeat(64) },
      results: { count: 1, expected: 1, status: "complete" },
      quality: "fail",
      revisions: { shas: ["head-a"], sources: ["src/mixed.gallery.tsx"] },
    },
  );
  expect(html).toContain("provenance-failed");
});

test("matrix index marks mixed-source cards as provenance-failed", () => {
  const html = renderIndex(
    [{ id: "mixed-source", engine: "chromium", screenshot: "mixed.png", ready: "1", revision: { sha: "head-a", source: "src/other.gallery.tsx" } }],
    {
      schemaVersion: 1,
      captureId: "capture-source",
      capturedAt: "2026-10-18T00:00:00.000Z",
      scenario: { count: 1, fingerprint: "0".repeat(64) },
      results: { count: 1, expected: 1, status: "complete" },
      quality: "fail",
      revisions: { shas: ["head-a"], sources: ["src/expected.gallery.tsx"] },
    },
  );
  expect(html).toContain("provenance-failed");
});

test("matrix index exposes free-text triage search", () => {
  const html = renderIndex([{ id: "composer", engine: "chromium", screenshot: "composer.png", ready: "1" }]);
  expect(html).toContain('id="search"');
  expect(html).toContain("JSON.stringify({id:r.id,params:r.params,source:r.revision?.source})");
});

test("matrix index pages large result sets instead of mounting every card", () => {
  const results = Array.from({ length: 49 }, (_, index) => ({
    id: `case-${index}`,
    engine: "chromium",
    screenshot: `${index}.png`,
    ready: "1",
  }));
  const html = renderIndex(results);
  expect(html).toContain("const pageSize=24");
  expect(html).toContain('id="pages"');
  expect(html).toContain('data-page="next"');
});

test("motion review cards include an opt-in video", () => {
  const html = renderIndex([{ id: "motion", engine: "webkit", screenshot: "motion.png", video: "motion.webm" }]);
  expect(html).toContain("r.video");
  expect(html).toContain("motion.webm");
});

test("parses and validates a manifest", () => {
  expect(parseManifest([{ id: "a", path_or_url: "index.html", params: { width: 10, dark: true } }])).toHaveLength(1);
  expect(() => parseManifest([{ id: "a", path_or_url: "x" }, { id: "a", path_or_url: "y" }])).toThrow("duplicate");
  expect(() => parseManifest({})).toThrow("array");
});

test("scenario fingerprints ignore manifest and parameter key order", () => {
  const first = parseManifest([
    { id: "b", path_or_url: "frame.html", params: { variant: "x", entry: "b" } },
    { id: "a", path_or_url: "frame.html", params: { entry: "a", variant: "x" } },
  ]);
  const second = parseManifest([
    { id: "a", path_or_url: "frame.html", params: { variant: "x", entry: "a" } },
    { id: "b", path_or_url: "frame.html", params: { entry: "b", variant: "x" } },
  ]);
  expect(scenarioFingerprint(first)).toBe(scenarioFingerprint(second));
});

test("scenario fingerprints use deterministic code-point ordering", () => {
  const upper = parseManifest([{ id: "Z", path_or_url: "frame.html", params: { b: 1, A: 2 } }]);
  const reordered = parseManifest([{ id: "Z", path_or_url: "frame.html", params: { A: 2, b: 1 } }]);
  expect(scenarioFingerprint(upper)).toBe(scenarioFingerprint(reordered));
});

test("capture receipts bind a run to its scenario and observed revisions", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html", params: { entry: "a", width: 760 } }]);
  const results = [{ id: "a", engine: "chromium", ready: "1", revision: { sha: "head-a", source: "src/a.gallery.tsx" } }];
  const receipt = captureReceipt(cases, results, "capture-a");
  expect(receipt.captureId).toBe("capture-a");
  expect(receipt.scenario).toEqual({ count: 1, fingerprint: scenarioFingerprint(cases) });
  expect(receipt.results).toEqual({ count: 1, expected: 1, status: "complete" });
  expect(receipt.revisions).toEqual({ shas: ["head-a"], sources: ["src/a.gallery.tsx"] });
});

test("capture receipts fail quality when a result lacks revision provenance", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html" }]);
  const receipt = captureReceipt(cases, [{ id: "a", engine: "chromium", ready: "1" }], "missing-revision");
  expect(receipt.results.status).toBe("complete");
  expect(receipt.quality).toBe("fail");
});

test("capture receipts fail quality when results mix checkout heads", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html" }, { id: "b", path_or_url: "frame.html" }]);
  const results = [
    { id: "a", engine: "chromium", ready: "1", revision: { sha: "head-a", source: "src/a.gallery.tsx" } },
    { id: "b", engine: "chromium", ready: "1", revision: { sha: "head-b", source: "src/b.gallery.tsx" } },
  ];
  expect(captureReceipt(cases, results, "mixed-head").quality).toBe("fail");
});

test("capture receipts fail quality when the rendered source differs from the scenario", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html", params: { entry: "a", source: "src/a.gallery.tsx" } }]);
  const results = [{ id: "a", engine: "chromium", ready: "1", params: { entry: "a", source: "src/other.gallery.tsx" }, revision: { sha: "head-a", source: "src/other.gallery.tsx" } }];
  expect(captureReceipt(cases, results, "mismatched-source").quality).toBe("fail");
});

test("capture receipts fail quality when results contain an unknown case", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html" }]);
  const results = [{ id: "unexpected", engine: "chromium", ready: "1", revision: { sha: "head-a", source: "src/a.gallery.tsx" } }];
  expect(captureReceipt(cases, results, "unknown-case").quality).toBe("fail");
});

test("capture receipts fail quality when results contain an unknown engine", () => {
  const cases = parseManifest([{ id: "a", path_or_url: "frame.html" }]);
  const results = [{ id: "a", engine: "unknown-engine", ready: "1", revision: { sha: "head-a", source: "src/a.gallery.tsx" } }];
  expect(captureReceipt(cases, results, "unknown-engine").quality).toBe("fail");
});

test("shards cases deterministically", () => {
  const cases = [0, 1, 2, 3, 4, 5].map((id) => ({ id: String(id), path_or_url: "x" }));
  expect(shardCases(cases, 2, 0).map((item) => item.id)).toEqual(["0", "2", "4"]);
  expect(shardCases(cases, 2, 1).map((item) => item.id)).toEqual(["1", "3", "5"]);
});

test("bounds a renderer operation that stops responding", async () => {
  await expect(withTimeout(new Promise(() => {}), 5, "fixture chromium")).rejects.toThrow("fixture chromium timed out after 5ms");
});

test("computes a pixel diff and threshold percentage", () => {
  const one = new PNG({ width: 2, height: 1 }); one.data.fill(0); one.data[3] = 255;
  const two = new PNG({ width: 2, height: 1 }); two.data.fill(0); two.data[3] = 255; two.data[4] = 255; two.data[7] = 255;
  const diff = diffPng(PNG.sync.write(one), PNG.sync.write(two), 0);
  expect(diff.result.differentPixels).toBeGreaterThan(0);
  expect(diff.result.passed).toBe(false);
  expect(diff.png.length).toBeGreaterThan(0);
});

test("ledger cleanup deletes exact recorded ids without listing", async () => {
  const dir = mkdtempSync(join(process.cwd(), "gallery-ledger-")); const path = join(dir, "ledger.json");
  writeLedger(path, { runId: "test", createdAt: new Date().toISOString(), vmIds: ["vm-exact"], deletedVmIds: [] });
  const deleted: string[] = []; let listed = false;
  await deleteLedgerIds(path, async (id) => { deleted.push(id); });
  expect(deleted).toEqual(["vm-exact"]);
  expect(listed).toBe(false);
  expect(readFileSync(path, "utf8")).toContain("vm-exact");
  rmSync(dir, { recursive: true, force: true });
});

test("an earlier run's undeleted ids block a new run until cleanup", async () => {
  const dir = mkdtempSync(join(process.cwd(), "gallery-ledger-")); const path = join(dir, "ledger.json");
  expect(undeletedLedgerIds(path)).toEqual([]);
  writeLedger(path, { runId: "old", createdAt: new Date().toISOString(), vmIds: ["vm-a", "vm-b"], deletedVmIds: ["vm-a"] });
  expect(undeletedLedgerIds(path)).toEqual(["vm-b"]);
  await deleteLedgerIds(path, async () => {});
  expect(undeletedLedgerIds(path)).toEqual([]);
  rmSync(dir, { recursive: true, force: true });
});

test("pausing touches only the ledger's own unsettled ids, each once", async () => {
  const dir = mkdtempSync(join(process.cwd(), "gallery-ledger-")); const path = join(dir, "ledger.json");
  writeLedger(path, { runId: "r", createdAt: new Date().toISOString(), vmIds: ["vm-1", "vm-2", "vm-3"], pausedVmIds: ["vm-1"], deletedVmIds: ["vm-3"] });
  const paused: string[] = [];
  await pauseLedgerIds(path, async (id) => { paused.push(id); });
  await pauseLedgerIds(path, async (id) => { paused.push(id); });
  expect(paused).toEqual(["vm-2"]);
  expect(undeletedLedgerIds(path)).toEqual([]);
  rmSync(dir, { recursive: true, force: true });
});

test("a hash-route case keeps its route; params go only into a stage's query", async () => {
  const { stageUrlForTest } = await import("./runner");
  expect(stageUrlForTest("frame.html", { entry: "a.b", width: 760 })).toBe("/frame.html?entry=a.b&width=760");
  expect(stageUrlForTest("index.html#/a.b/c?theme=Nord", { width: 1600 })).toBe("/index.html#/a.b/c?theme=Nord");
});

test("a matrix reuses its browser while isolating and closing every case context", async () => {
  const { runLocal } = await import("./runner");
  const { writeFileSync } = await import("node:fs");
  const dir = mkdtempSync(join(process.cwd(), "gallery-browser-lifecycle-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([
    { id: "first", path_or_url: "https://example.test/" },
    { id: "second", path_or_url: "https://example.test/" },
  ]));
  let launches = 0; let contexts = 0; let closedContexts = 0; let closedBrowsers = 0;
  const navigationWaits: unknown[] = [];
  const browserTypes = { chromium: { launch: async () => {
    launches++;
    return {
      newContext: async () => {
        contexts++;
        return {
          newPage: async () => ({
            exposeFunction: async () => {}, goto: async (_url: string, options: unknown) => { navigationWaits.push(options); }, waitForFunction: async () => {},
            evaluate: async () => null,
            screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
          }),
          close: async () => { closedContexts++; },
        };
      },
      close: async () => { closedBrowsers++; },
    };
  } } };
  try {
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never);
    expect(results.map((r) => r.id)).toEqual(["first", "second"]);
    expect(launches).toBe(1);
    expect(contexts).toBe(2);
    expect(closedContexts).toBe(2);
    expect(closedBrowsers).toBe(1);
    expect(navigationWaits).toEqual([{ waitUntil: "domcontentloaded" }, { waitUntil: "domcontentloaded" }]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("recycles a crashed renderer and keeps the matrix moving", async () => {
  const { runLocal } = await import("./runner");
  const { writeFileSync } = await import("node:fs");
  const dir = mkdtempSync(join(process.cwd(), "gallery-browser-recovery-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([{ id: "crash-once", path_or_url: "https://example.test/" }]));
  let launches = 0;
  let closedBrowsers = 0;
  try {
    const browserTypes = { chromium: { launch: async () => {
      const attempt = ++launches;
      return {
        newContext: async () => ({
          newPage: async () => ({
            exposeFunction: async () => {}, goto: async () => {}, waitForFunction: async () => {},
            evaluate: async () => { if (attempt === 1) throw new Error("Target crashed"); return null; },
            screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
          }),
          close: async () => {},
        }),
        close: async () => { closedBrowsers++; },
      };
    } } };
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never);
    expect(results).toHaveLength(1);
    expect(results[0]?.ready).toBe(null);
    expect(launches).toBe(2);
    expect(closedBrowsers).toBe(2);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("records a hung case after both bounded attempts and captures later cases", async () => {
  const { runLocal } = await import("./runner");
  const { writeFileSync } = await import("node:fs");
  const dir = mkdtempSync(join(process.cwd(), "gallery-browser-timeout-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([
    { id: "hung", path_or_url: "https://example.test/hung" },
    { id: "next", path_or_url: "https://example.test/next" },
  ]));
  let launches = 0; let closedBrowsers = 0;
  const previousExitCode = process.exitCode;
  try {
    const browserTypes = { chromium: { launch: async () => {
      launches++;
      return {
        newContext: async () => {
          let target = "";
          return {
            newPage: async () => ({
              exposeFunction: async () => {}, goto: async (url: string) => { target = url; }, waitForFunction: async () => {},
              evaluate: async () => target.includes("hung") ? new Promise(() => {}) : null,
              screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
            }),
            close: async () => {},
          };
        },
        close: async () => { closedBrowsers++; },
      };
    } } };
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0, caseTimeoutMs: 5 }, browserTypes as never);
    expect(results.map((result) => result.id)).toEqual(["hung", "next"]);
    expect(results[0]?.ready).toBe("error");
    expect(results[0]?.error).toContain("timed out after 5ms");
    expect(results[1]?.ready).toBe(null);
    expect(launches).toBe(3);
    expect(closedBrowsers).toBe(3);
    expect(JSON.parse(readFileSync(join(dir, "results.json"), "utf8"))).toEqual(results);
  } finally {
    process.exitCode = previousExitCode;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("records a navigation failure and continues the matrix", async () => {
  const { runLocal } = await import("./runner");
  const dir = mkdtempSync(join(process.cwd(), "gallery-navigation-failure-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([
    { id: "stuck", path_or_url: "https://example.test/stuck" },
    { id: "fine", path_or_url: "https://example.test/fine" },
  ]));
  const browserTypes = { chromium: { launch: async () => ({
    newContext: async () => ({
      newPage: async () => ({
        exposeFunction: async () => {},
        goto: async (url: string) => { if (url.includes("stuck")) throw new Error("goto: Timeout 30000ms exceeded."); },
        waitForFunction: async () => {},
        evaluate: async () => null,
        screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
      }),
      close: async () => {},
    }),
    close: async () => {},
  }) } };
  const exitCode = process.exitCode;
  try {
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never);
    expect(results.map((r) => [r.id, r.ready])).toEqual([["stuck", "error"], ["fine", null]]);
    expect(String(results[0]!.error)).toContain("Timeout");
    expect(existsSync(join(dir, "fine-chromium.png"))).toBe(true);
    expect(JSON.parse(readFileSync(join(dir, "results.json"), "utf8"))).toHaveLength(2);
    expect(existsSync(join(dir, "index.html"))).toBe(true);
  } finally {
    process.exitCode = exitCode;
    rmSync(dir, { recursive: true, force: true });
  }
});

test("allocation failure waits for late VM ids before finally cleanup", async () => {
  const { createAllVms } = await import("./runner");
  const late = Promise.withResolvers<void>();
  const recorded: string[] = []; const paused: string[] = [];
  const run = (async () => {
    try {
      await createAllVms(2, async (shard) => {
        if (shard === 0) throw new Error("allocation refused");
        await late.promise;
        recorded.push("vm-late");
      });
    } catch { /* The allocation failure is expected; cleanup must still see the late success. */ }
    finally { paused.push(...recorded); }
  })();
  // Let the rejected allocation settle while its sibling is still in flight.
  await new Promise((resolve) => setTimeout(resolve, 0));
  late.resolve();
  await run;
  expect(paused).toEqual(["vm-late"]);
});

test("duplicate capture cells cannot replace a missing scenario", () => {
  const cases = [{ id: "a", path_or_url: "frame.html" }, { id: "b", path_or_url: "frame.html" }];
  const duplicate = { id: "a", engine: "chromium", ready: "1" };
  const receipt = captureReceipt(cases, [duplicate, duplicate], "capture", undefined, 2);
  expect(receipt.results.status).toBe("partial");
  expect(receipt.quality).toBe("fail");
});

test("an empty capture never reports passing quality", () => {
  expect(captureReceipt([], [], "empty").quality).toBe("fail");
});
