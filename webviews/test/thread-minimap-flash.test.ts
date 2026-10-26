// l10n-allow-file: fixture prompts and replies, not shipped UI.
// CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-flash.test.ts
//
// This is the measuring regression for the prompt rail flash. It keeps the same rows on screen
// while the rail changes, counts row-node churn, and samples after painted frames so a compositor
// flash cannot be mistaken for a virtualizer gap.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-flash.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const row = (id: string, kind: string, text?: string, version = 1, extra: Record<string, unknown> = {}) => ({
    id,
    kind,
    text,
    version,
    at: 1,
    ...extra,
  });
  const paragraph = "The streamed answer keeps enough spacing to exercise the transcript layout.";
  const rows = Array.from({ length: 30 }, (_, index) => [
    row(`t${index}-user`, "user", `Prompt ${index + 1}: inspect the thread rail redraw.`),
    row(`t${index}-answer`, "assistant", `${paragraph}\n\n${paragraph}`),
    row(`t${index}-end`, "turnSummary", undefined, 1, { status: "completed", durationMs: 1_000 }),
  ]).flat();
  const streamedRows = rows.map((entry) =>
    entry.id === "t4-answer"
      ? {
          ...entry,
          version: 2,
          text: `${entry.text}\n\n${Array.from({ length: 12 }, () => paragraph).join("\n\n")}`,
        }
      : entry,
  );

  type Scenario = {
    name: string;
    action: (page: Page) => Promise<void>;
  };
  type Result = {
    name: string;
    rowAdds: number;
    rowRemoves: number;
    missingFrames: number;
    frameCount: number;
    layerChanges: number;
    removedIds?: string[];
    before: Record<string, unknown>;
    after: Record<string, unknown>;
    cardLayer?: { isolation?: string; willChange?: string };
  };

  const settle = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      for (let tries = 0; tries < 20; tries += 1) {
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let last = -1;
          let still = 0;
          window.cmuxAfterPaint(() => {
            const top = document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0;
            still = top === last ? still + 1 : 0;
            last = top;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
        if (finite().every((animation) => animation.playState !== "running")) return;
      }
    });

  const scenarioProbe = (page: Page, name: string) =>
    page.evaluate(
      ({ name }) =>
        new Promise<Result>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const visibleAtStart = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
            .filter((node) => {
              const box = node.getBoundingClientRect();
              const view = scroller.getBoundingClientRect();
              return box.bottom > view.top && box.top < view.bottom;
            })
            .map((node) => node.dataset.rowId!);
          let rowAdds = 0;
          let rowRemoves = 0;
          const removedIds: string[] = [];
          const observer = new MutationObserver((records) => {
            const ids = (node: Node) =>
              node instanceof HTMLElement
                ? [
                    ...(node.matches(".acpmux-row") ? [node.dataset.rowId] : []),
                    ...[...node.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => row.dataset.rowId),
                  ].filter((id): id is string => Boolean(id))
                : [];
            for (const record of records) {
              for (const node of record.addedNodes) rowAdds += ids(node).length;
              for (const node of record.removedNodes) {
                const removed = ids(node);
                rowRemoves += removed.length;
                removedIds.push(...removed);
              }
            }
          });
          observer.observe(scroller, { childList: true, subtree: true });
          const snapshot = () => {
            const selectors = [".acpmux-scroll", ".acpmux-minimap__rail", ".acpmux-minimap__card"];
            return Object.fromEntries(
              selectors.map((selector) => {
                const node = document.querySelector<HTMLElement>(selector);
                if (!node) return [selector, null];
                const style = getComputedStyle(node);
                const box = node.getBoundingClientRect();
                return [
                  selector,
                  {
                    backdropFilter: style.backdropFilter,
                    maskImage: style.maskImage,
                    willChange: style.willChange,
                    isolation: style.isolation,
                    contain: style.contain,
                    width: box.width,
                    height: box.height,
                  },
                ];
              }),
            );
          };
          const before = snapshot();
          const initialLayer = JSON.stringify(before);
          let layerChanges = 0;
          let missingFrames = 0;
          let frameCount = 0;
          let cardLayer: Result["cardLayer"];
          const started = performance.now();
          window.cmuxAfterPaint(() => {
            frameCount += 1;
            const current = snapshot();
            if (JSON.stringify(current) !== initialLayer) layerChanges += 1;
            const card = current[".acpmux-minimap__card"];
            if (card && !cardLayer) cardLayer = card as Result["cardLayer"];
            for (const id of visibleAtStart) {
              const node = scroller.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${CSS.escape(id)}"]`);
              const box = node?.getBoundingClientRect();
              const opacity = node ? Number(getComputedStyle(node).opacity) : 0;
              if (!node || !box || box.width === 0 || box.height === 0 || opacity !== 1) {
                missingFrames += 1;
                break;
              }
            }
            if (performance.now() - started < 700) return true;
            observer.disconnect();
            const after = snapshot();
            resolve({
              name,
              rowAdds,
              rowRemoves,
              removedIds,
              missingFrames,
              frameCount,
              layerChanges,
              before,
              after,
              cardLayer,
            });
            return false;
          });
        }),
      { name },
    );

  const openPage = async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector(".acpmux-minimap__rail");
    await settle(page);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.min(700, scroller.scrollHeight / 2);
    });
    await settle(page);
    return page;
  };

  const tickPoint = (page: Page, index = 2) =>
    page.evaluate((index) => {
      const box = document.querySelector<HTMLElement>(`[data-tick="${index}"]`)!.getBoundingClientRect();
      return { x: box.left + 8, y: box.top + box.height / 2 };
    }, index);

  const scenarios: Scenario[] = [
    {
      name: "hover leave",
      action: async (page) => {
        const point = await tickPoint(page);
        await page.mouse.move(point.x, point.y);
        await page.locator(".acpmux-minimap__card").waitFor({ timeout: 5_000 });
        await page.mouse.move(900, 20);
      },
    },
    {
      name: "stream spacing",
      action: async (page) => {
        await page.evaluate(
          (next) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(next),
          streamedRows,
        );
      },
    },
    {
      name: "rail tick click",
      action: async (page) => {
        const point = await tickPoint(page);
        await page.mouse.click(point.x, point.y);
      },
    },
    {
      name: "card open close",
      action: async (page) => {
        const point = await tickPoint(page);
        await page.mouse.move(point.x, point.y);
        await page.locator(".acpmux-minimap__card").waitFor({ timeout: 5_000 });
        await page.mouse.move(900, 20);
      },
    },
  ];

  test("the rail highlight clears without transcript remounts or missing painted rows", async () => {
    const results: Result[] = [];
    for (const scenario of scenarios) {
      const page = await openPage();
      try {
        const probe = scenarioProbe(page, scenario.name);
        await scenario.action(page);
        results.push(await probe);
      } finally {
        await page.close();
      }
    }
    console.log(`thread-minimap-flash ${JSON.stringify(results)}`);
    expect(results.every((result) => result.missingFrames === 0)).toBe(true);
    expect(results.find((result) => result.name === "hover leave")).toMatchObject({
      rowAdds: 0,
      rowRemoves: 0,
    });
    expect(results.find((result) => result.name === "card open close")).toMatchObject({
      rowAdds: 0,
      rowRemoves: 0,
    });
    // The rail and its card must have an independent, stable compositing boundary. Base fails this
    // assertion while the frame counts above show that the rows themselves stayed mounted/painted.
    expect(
      results.every((result) => {
        const rail = result.before[".acpmux-minimap__rail"] as {
          isolation?: string;
          willChange?: string;
        } | null;
        return rail?.isolation === "isolate" && rail.willChange?.includes("transform");
      }),
    ).toBe(true);
    expect(
      results
        .filter((result) => result.cardLayer)
        .every(
          (result) => result.cardLayer?.isolation === "isolate" && result.cardLayer.willChange?.includes("transform"),
        ),
    ).toBe(true);
  });
});
