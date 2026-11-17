// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
// cmux#44886: Settings > Personalization's title drew blurred under a white haze. The page's soft
// scroll edge (layout.css .scroll-edge: four backdrop blurs and a tint of the page background) fades
// in with a scroll-driven animation, so at rest it is not drawn. With the app's motion switch off,
// WebTheme.bootstrapScript sets `animation-duration: 0s !important` on every element; a 0s
// scroll-driven animation has no range, holds its last keyframe, and the edge sat fully drawn over
// the title at every scroll position. Real Chromium on the gallery's Personalization page with the
// real bootstrap: at rest the edge is not drawn and the title is not under it, with motion on or off,
// and once the page scrolls the edge still fades in.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("settings-scroll-edge-motion-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("settings-scroll-edge-motion: chromium cannot launch here; skipping");
    describe.skip("settings scroll edge motion", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "pages.settings", { params: { variant: "personalization" } });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Each edge layer's opacity (its four blurs, then its tint) after the next two frames. */
  async function edgeOpacities(page: Page): Promise<number[]> {
    return page.evaluate(async () => {
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      const edge = document.querySelector<HTMLElement>(".content > .scroll-edge")!;
      return [
        ...[...edge.querySelectorAll(":scope > span")].map((layer) => Number(getComputedStyle(layer).opacity)),
        Number(getComputedStyle(edge, "::after").opacity),
      ];
    });
  }

  for (const motion of ["off", "full"] as const) {
    test(`the scroll edge is not drawn over the page title at rest, and fades in on scroll (motion ${motion})`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
      try {
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("pages.settings", { variant: "personalization", colorScheme: "light", width: 900, height: 640 })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
        await page.waitForSelector('[data-section="personalization"] .section-title');
        // What cmuxTheme.apply does with a payload's `motion` (WebTheme.motionValue: the master
        // switch, the web category or the speed off).
        await page.evaluate((value) => document.documentElement.setAttribute("data-cmux-motion", value), motion);
        const layout = await page.evaluate(() => {
          const edge = document.querySelector<HTMLElement>(".content > .scroll-edge")!;
          const title = document.querySelector<HTMLElement>('[data-section="personalization"] .section-title')!;
          const content = document.querySelector<HTMLElement>(".content")!;
          return {
            display: getComputedStyle(edge).display,
            titleUnderEdge: title.getBoundingClientRect().top < edge.getBoundingClientRect().bottom,
            scrollable: content.scrollHeight - content.clientHeight,
          };
        });
        // The edge is drawn on this page (a jump bar), and the title sits in its strip: it is the
        // text a drawn edge blurs.
        expect(layout.display).toBe("block");
        expect(layout.titleUnderEdge).toBe(true);
        expect(layout.scrollable).toBeGreaterThan(100);

        expect(await edgeOpacities(page)).toEqual([0, 0, 0, 0, 0]);

        await page.evaluate(() => {
          document.querySelector<HTMLElement>(".content")!.scrollTop = 100;
        });
        expect(await edgeOpacities(page)).toEqual([1, 1, 1, 1, 1]);

        await page.evaluate(() => {
          document.querySelector<HTMLElement>(".content")!.scrollTop = 0;
        });
        expect(await edgeOpacities(page)).toEqual([0, 0, 0, 0, 0]);
      } finally {
        await page.close();
      }
    });
  }
});
