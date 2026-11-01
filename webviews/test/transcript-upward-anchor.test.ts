// Leo 2026-10-28: upward scrolling has a "weird recalculation". Measure row movement after paint,
// subtracting only the distance the wheel requested, while cold rows above the view first measure.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { traceUpwardAnchors } from "./support/upwardAnchorTrace";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-upward-anchor.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-upward-anchor: skipping (run `bunx playwright install webkit`)");
    describe.skip("transcript upward anchor", () => test("webkit", () => {}));
    return;
  }
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
    await warmViteServer(vite, "/test/browser/transcript-fling.html");
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("cold 3k-turn upward wheels preserve the visible row's position", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      // Three source rows per synthetic turn: user, assistant and summary.
      const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
      expect(seeded.rows).toBe(9_000);
      await page.waitForFunction(
        () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9_000,
      );
      const shownRows = await page.evaluate(() =>
        Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")),
      );
      // No warm fling: rows encountered above the viewport must still have estimated heights.
      const steps = Array.from({ length: 240 }, (_, frame) => -[18.25, 42.5, 27.75, 56.125][frame % 4]!);
      const result = await page.evaluate(traceUpwardAnchors, { steps });
      // Preserve the complete row-id/y trace in the hosted log, on both a pass and a failure.
      console.log(
        `transcript-upward-anchor: ${JSON.stringify({ sourceRows: seeded.rows, turns: seeded.rows / 3, shownRows, ...result })}`,
      );
      expect(result.cancelledWheels).toBe(0);
      expect(result.wheelPixels).toBeLessThan(-8_000);
      expect(result.frames).toBe(264);
      expect(result.compared).toBe(result.frames);
      expect(result.missingAnchors).toBe(0);
      expect(result.blankFrames).toBe(0);
      expect(result.blankBandFrames).toBe(0);
      expect(result.maxRowBoxGap).toBeLessThanOrEqual(1 / 64);
      expect(result.blankEdgeFrames).toBe(0);
      expect(result.maxViewportEdgeGap).toBeLessThanOrEqual(1 / 64);
      // DOM coordinates use fractional CSS pixels; allow only one 1/64 px layout quantum.
      expect(result.maxDrift).toBeLessThanOrEqual(1 / 64);
    } finally {
      await page.close();
    }
  });
  test("fractional remeasurement while following keeps the painted anchor through upward release", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      await page.evaluate(`window.__debug.seedRows(9000)`);
      await page.waitForFunction(
        () => Number(document.querySelector(".acpmux-row")?.getAttribute("aria-setsize")) >= 9000,
      );
      const result = await page.evaluate(async () => {
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = scroller.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const above = rows.find((row) => row.getBoundingClientRect().bottom < view.top)!;
        const anchor = rows.find((row) => row.getBoundingClientRect().bottom > view.top)!;
        const originalHeight = above.getBoundingClientRect().height;
        const originalY = anchor.getBoundingClientRect().top;
        const drift: number[] = [];
        const growth: number[] = [];
        for (const added of [0.5, 0]) {
          await window.cmuxPaintFrame(() => {
            above.style.minHeight = `${originalHeight + added}px`;
          });
          for (let frame = 0; frame < 3; frame += 1) {
            drift.push(anchor.getBoundingClientRect().top - originalY);
            await window.cmuxPaintFrame();
          }
          growth.push(above.getBoundingClientRect().height - originalHeight);
        }
        let moved = 0;
        await window.cmuxPaintFrame(() => {
          const before = scroller.scrollTop;
          scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -18.25, bubbles: true, cancelable: true }));
          scroller.scrollTop -= 18.25;
          moved = scroller.scrollTop - before;
        });
        drift.push(anchor.getBoundingClientRect().top - originalY + moved);
        return { growth, drift };
      });
      console.log(`transcript-fractional-follow: ${JSON.stringify(result)}`);
      expect(result.growth).toEqual([0.5, 0]);
      for (const drift of result.drift) expect(Math.abs(drift)).toBeLessThanOrEqual(1 / 64);
    } finally {
      await page.close();
    }
  });

  test("large transcript keeps adjacent row boxes at every 1/64 px measured height", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
      expect(seeded.rows).toBe(9_000);
      await page.evaluate(() => (window as unknown as { __seedFoldStream(): void }).__seedFoldStream());
      const card = page.locator('[data-row-id="gap-incoming"]');
      await card.waitFor();
      await card.evaluate((node) => node.scrollIntoView({ block: "center" }));

      const result = await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const upper = () => scroller.querySelector<HTMLElement>('[data-row-id="synthetic-end-2996"]')!;
        const lower = () => scroller.querySelector<HTMLElement>('[data-row-id="gap-incoming"]')!;
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        if (!upper() || !lower()) throw new Error("the adjacent 3k-turn rows did not mount");
        const baseHeight = upper().getBoundingClientRect().height;
        const absoluteTop = Number.parseFloat(upper().style.top);
        const samples: Array<{
          phase: string;
          quantum: number;
          height: number;
          gap: number;
          upperTop: string;
          upperMarginTop: string;
          lowerTop: string;
          lowerMarginTop: string;
          scrollTop: number;
        }> = [];
        const setHeightAndSample = async (quantum: number, phase: string) => {
          await window.cmuxPaintFrame(() => {
            const row = upper();
            if (!row) throw new Error(`upper row unmounted at ${phase} ${quantum}`);
            row.style.minHeight = `${baseHeight + quantum / 64}px`;
          });
          // Let ResizeObserver report the new measured height, React place rows, then read painted boxes.
          await window.cmuxPaintFrame();
          await window.cmuxPaintFrame();
          const a = upper();
          const b = lower();
          if (!a || !b) throw new Error(`adjacent rows unmounted at ${phase} ${quantum}`);
          const aBox = a.getBoundingClientRect();
          const bBox = b.getBoundingClientRect();
          samples.push({
            phase,
            quantum,
            height: aBox.height,
            gap: bBox.top - aBox.bottom,
            upperTop: a.style.top,
            upperMarginTop: a.style.marginTop,
            lowerTop: b.style.top,
            lowerMarginTop: b.style.marginTop,
            scrollTop: scroller.scrollTop,
          });
        };

        for (let quantum = 0; quantum < 32; quantum += 1) await setHeightAndSample(quantum, "folded");
        const toggle = lower().querySelector<HTMLButtonElement>(".cv-disclosure__toggle")!;
        if (!toggle) throw new Error("real received-card fold toggle missing");
        const beforeFold = toggle.getAttribute("aria-expanded");
        await window.cmuxPaintFrame(() => {
          toggle.click();
          (window as unknown as { __stepFoldStream(): void }).__stepFoldStream();
        });
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const afterFold = lower()
          .querySelector<HTMLButtonElement>(".cv-disclosure__toggle")
          ?.getAttribute("aria-expanded");
        for (let quantum = 31; quantum >= 0; quantum -= 1) await setHeightAndSample(quantum, "expanded-streaming");
        return { baseHeight, absoluteTop, beforeFold, afterFold, samples };
      });
      console.log(`transcript-css-top-precision: ${JSON.stringify(result)}`);
      expect(result.absoluteTop).toBeGreaterThan(500_000);
      expect(result.beforeFold).toBe("false");
      expect(result.afterFold).toBe("true");
      expect(result.samples).toHaveLength(64);
      for (const sample of result.samples) {
        // This guard makes the test fail if the min-height mutation or ResizeObserver never took effect.
        expect(Math.abs(sample.height - (result.baseHeight + sample.quantum / 64))).toBeLessThanOrEqual(1 / 128);
        // Check overlap as well as a positive blank seam; both are structural placement errors.
        expect(Math.abs(sample.gap)).toBeLessThanOrEqual(1 / 64);
      }
    } finally {
      await page.close();
    }
  });

  test.each(["top", "bottom"] as const)(
    "the painted oracle detects a blank band at the %s viewport edge",
    async (edge) => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      try {
        await installPaintedFrames(page);
        const top = edge === "top" ? 40 : -40;
        // Middle transcript rows remain adjacent; only one viewport edge is uncovered. These
        // negative oracle fixtures make an adjacency-only check fail to detect the missing paint.
        await page.setContent(`
        <div class="acpmux-scroll" style="position:relative;height:200px;overflow:hidden">
          <article class="acpmux-row" data-row-id="a" aria-posinset="2" aria-setsize="4"
            style="position:absolute;top:${top}px;height:100px;width:100%">A</article>
          <article class="acpmux-row" data-row-id="b" aria-posinset="3" aria-setsize="4"
            style="position:absolute;top:${top + 100}px;height:100px;width:100%">B</article>
        </div>`);
        const result = await page.evaluate(traceUpwardAnchors, { steps: [0], restFrames: 0 });
        expect(result.frames).toBe(1);
        expect(result.compared).toBe(1);
        expect(result.maxRowBoxGap).toBe(0);
        expect(result.blankEdgeFrames).toBe(1);
        expect(result.maxViewportEdgeGap).toBe(40);
        expect(result.samples[0]![edge === "top" ? "topEdgeGap" : "bottomEdgeGap"]).toBe(40);
      } finally {
        await page.close();
      }
    },
  );

  test("received card folds preserve painted row-box adjacency while streaming", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    try {
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-fling.html`);
      await page.waitForFunction(() => "__debug" in window);
      const seeded = (await page.evaluate(`window.__debug.seedRows(9000)`)) as { rows: number };
      expect(seeded.rows).toBe(9000);
      await page.evaluate(() => (window as unknown as { __seedFoldStream(): void }).__seedFoldStream());
      const card = page.locator('[data-row-id="gap-incoming"]');
      await card.waitFor();
      await card.evaluate((node) => node.scrollIntoView({ block: "start" }));
      const result = await page.evaluate(traceUpwardAnchors, {
        steps: Array.from({ length: 112 }, () => 0),
        foldStream: true,
      });
      console.log(`transcript-fold-stream: ${JSON.stringify({ sourceRows: seeded.rows, turns: 3000, ...result })}`);
      expect(result.foldToggleClicks).toBe(4);
      expect(result.foldTransitions).toHaveLength(4);
      for (const transition of result.foldTransitions) {
        const before = transition.before;
        if (before !== "true" && before !== "false") throw new Error(`unexpected fold state: ${before}`);
        expect(["true", "false"]).toContain(before);
        expect(transition.after).toBe(before === "true" ? "false" : "true");
      }
      expect(result.frames).toBe(136);
      expect(result.compared).toBe(result.frames);
      expect(result.missingAnchors).toBe(0);
      expect(result.maxDrift).toBeLessThanOrEqual(1 / 64);
      expect(result.blankFrames).toBe(0);
      expect(result.blankBandFrames).toBe(0);
      expect(result.maxRowBoxGap).toBeLessThanOrEqual(1 / 64);
      expect(result.blankEdgeFrames).toBe(0);
      expect(result.maxViewportEdgeGap).toBeLessThanOrEqual(1 / 64);
    } finally {
      await page.close();
    }
  });
});
