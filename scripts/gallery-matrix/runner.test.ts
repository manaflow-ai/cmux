import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { PNG } from "pngjs";
import { chromium } from "playwright";
import { captureClip, deleteLedgerIds, diffPng, parseManifest, pauseLedgerIds, renderIndex, settleSummary, shardCases, undeletedLedgerIds, withTimeout, writeLedger } from "./runner";

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

test("motion review cards include an opt-in video", () => {
  const html = renderIndex([{ id: "motion", engine: "webkit", screenshot: "motion.png", video: "motion.webm" }]);
  expect(html).toContain("r.video");
  expect(html).toContain("motion.webm");
});

test("capture clips stay in the viewport after scroll and handle offscreen or missing targets", async () => {
  const browser = await chromium.launch({ ...(process.env.CMUX_CHROME_HEADLESS_SHELL ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL } : { channel: "chrome" }) });
  try {
    const page = await browser.newPage({ viewport: { width: 400, height: 300 } });
    await page.setContent('<style>body{margin:0;height:1600px}#root{position:absolute;left:80px;top:600px;width:100px;height:80px;background:blue}[data-gallery-capture]{position:absolute;left:10px;top:10px;width:40px;height:30px;background:red}</style><div id="root"><div data-gallery-capture></div></div>');
    await page.evaluate(() => window.scrollTo(0, 500));
    expect(await page.evaluate(() => window.scrollY)).toBe(500);
    const clip = await captureClip(page);
    expect(clip).toEqual({ x: 58, y: 78, width: 104, height: 94 });
    const pixels = PNG.sync.read(await page.screenshot({ clip }));
    const pixel = (40 * pixels.width + 40) * 4;
    expect([...pixels.data.subarray(pixel, pixel + 3)]).toEqual([255, 0, 0]);
    // A partially visible target retains only its visible portion plus context.
    await page.evaluate(() => { const root = document.getElementById("root")!; root.querySelector("[data-gallery-capture]")!.remove(); Object.assign(root.style, { left: "-40px", top: "750px", width: "500px", height: "100px" }); });
    expect(await captureClip(page)).toEqual({ x: 0, y: 218, width: 400, height: 82 });
    for (const [left, top] of [[500, 600], [-500, 600], [-110, 600], [410, 600], [80, 410], [80, 810], [80, 0], [80, 1200]]) {
      await page.evaluate(({ left, top }) => Object.assign(document.getElementById("root")!.style, { left: `${left}px`, top: `${top}px`, width: "100px", height: "80px" }), { left, top });
      expect(await captureClip(page)).toBeUndefined();
    }
    await page.evaluate(() => document.getElementById("root")!.remove());
    expect(await captureClip(page)).toBeUndefined();
  } finally { await browser.close(); }
});

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

/** The browser-context double's CDP session: Performance metrics with this renderer ThreadTime (s). */
function cdpSession(threadTimeS: number) {
  return async () => ({
    send: async (method: string) =>
      method === "Performance.getMetrics" ? { metrics: [{ name: "ThreadTime", value: threadTimeS }] } : {},
  });
}

