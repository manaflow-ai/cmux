// The paragraph and display-math seam is owned by the scaled transcript inner-gap token.
// Gallery agent-pane.paragraph-spacing-token provides before, chosen and comparison arms.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { DENSITIES } from "../src/gallery/env";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("paragraph-spacing-token.test.ts", async () => {
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

  async function measure(variant: string, density: string, theme: string, interfaceScale: number) {
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
    const read = () =>
      page.evaluate(() => {
        const markdown = document.querySelector<HTMLElement>(".cv-md");
        const paragraph = document.querySelector<HTMLElement>(".cv-md .cv-p");
        const math = document.querySelector<HTMLElement>(".cv-p + .cv-math-display");
        return {
          paragraphCount: document.querySelectorAll(".cv-md .cv-p").length,
          equation: !!document.querySelector(".cv-math-display .katex"),
          gridGap: markdown ? Number.parseFloat(getComputedStyle(markdown).rowGap) : Number.NaN,
          paragraphAfter: paragraph ? Number.parseFloat(getComputedStyle(paragraph).marginBottom) : Number.NaN,
          mathMarginTop: math ? Number.parseFloat(getComputedStyle(math).marginTop) : Number.NaN,
        };
      });
    const result = await read();
    // A page that sets the token above the transcript (Home Channels sets 4px on its root) keeps it.
    await page.evaluate(() => document.documentElement.style.setProperty("--cv-para-after", "4px"));
    const inherited = await read();
    await page.close();
    return { ...result, inherited };
  }

  for (const density of DENSITIES)
    for (const theme of themes)
      for (const interfaceScale of scales)
        for (const variant of variants)
          test(`${variant.name} uses one paragraph token (${density}/${theme.file}/s${interfaceScale})`, async () => {
            const result = await measure(variant.name, density, theme.name, interfaceScale);
            expect(result.paragraphCount).toBeGreaterThanOrEqual(3);
            expect(result.equation).toBe(true);
            const after = variant.relation === "shared" ? result.gridGap : variant.relation === "before" ? 14 : 16;
            expect(result.gridGap).toBeGreaterThan(0);
            expect(result.paragraphAfter).toBeCloseTo(after, 1);
            expect(result.mathMarginTop).toBeCloseTo(result.gridGap - after, 1);
            if (variant.relation === "shared") {
              expect(result.inherited.paragraphAfter).toBeCloseTo(4, 1);
              expect(result.inherited.mathMarginTop).toBeCloseTo(result.gridGap - 4, 1);
            }
          });
});
