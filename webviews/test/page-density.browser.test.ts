// cmux-web-test-timeout: 240
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("page-density.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const scale of [0.8, 1.2])
    test(`settings disclosure content and corners follow their fill at density ${scale}`, async () => {
      const page = await browser.newPage({ viewport: { width: 1000, height: 900 } });
      try {
        const port = (server.httpServer!.address() as { port: number }).port;
        const density = scale === 0.8 ? "ultra-compact" : "spacious";
        await page.goto(`http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: `density-${density}` })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        expect(await page.evaluate(() => window.cmuxGalleryPlayReport?.error)).toBeUndefined();
        const metrics = () =>
          page.locator(".content .more-options").evaluateAll((rows) =>
            rows.map((row) => {
              const card = row.closest(".rows")!;
              const cardStyle = getComputedStyle(card);
              const fill = getComputedStyle(row, "::before");
              const box = row.getBoundingClientRect();
              return {
                cardRadius: Number.parseFloat(cardStyle.borderBottomLeftRadius),
                radius: Number.parseFloat(fill.borderBottomLeftRadius),
                inset: Number.parseFloat(cardStyle.borderLeftWidth) + Number.parseFloat(fill.left),
                bottomInset: card.getBoundingClientRect().bottom - box.bottom + Number.parseFloat(fill.bottom),
                height: box.height - Number.parseFloat(fill.top) - Number.parseFloat(fill.bottom),
                fillCenter: box.top + (box.height + Number.parseFloat(fill.top) - Number.parseFloat(fill.bottom)) / 2,
                contentCenters: Array.from(row.children, (child) => {
                  const content = child.getBoundingClientRect();
                  return content.top + content.height / 2;
                }),
              };
            }),
          );
        const closed = await metrics();
        expect(closed.length).toBeGreaterThan(0);
        for (const row of closed) {
          expect(row.bottomInset).toBeCloseTo(row.inset, 1);
          expect(row.radius).toBeCloseTo(Math.min(Math.max(2 * scale, row.cardRadius - row.inset), row.height / 2), 1);
          expect(row.contentCenters).toHaveLength(3);
          for (const center of row.contentCenters) expect(center).toBeCloseTo(row.fillCenter, 1);
        }
        await page.locator(".content .more-options").first().click();
        const opened = (await metrics())[0]!;
        expect(opened.radius).toBeCloseTo(closed[0]!.radius, 1);
        expect(opened.radius).toBeLessThanOrEqual(opened.height / 2);
        for (const center of opened.contentCenters) expect(center).toBeCloseTo(opened.fillCenter, 1);

        await page.locator(".settings").evaluate((element, scale) => {
          (element as HTMLElement).style.setProperty("--look-card-radius", `${scale}px`);
        }, scale);
        expect((await metrics())[0]!.radius).toBeCloseTo(2 * scale, 1);
        await page.locator(".settings").evaluate((element) => {
          (element as HTMLElement).style.setProperty("--look-card-radius", "100px");
        });
        const capped = (await metrics())[0]!;
        expect(capped.radius).toBeGreaterThanOrEqual(2 * scale);
        expect(capped.radius).toBeLessThanOrEqual(capped.height / 2);
      } finally {
        await page.close();
      }
    });

  for (const entry of ["pages.settings"])
    for (const width of [480, 1000])
      for (const [density, scale] of [
        ["ultra-compact", 0.8],
        ["default", 1],
        ["spacious", 1.2],
      ] as const)
        test(`${entry} fits long labels at ${density} in ${width}px`, async () => {
          const page = await browser.newPage({ viewport: { width, height: 900 } });
          try {
            const port = (server.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: `density-${density}`, width })}`);
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            expect(await page.evaluate(() => window.cmuxGalleryPlayReport?.error)).toBeUndefined();
            const metrics = await page.evaluate((settings) => {
              const surface = document.querySelector<HTMLElement>(settings ? ".content" : ".apps-page")!;
              const row = surface.querySelector<HTMLElement>(settings ? ".row" : ".apps-card")!;
              const title = row.querySelector<HTMLElement>(settings ? ".row-title" : ".apps-name");
              if (title)
                title.textContent = "A deliberately long label that needs to wrap without covering adjacent controls";
              const control = row.querySelector<HTMLElement>(settings ? ".row-control" : ".apps-card-actions");
              const label = row.querySelector<HTMLElement>(settings ? ".row-label" : ".apps-card-text");
              const style = getComputedStyle(row);
              const titleBox = label?.getBoundingClientRect();
              const controlBox = control?.getBoundingClientRect();
              return {
                overflow: surface.scrollWidth - surface.clientWidth,
                padding: Number.parseFloat(style.paddingTop),
                radius: Number.parseFloat(style.borderTopLeftRadius),
                overlap:
                  titleBox && controlBox
                    ? titleBox.left < controlBox.right - 1 &&
                      titleBox.right > controlBox.left + 1 &&
                      titleBox.top < controlBox.bottom - 1 &&
                      titleBox.bottom > controlBox.top + 1
                    : false,
              };
            }, entry === "pages.settings");
            expect(metrics.overflow).toBeLessThanOrEqual(1);
            expect(metrics.overlap).toBe(false);
            expect(metrics.padding).toBeCloseTo((entry === "pages.settings" ? 12 : 14) * scale, 1);
            if (entry === "pages.apps") expect(metrics.radius).toBeCloseTo(12 * scale, 1);
          } finally {
            await page.close();
          }
        });
});