/** One ready case, stamped ready 3000 ms after navigation, in a context with or without CDP. */
async function renderReadyCase(context: Record<string, unknown>) {
  const { runLocal } = await import("./runner");
  const dir = mkdtempSync(join(process.cwd(), "gallery-ready-cpu-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([{ id: "ready", path_or_url: "https://example.test/", params: { entry: "e", variant: "v" } }]));
  const browserTypes = { chromium: { launch: async () => ({
    newContext: async () => ({
      newPage: async () => ({
        exposeFunction: async () => {}, addInitScript: async () => {}, goto: async () => {}, waitForFunction: async () => {},
        evaluate: async (fn: unknown) => {
          const source = String(fn);
          if (source.includes("cmuxGalleryReadyMs")) return 3000;
          if (source.includes("galleryReady ??")) return "1";
          return null;
        },
        screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
      }),
      close: async () => {},
      ...context,
    }),
    close: async () => {},
  }) } };
  const exitCode = process.exitCode;
  try {
    return (await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never))[0]!;
  } finally {
    process.exitCode = exitCode;
    rmSync(dir, { recursive: true, force: true });
  }
}

test("a ready case records the renderer's CPU time, and its budget is held to it", async () => {
  const { readyTimes } = await import("./ready-budgets");
  const result = await renderReadyCase({ newCDPSession: cdpSession(0.75) });
  expect([result.ready, result.readyMs, result.readyCpuMs]).toEqual(["1", 3000, 750]);
  expect(readyTimes([result as never])).toEqual(new Map([["e#v", 750]]));
});

test("a context with no CDP, or one that refuses it, falls back to wall time instead of failing the case", async () => {
  const { readyTimes } = await import("./ready-budgets");
  const refuse = () => { throw new Error("CDP session is only available in Chromium"); };
  for (const context of [{}, { newCDPSession: refuse }, { newCDPSession: async () => ({ send: refuse }) }]) {
    const result = await renderReadyCase(context);
    expect([result.ready, result.readyMs, result.readyCpuMs, result.error]).toEqual(["1", 3000, null, undefined]);
    expect(readyTimes([result as never])).toEqual(new Map([["e#v", 3000]]));
  }
});

/** One ready case whose play takes `stills` step stills, each costing the renderer 200 ms of CPU, around 750 ms of its own work. */
async function renderCapturingCase(stills: number) {
  const { runLocal } = await import("./runner");
  const dir = mkdtempSync(join(process.cwd(), "gallery-capture-cpu-"));
  const manifest = join(dir, "manifest.json");
  writeFileSync(manifest, JSON.stringify([{ id: "captures", path_or_url: "https://example.test/", params: { entry: "e", variant: "v" } }]));
  let threadTime = 0;
  let step: ((step: { index: number; step: string }) => Promise<void>) | undefined;
  const browserTypes = { chromium: { launch: async () => ({
    newContext: async () => ({
      newPage: async () => ({
        exposeFunction: async (name: string, callback: typeof step) => { if (name === "cmuxGalleryStep") step = callback; },
        addInitScript: async () => {},
        goto: async () => {
          threadTime += 0.75;
          for (let index = 0; index < stills; index++) await step?.({ index, step: `still ${index}` });
        },
        waitForFunction: async () => {},
        evaluate: async (fn: unknown) => {
          const source = String(fn);
          if (source.includes("cmuxGalleryReadyMs")) return 3000;
          if (source.includes("galleryReady ??")) return "1";
          return null;
        },
        screenshot: async ({ path }: { path: string }) => { threadTime += 0.2; writeFileSync(path, "fixture screenshot"); },
      }),
      newCDPSession: async () => ({
        send: async (method: string) => method === "Performance.getMetrics" ? { metrics: [{ name: "ThreadTime", value: threadTime }] } : {},
      }),
      close: async () => {},
    }),
    close: async () => {},
  }) } };
  const exitCode = process.exitCode;
  try {
    return (await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never))[0]!;
  } finally {
    process.exitCode = exitCode;
    rmSync(dir, { recursive: true, force: true });
  }
}

test("the CPU a play's step stills cost is taken out of its ready CPU time", async () => {
  const one = await renderCapturingCase(1);
  const five = await renderCapturingCase(5);
  expect([one.readyCpuMs, one.readyCaptureCpuMs]).toEqual([750, 200]);
  expect([five.readyCpuMs, five.readyCaptureCpuMs]).toEqual([750, 1000]);
});

