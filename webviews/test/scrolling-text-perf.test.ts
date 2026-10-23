// cmux-web-test-timeout: 420
// l10n-allow-file: performance fixture content, not shipped UI.
// A 320-turn, rich transcript is scrolled at a fixed wheel-like cadence and a fling, while idle and
// while the final answer streams. The page is the real VirtualTranscript; scrolling-text.harness.tsx
// samples every painted frame and stops all observers/timers at the end of each phase.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type ScrollReport = {
  phase: "constant" | "fling";
  streaming: boolean;
  turns: number;
  rows: number;
  frames: { count: number; p50: number; p95: number; p99: number; max: number; over16_7: number; over33: number };
  longAnimationFrames: { count: number; p50: number; p95: number; p99: number; max: number; entries: unknown[] } | null;
  longTasks: { count: number; totalMs: number; p50: number; p95: number; p99: number; max: number; entries: unknown[] } | null;
  scriptMs: { p50: number; p95: number; p99: number; max: number };
  scrollTop: { start: number; end: number; max: number };
  input: "synthetic-scrollTop+scroll";
  cdp?: {
    taskMs: number;
    scriptMs: number;
    layoutMs: number;
    recalcStyleMs: number;
    layoutCount: number;
    recalcStyleCount: number;
    perFrame: { taskMs: number; scriptMs: number; layoutMs: number; recalcStyleMs: number; layoutCount: number; recalcStyleCount: number };
  };
  compositor?: {
    layerPainted: number;
    layerTreeDidChange: number;
    layersWithPaintDelta: number;
    contentLayers: number;
    layerPaintedPerFrame: number;
    layersWithPaintDeltaPerFrame: number;
  } | "unsupported";
};

type CdpMetric = { name: string; value: number };
type Cdp = {
  send(method: string, params?: Record<string, unknown>): Promise<any>;
  on(event: string, listener: (payload: any) => void): void;
  off(event: string, listener: (payload: any) => void): void;
};

