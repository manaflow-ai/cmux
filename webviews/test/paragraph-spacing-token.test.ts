// The paragraph and display-math seam is owned by the scaled transcript inner-gap token.
// Gallery agent-pane.paragraph-spacing-token provides before, chosen and comparison arms.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { DENSITIES } from "../src/gallery/env";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("paragraph-spacing-token.test.ts", async () => {
  setDefaultTimeout(120_000);
  const themes = [
    { name: "Apple System Colors Light", file: "light" },
    { name: "Catppuccin Mocha", file: "dark" },
  ] as const;
  const variants = [
    { name: "before", relation: "before" },
    { name: "shared", relation: "shared" },
    { name: "roomy", relation: "roomy" },
  ] as const;
  const scales = [1, 1.25] as const;
  let browser: Browser | undefined;
  let vite: Awaited<ReturnType<typeof import("vite").createServer>> | undefined;

  beforeAll(async () => {
    try {
      browser = await chromium.launch({ headless: true });
    } catch {
      describe.skip("paragraph spacing token", () => test("browser", () => {}));
      return;
    }
    const { createServer } = await import("vite");
    const webviews = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.paragraph-spacing-token", {
      browser,
      params: { variant: "shared", density: "comfortable", scale: 1, interfaceScale: 1 },
    });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function measure(
    variant: string,
    density: string,
    theme: string,
    interfaceScale: number,
    after: number | "gap",
  ) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.paragraph-spacing-token", {
        variant,
        density,
        scale: 1,
        interfaceScale,
        theme,
        colorScheme: theme.includes("Light") ? "light" : "dark",
        reducedMotion: 1,
      })}`,
      { waitUntil: "commit" },
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    const sample = () =>
      page.evaluate(() => {
        const markdown = document.querySelector<HTMLElement>(".cv-md");
        // Top-level blocks are spaced by the stack's gap; nested ones (a list item's) by the token.
        const before = document.querySelector<HTMLElement>(".cv-list li > .cv-p:has(+ .cv-math-display)");
        const math = document.querySelector<HTMLElement>(".cv-list li > .cv-p + .cv-math-display");
        const paragraph = document.querySelector<HTMLElement>(".cv-list li > .cv-math-display + .cv-p");
        return {
          paragraphCount: document.querySelectorAll(".cv-md .cv-p").length,
          equation: !!document.querySelector(".cv-math-display .katex"),
          gridGap: markdown ? Number.parseFloat(getComputedStyle(markdown).rowGap) : Number.NaN,
          paragraphAfter: paragraph ? Number.parseFloat(getComputedStyle(paragraph).marginBottom) : Number.NaN,
          // Drawn, not computed: stacked margins collapse, so the boxes tell the real seam.
          mathGap:
            before && math ? math.getBoundingClientRect().top - before.getBoundingClientRect().bottom : Number.NaN,
        };
      });
    // The reply can still be settling when the frame reports ready: wait until the gaps read as
    // expected (or the wait gives up), then read them, so a failure reports what was drawn.
    const settled = (after: number | "gap") =>
      page
        .waitForFunction(
          (want) => {
            const markdown = document.querySelector<HTMLElement>(".cv-md");
            const before = document.querySelector<HTMLElement>(".cv-list li > .cv-p:has(+ .cv-math-display)");
            const math = document.querySelector<HTMLElement>(".cv-list li > .cv-p + .cv-math-display");
            const paragraph = document.querySelector<HTMLElement>(".cv-list li > .cv-math-display + .cv-p");
            if (!markdown || !before || !math || !paragraph) return false;
            const gap = Number.parseFloat(getComputedStyle(markdown).rowGap);
            const target = want === "gap" ? gap : want;
            const seam = math.getBoundingClientRect().top - before.getBoundingClientRect().bottom;
            return (
              Math.abs(Number.parseFloat(getComputedStyle(paragraph).marginBottom) - target) < 0.05 &&
              Math.abs(seam - gap) < 0.05
            );
          },
          after,
          { timeout: 10_000 },
        )
        .catch(() => undefined)
        .then(sample);
    const result = await settled(after);
    // A page that sets the token above the transcript (Home Channels sets 4px on its root) keeps it.
    let inherited: Awaited<ReturnType<typeof sample>> | undefined;
    if (after === "gap") {
      await page.addStyleTag({ content: ".acpmux-row { --cv-para-after: 4px; }" });
      inherited = await settled(4);
    }
    await page.close();
    return { ...result, inherited };
  }

  for (const density of DENSITIES)
    for (const theme of themes)
      for (const interfaceScale of scales)
        for (const variant of variants)
          test(`${variant.name} uses one paragraph token (${density}/${theme.file}/s${interfaceScale})`, async () => {
            const want = variant.relation === "shared" ? "gap" : variant.relation === "before" ? 14 : 16;
            const result = await measure(variant.name, density, theme.name, interfaceScale, want);
            expect(result.paragraphCount).toBeGreaterThanOrEqual(3);
            expect(result.equation).toBe(true);
            const after = variant.relation === "shared" ? result.gridGap : variant.relation === "before" ? 14 : 16;
            expect(result.gridGap).toBeGreaterThan(0);
            expect(result.paragraphAfter).toBeCloseTo(after, 1);
            expect(result.mathGap).toBeCloseTo(result.gridGap, 1);
            if (variant.relation === "shared") {
              expect(result.inherited?.paragraphAfter).toBeCloseTo(4, 1);
              expect(result.inherited?.mathGap).toBeCloseTo(result.gridGap, 1);
            }
          });
});