test("in Chromium, a state's ready CPU time stays flat as its play takes more stills", async () => {
  const { runLocal } = await import("./runner");
  const dir = mkdtempSync(join(process.cwd(), "gallery-capture-cpu-chromium-"));
  // A dense stage, so a full-page still costs the renderer real work, and a fixed 150 ms of its own.
  writeFileSync(join(dir, "gallery-frame-stub.js"), "");
  writeFileSync(join(dir, "stage.html"), `<!doctype html><html><body style="margin:0">
<script src="gallery-frame-stub.js"></script>
<div id="grid" style="display:grid;grid-template-columns:repeat(40,1fr)"></div>
<script>
const grid = document.getElementById("grid");
for (let i = 0; i < 6000; i++) { const cell = document.createElement("div"); cell.textContent = "cell " + i; cell.style.cssText = "font:11px sans-serif;padding:2px;border:1px solid hsl(" + (i % 360) + ",60%,50%);border-radius:3px;box-shadow:0 1px 3px rgba(0,0,0,.3)"; grid.appendChild(cell); }
const stills = Number(new URLSearchParams(location.search).get("stills"));
(async () => {
  for (let index = 0; index < stills; index++) await window.cmuxGalleryStep({ index, step: "still " + index });
  const until = performance.now() + 150; while (performance.now() < until) {}
  document.documentElement.dataset.galleryReady = "1";
})();
</script></body></html>`);
  const exitCode = process.exitCode;
  try {
    const render = async (stills: number) => {
      const manifest = join(dir, `manifest-${stills}.json`);
      writeFileSync(manifest, JSON.stringify([{ id: `stills-${stills}`, path_or_url: "stage.html", params: { stills, width: 1600, height: 1200 } }]));
      return (await runLocal({ manifest, galleryDir: dir, outputDir: join(dir, `out-${stills}`), threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }))[0]!;
    };
    // Each count is rendered three times and its fastest kept, as gallery health keeps a state's fastest run.
    const fastest = async (stills: number) => {
      const runs = [await render(stills), await render(stills), await render(stills)];
      for (const run of runs) expect(run.ready).toBe("1");
      return runs.reduce((best, run) => (Number(run.readyCpuMs) < Number(best.readyCpuMs) ? run : best));
    };
    const one = await fastest(1);
    const five = await fastest(5);
    console.log(`ready CPU: 1 still ${one.readyCpuMs} ms (captures ${one.readyCaptureCpuMs} ms), 5 stills ${five.readyCpuMs} ms (captures ${five.readyCaptureCpuMs} ms)`);
    // Four more stills cost the renderer real CPU, and none of it reaches the ready time.
    expect(Number(five.readyCaptureCpuMs) - Number(one.readyCaptureCpuMs)).toBeGreaterThan(40);
    expect(Math.abs(Number(five.readyCpuMs) - Number(one.readyCpuMs))).toBeLessThan(
      Math.max(30, (Number(five.readyCaptureCpuMs) - Number(one.readyCaptureCpuMs)) / 2),
    );
  } finally {
    process.exitCode = exitCode;
    rmSync(dir, { recursive: true, force: true });
  }
}, 60_000);

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
  const screenshots: { fullPage?: boolean; clip?: unknown }[] = [];
  let captureStep: ((step: { index: number; step: string }) => Promise<void>) | undefined;
  const browserTypes = { chromium: { launch: async () => {
    launches++;
    return {
      newContext: async () => {
        contexts++;
        return {
          newPage: async () => ({
            exposeFunction: async (name: string, callback: typeof captureStep) => { if (name === "cmuxGalleryStep") captureStep = callback; }, addInitScript: async () => {}, goto: async (_url: string, options: unknown) => { navigationWaits.push(options); await captureStep?.({ index: 0, step: "fixture" }); }, waitForFunction: async () => {},
            evaluate: async () => null,
            screenshot: async ({ path, ...options }: { path: string; fullPage?: boolean; clip?: unknown }) => { screenshots.push(options); writeFileSync(path, "fixture screenshot"); },
          }),
          newCDPSession: cdpSession(0.5),
          close: async () => { closedContexts++; },
        };
      },
      close: async () => { closedBrowsers++; },
    };
  } } };
  try {
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0 }, browserTypes as never);
    expect(results.map((r) => r.id)).toEqual(["first", "second"]);
    expect(screenshots).toEqual(Array.from({ length: 4 }, () => ({ fullPage: true })));
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
            exposeFunction: async () => {}, addInitScript: async () => {}, goto: async () => {}, waitForFunction: async () => {},
            evaluate: async () => { if (attempt === 1) throw new Error("Target crashed"); return null; },
            screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
          }),
          newCDPSession: cdpSession(0.5),
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
              exposeFunction: async () => {}, addInitScript: async () => {}, goto: async (url: string) => { target = url; }, waitForFunction: async () => {},
              evaluate: async () => target.includes("hung") ? new Promise(() => {}) : null,
              screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
            }),
            newCDPSession: cdpSession(0.5),
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
        exposeFunction: async () => {}, addInitScript: async () => {},
        goto: async (url: string) => { if (url.includes("stuck")) throw new Error("goto: Timeout 30000ms exceeded."); },
        waitForFunction: async () => {},
        evaluate: async () => null,
        screenshot: async ({ path }: { path: string }) => writeFileSync(path, "fixture screenshot"),
      }),
      newCDPSession: cdpSession(0.5),
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

test("renders cases concurrently, one browser per worker, and keeps manifest order", async () => {
  const { runLocal } = await import("./runner");
  const dir = mkdtempSync(join(process.cwd(), "gallery-concurrency-"));
  const manifest = join(dir, "manifest.json");
  // The first case is the slowest, so a worker that took a later case finishes first.
  const ids = ["a", "b", "c", "d", "e", "f", "g"];
  writeFileSync(manifest, JSON.stringify(ids.map((id) => ({ id, path_or_url: `https://example.test/${id}` }))));
  let launches = 0; let inFlight = 0; let most = 0;
  const browserTypes = { chromium: { launch: async () => {
    launches++;
    return {
      newContext: async () => {
        let target = "";
        return {
          newPage: async () => ({
            exposeFunction: async () => {}, addInitScript: async () => {}, waitForFunction: async () => {},
            goto: async (url: string) => {
              target = url;
              inFlight++; most = Math.max(most, inFlight);
              await new Promise((done) => setTimeout(done, url.endsWith("/a") ? 40 : 5));
              inFlight--;
            },
            evaluate: async () => null,
            screenshot: async ({ path }: { path: string }) => writeFileSync(path, target),
          }),
          newCDPSession: cdpSession(0.5),
          close: async () => {},
        };
      },
      close: async () => {},
    };
  } } };
  const exitCode = process.exitCode;
  try {
    const results = await runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0, concurrency: 3 }, browserTypes as never);
    expect(results.map((r) => r.id)).toEqual(ids);
    expect(most).toBe(3);
    expect(launches).toBe(3);
    expect(readFileSync(join(dir, "e-chromium.png"), "utf8")).toBe("https://example.test/e");
    await expect(runLocal({ manifest, galleryDir: dir, outputDir: dir, threshold: 0, engines: ["chromium"], shardCount: 1, shardIndex: 0, concurrency: 0 }, browserTypes as never)).rejects.toThrow("concurrency");
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