await requireBrowserLane("scrolling-text-perf.test.ts", async () => {
  setDefaultTimeout(420_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`scrolling-text-perf: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("scrolling text performance", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/scrolling-text.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function metrics(cdp: Cdp) {
    const result = await cdp.send("Performance.getMetrics");
    const get = (name: string) => (result.metrics as CdpMetric[]).find((entry) => entry.name === name)?.value ?? 0;
    return {
      taskMs: get("TaskDuration") * 1000,
      scriptMs: get("ScriptDuration") * 1000,
      layoutMs: get("LayoutDuration") * 1000,
      recalcStyleMs: get("RecalcStyleDuration") * 1000,
      layoutCount: get("LayoutCount"),
      recalcStyleCount: get("RecalcStyleCount"),
    };
  }

  async function run(name: string, phase: "constant" | "fling", streaming: boolean): Promise<ScrollReport> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 760 } });
    const cdp = name === "chromium" ? ((await page.context().newCDPSession(page)) as unknown as Cdp) : undefined;
    const initialPaintCounts = new Map<string, number>();
    const finalPaintCounts = new Map<string, number>();
    const layerIds = new Set<string>();
    let layerPainted = 0;
    let layerTreeDidChange = 0;
    const onPainted = ({ layerId }: { layerId: string }) => {
      layerPainted += 1;
      layerIds.add(layerId);
    };
    const onTree = ({ layers }: { layers?: { layerId: string; paintCount: number; drawsContent: boolean }[] }) => {
      layerTreeDidChange += 1;
      for (const layer of layers ?? []) {
        if (!layer.drawsContent) continue;
        layerIds.add(layer.layerId);
        if (!initialPaintCounts.has(layer.layerId)) initialPaintCounts.set(layer.layerId, layer.paintCount);
        finalPaintCounts.set(layer.layerId, layer.paintCount);
      }
    };
    try {
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/scrolling-text.html`);
      await page.waitForFunction(() => "__scrollPerf" in window);
      await page.locator(".acpmux-row").first().waitFor();
      // Let the 320-turn fixture finish its initial measurement before the measured phases.
      for (let count = 0; count < 12; count += 1) await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
      if (cdp) {
        await cdp.send("Performance.enable");
        await cdp.send("LayerTree.enable");
        cdp.on("LayerTree.layerPainted", onPainted);
        cdp.on("LayerTree.layerTreeDidChange", onTree);
        await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
      }
      const before = cdp ? await metrics(cdp) : undefined;
      const report = (await page.evaluate(
        ({ phase: direction, streaming: active }) =>
          (window as unknown as { __scrollPerf: { run(options: { phase: string; streaming: boolean }): Promise<unknown> } }).__scrollPerf.run({
            phase: direction,
            streaming: active,
          }),
        { phase, streaming },
      )) as ScrollReport;
      const after = cdp ? await metrics(cdp) : undefined;
      if (cdp && before && after) {
        const frameCount = Math.max(1, report.frames.count);
        const delta = {
          taskMs: +(after.taskMs - before.taskMs).toFixed(3),
          scriptMs: +(after.scriptMs - before.scriptMs).toFixed(3),
          layoutMs: +(after.layoutMs - before.layoutMs).toFixed(3),
          recalcStyleMs: +(after.recalcStyleMs - before.recalcStyleMs).toFixed(3),
          layoutCount: after.layoutCount - before.layoutCount,
          recalcStyleCount: after.recalcStyleCount - before.recalcStyleCount,
        };
        report.cdp = {
          ...delta,
          perFrame: {
            taskMs: +(delta.taskMs / frameCount).toFixed(3),
            scriptMs: +(delta.scriptMs / frameCount).toFixed(3),
            layoutMs: +(delta.layoutMs / frameCount).toFixed(3),
            recalcStyleMs: +(delta.recalcStyleMs / frameCount).toFixed(3),
            layoutCount: +(delta.layoutCount / frameCount).toFixed(3),
            recalcStyleCount: +(delta.recalcStyleCount / frameCount).toFixed(3),
          },
        };
        report.compositor = {
          layerPainted,
          layerTreeDidChange,
          layersWithPaintDelta: [...initialPaintCounts].filter(([layerId, count]) => (finalPaintCounts.get(layerId) ?? count) > count).length,
          contentLayers: layerIds.size,
          layerPaintedPerFrame: +(layerPainted / frameCount).toFixed(3),
          layersWithPaintDeltaPerFrame: +(
            [...initialPaintCounts].filter(([layerId, count]) => (finalPaintCounts.get(layerId) ?? count) > count).length / frameCount
          ).toFixed(3),
        };
      }
      if (!cdp) report.compositor = "unsupported";
      return report;
    } finally {
      if (cdp) {
        cdp.off("LayerTree.layerPainted", onPainted);
        cdp.off("LayerTree.layerTreeDidChange", onTree);
        await cdp.send("LayerTree.disable").catch(() => {});
        await cdp.send("Performance.disable").catch(() => {});
      }
      await page.close();
    }
  }

  for (const [name] of engines) {
    test(`${name}: idle and streaming transcript scroll metrics`, async () => {
      const reports: ScrollReport[] = [];
      for (const streaming of [false, true]) {
        for (const phase of ["constant", "fling"] as const) reports.push(await run(name, phase, streaming));
      }
      for (const report of reports) console.log(`scrolling-text-perf ${name}: ${JSON.stringify(report)}`);
      expect(reports.every((report) => report.turns === 320 && report.rows === 1_280)).toBe(true);
      // This is a measurement harness: retain a behavioral oracle for the virtualized scroll path and
      // leave the threshold decision to the PR's before/after numbers on the same fleet host.
      expect(reports.every((report) => report.frames.count >= 120)).toBe(true);
      expect(reports.every((report) => report.scrollTop.end > report.scrollTop.start)).toBe(true);
    });
  }
});
