// A rail jump to the oldest loaded prompt pages older history above it. The target row must stay
// at the landing line while those pages arrive and the rows above it measure.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { LANDING_OFFSET } from "../src/agent-session/acpmux/threadMinimap/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-minimap-jump-history.test.ts", async () => {
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

  const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
  const turn = (index: number) => [
    row(`t${index}-user`, "user", `Prompt ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}. A long answer keeps the row measurable.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ];
  const all = Array.from({ length: 1_500 }, (_, index) => turn(index)).flat();
  const loadedStart = 1_200;
  const target = `t${loadedStart}-user`;

  describe("thread minimap jump through older pages (Chromium)", () => {
    test("holds the clicked row while older pages prepend", async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 1280, height: 820 } });
      await installPaintedFrames(page);
      await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html`);
      await page.waitForFunction(() => "__showRows" in window && "__setOlderPage" in window);
      await page.evaluate(
        ({ rows, start }) => {
          const state = window as any;
          state.__allRows = rows;
          state.__pageStart = start;
          state.__pageCount = 0;
          state.__olderRequested = 0;
          state.__releaseOlderPage = undefined;
          state.__setOlderPage(
            () =>
              new Promise<void>((resolve) => {
                state.__olderRequested++;
                state.__releaseOlderPage = () => {
                  state.__pageReleasedAt = ((state.__frames ?? []) as unknown[]).length;
                  state.__pageCount++;
                  state.__pageStart = Math.max(0, state.__pageStart - 100);
                  state.__showRows((state.__allRows as AcpmuxRow[]).slice(state.__pageStart * 3));
                  resolve();
                };
              }),
          );
          (window as any).__showRows(rows.slice(start * 3));
        },
        { rows: all, start: loadedStart },
      );
      await page.waitForSelector(".acpmux-minimap__tick");
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = 0;
        scroller.dispatchEvent(new Event("scroll"));
      });
      await page.waitForFunction(() => (window as any).__olderRequested === 1);
      const frames: { target?: number; scrollTop: number }[] = [];
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = 0;
        scroller.dispatchEvent(new Event("scroll"));
      });
      await page.waitForSelector(`.acpmux-row[data-row-id="${target}"]`);
      await page.evaluate((id) => {
        const probe = window as any;
        probe.__frames = [];
        probe.__targetRemounts = 0;
        let previous: HTMLElement | undefined;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const observer = new MutationObserver(() => {
          const current = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find(
            (row) => row.dataset.rowId === id,
          );
          if (previous && current !== previous) probe.__targetRemounts++;
          if (current) previous = current;
        });
        observer.observe(scroller, { childList: true, subtree: true });
        probe.__stopTargetObserver = () => observer.disconnect();
        window.cmuxAfterPaint(() => {
          const view = scroller.getBoundingClientRect();
          const node = document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`);
          if (node) previous = previous ?? node;
          probe.__frames.push({
            target: node ? node.getBoundingClientRect().top - view.top : undefined,
            scrollTop: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
          });
          return probe.__frames.length < 240;
        });
      }, target);
      await page.waitForFunction(() => ((window as any).__frames as unknown[]).length >= 30);
      const tick = await page.evaluate(() => {
        const box = document.querySelector<HTMLElement>('[data-tick="0"]')!.getBoundingClientRect();
        return { x: box.left + 6, y: box.top + box.height / 2 };
      });
      await page.evaluate(() => {
        (window as any).__clickedAt = ((window as any).__frames as unknown[]).length;
      });
      await page.mouse.click(tick.x, tick.y);
      await page.evaluate(() => (window as any).__releaseOlderPage?.());
      await page.waitForFunction(() => ((window as any).__frames as unknown[]).length >= 120);
      const captured = await page.evaluate(() => (window as any).__frames as { target?: number; scrollTop: number }[]);
      const pageCount = await page.evaluate(() => (window as any).__pageCount ?? 0);
      const pageReleasedAt = await page.evaluate(() => (window as any).__pageReleasedAt ?? -1);
      const targetRemounts = await page.evaluate(() => {
        (window as any).__stopTargetObserver?.();
        return (window as any).__targetRemounts ?? 0;
      });
      const clickedAt = await page.evaluate(() => (window as any).__clickedAt as number);
      frames.push(...captured);
      await page.close();

      const landed = frames.filter((frame) => frame.target !== undefined);
      const postClick = captured.slice(clickedAt).filter((frame) => frame.target !== undefined);
      expect(landed.length).toBeGreaterThan(30);
      const tail = postClick.slice(-30);
      expect(tail.every((frame) => Math.abs(frame.target! - LANDING_OFFSET) <= 2)).toBe(true);
      const settledAt = postClick.findIndex((frame) => Math.abs(frame.target! - LANDING_OFFSET) <= 2);
      expect(settledAt).toBeGreaterThanOrEqual(0);
      const targetRange = postClick.slice(settledAt).map((frame) => frame.target!);
      console.log(
        JSON.stringify({
          historyPages: pageCount,
          pageReleasedAt,
          paintedFrames: captured.length,
          clickedAt,
          settledAt,
          postTargetRange: [Math.min(...targetRange), Math.max(...targetRange)],
          postScrollRange: [postClick[0]?.scrollTop, postClick.at(-1)?.scrollTop],
          targetRemounts,
        }),
      );
      expect(Math.max(...targetRange) - Math.min(...targetRange)).toBeLessThanOrEqual(4);
      expect(pageCount).toBe(1);
      expect(pageReleasedAt).toBeGreaterThanOrEqual(clickedAt);
      expect(targetRemounts).toBe(0);
    });
  });
});
