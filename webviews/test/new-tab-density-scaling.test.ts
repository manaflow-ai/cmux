// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-density-scaling.test.ts", async () => {
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser: browsers.get("chromium")! });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"]) {
    test(`${engine}: suggestion width, alignment and proportions follow the composer zoom`, async () => {
      const page = await browsers.get(engine)!.newPage({ viewport: { width: 1600, height: 1000 } });
      const port = (vite.httpServer!.address() as { port: number }).port;
      const results: {
        scale: number;
        boxWidth: number;
        popupWidth: number;
        left: number;
        glyph: number;
        text: number;
        prompt: number;
        row: number;
        plus: number;
        send: number;
        stroke: number;
        layout: {
          composerZoom: string;
          composerWidth: string;
          column: string;
          screenWidth: number;
          screenPadding: string;
        };
      }[] = [];
      for (const scale of [0.8, 1, 1.2]) {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", {
            variant: `density-${Math.round(scale * 100)}`,
            width: 1400,
            frame: "component",
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".nt-popover .nt-row").first().waitFor();
        results.push(
          await page.evaluate((scale) => {
            const composer = document.querySelector<HTMLElement>(".nt-composer")!;
            const box = document.querySelector<HTMLElement>(".nt-box")!.getBoundingClientRect();
            const popover = document.querySelector<HTMLElement>(".nt-popover")!;
            const popup = popover.getBoundingClientRect();
            const row = popover.querySelector<HTMLElement>(".nt-row")!;
            const glyph = row.querySelector<HTMLElement>(".nt-row-glyph")!;
            const prompt = composer.querySelector<HTMLElement>(".nt-field")!;
            const zoom = parseFloat(getComputedStyle(popover).zoom);
            const plus = composer.querySelector<HTMLElement>(".acpmux-newtab-plus .acpmux-icon")!;
            const send = composer.querySelector<HTMLElement>(".acpmux-send .acpmux-icon")!;
            const screen = composer.closest<HTMLElement>(".nt-screen")!;
            const composerStyle = getComputedStyle(composer);
            return {
              scale,
              boxWidth: box.width,
              popupWidth: popup.width,
              left: popup.left - box.left,
              glyph: glyph.getBoundingClientRect().width,
              text: parseFloat(getComputedStyle(row).fontSize) * zoom,
              prompt: parseFloat(getComputedStyle(prompt).fontSize) * zoom,
              row: row.getBoundingClientRect().height,
              plus: plus.getBoundingClientRect().width,
              send: send.getBoundingClientRect().width,
              stroke: parseFloat(getComputedStyle(send).strokeWidth),
              layout: {
                composerZoom: composerStyle.zoom,
                composerWidth: composerStyle.width,
                column:
                  composerStyle.getPropertyValue("--cmux-composer-column") ||
                  composerStyle.getPropertyValue("--cv-column"),
                screenWidth: screen.getBoundingClientRect().width,
                screenPadding: getComputedStyle(screen).paddingInline,
              },
            };
          }, scale),
        );
      }
      const reference = results[1]!;
      expect(reference.plus).toBeCloseTo(16, 1);
      expect(reference.send).toBeCloseTo(16, 1);
      expect(reference.stroke).toBeCloseTo(1.5, 1);
      for (const result of results) {
        expect(Math.abs(result.popupWidth - result.boxWidth)).toBeLessThan(1);
        expect(Math.abs(result.left)).toBeLessThan(1);
        expect(
          Math.abs(result.boxWidth - reference.boxWidth * result.scale),
          JSON.stringify({ engine, result, reference }),
        ).toBeLessThan(1);
        for (const key of ["glyph", "text", "prompt", "row", "plus", "send"] as const) {
          expect(Math.abs(result[key] - reference[key] * result.scale)).toBeLessThan(0.5);
        }
      }
      await page.close();
    });
  }
});
