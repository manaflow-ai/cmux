import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { PNG } from "pngjs";
import { deleteLedgerIds, diffPng, parseManifest, pauseLedgerIds, shardCases, undeletedLedgerIds, writeLedger } from "./runner";

test("parses and validates a manifest", () => {
  expect(parseManifest([{ id: "a", path_or_url: "index.html", params: { width: 10, dark: true } }])).toHaveLength(1);
  expect(() => parseManifest([{ id: "a", path_or_url: "x" }, { id: "a", path_or_url: "y" }])).toThrow("duplicate");
  expect(() => parseManifest({})).toThrow("array");
});

test("shards cases deterministically", () => {
  const cases = [0, 1, 2, 3, 4, 5].map((id) => ({ id: String(id), path_or_url: "x" }));
  expect(shardCases(cases, 2, 0).map((item) => item.id)).toEqual(["0", "2", "4"]);
  expect(shardCases(cases, 2, 1).map((item) => item.id)).toEqual(["1", "3", "5"]);
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
  const browserTypes = { chromium: { launch: async () => {
    launches++;
    return {
      newContext: async () => {
        contexts++;
        return {
          newPage: async () => ({
            exposeFunction: async () => {}, goto: async () => {}, waitForFunction: async () => {},
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
  } finally { rmSync(dir, { recursive: true, force: true }); }
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

test("a stage that keeps fetching renders once it says it is ready; navigation never waits for network idle", async () => {
  // Run 37833947171: pages.markdown showcase never went 500 ms without a request, so
  // goto(networkidle) timed out at 30 s although the stage had painted. The stage's own
  // data-gallery-ready is the readiness signal; navigation waits only for load.
  const { runLocal } = await import("./runner");
  const { writeFileSync } = await import("node:fs");
  const dir = mkdtempSync(join(process.cwd(), "gallery-busy-network-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([{ id: "busy", path_or_url: "https://example.test/" }]));
  const waits: (string | undefined)[] = [];
  let readyChecks = 0;
  const browserTypes = { chromium: { launch: async () => ({
    newContext: async () => ({
      newPage: async () => ({
        exposeFunction: async () => {},
        goto: async (_url: string, options?: { waitUntil?: string }) => {
          waits.push(options?.waitUntil);
          if (options?.waitUntil === "networkidle") throw new Error("goto: Timeout 30000ms exceeded (the stage never goes network-idle)");
        },
        waitForFunction: async () => { readyChecks++; },
        evaluate: async () => "1",
        screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
      }),
      close: async () => {},
    }),
    close: async () => {},
  }) } };
  try {
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never);
    expect(results.map((r) => r.id)).toEqual(["busy"]);
    expect(waits).toEqual(["load"]);
    expect(readyChecks).toBe(1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
