// Both composer looks use Codex's permission capsule. In Claude's look it sits in the quiet row under
// the box, its shield under the + glyph, and keeps its own 8 px inset. In Codex's look it sits in the
// box's row, where every control takes the row's one inset (design/composer.md rule 11, Leo
// 2026-10-31; composer-row-one-gap.test.ts). Measure the real gallery composer in Chromium.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-permission-pill.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const look of ["claude", "codex"] as const) {
    test(`${look}: permission control keeps the shared capsule geometry`, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height: 360 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", { variant: `${look}-chat` })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.waitForSelector(".acpmux-access-trigger");
      const measure = () =>
        page.$eval(".acpmux-access-trigger", (pill) => {
          const css = getComputedStyle(pill);
          const plus = document.querySelector(".acpmux-composer-plus .acpmux-icon")!;
          const shield = pill.querySelector(".acpmux-icon")!.getBoundingClientRect();
          const plusBox = plus.getBoundingClientRect();
          return {
            // Both looks put the capsule in the quiet row under the box (#26551), its shield under the
            // + glyph (composer-alignment-centers.test.ts).
            shieldUnderPlus: Math.abs((shield.left + shield.right) / 2 - (plusBox.left + plusBox.right) / 2) <= 0.5,
            height: pill.getBoundingClientRect().height,
            paddingStart: Number.parseFloat(css.paddingInlineStart),
            paddingEnd: Number.parseFloat(css.paddingInlineEnd),
            radius: Number.parseFloat(css.borderTopLeftRadius),
          };
        });
      const normal = await measure();
      expect(normal.height).toBe(28);
      // Codex's row: the row's inset (--acpmux-row-inset, 6 px), as every chip in it.
      const inset = look === "codex" ? 6 : 8;
      expect(normal.paddingStart).toBe(inset);
      expect(normal.paddingEnd).toBe(inset);
      expect(normal.radius).toBeGreaterThanOrEqual(normal.height / 2);
      // Claude's look pins the shield under the + glyph (composer-alignment-centers.test.ts); Codex's
      // + sits on its own box inset, which no test pins yet, so only the capsule is checked there.
      if (look === "claude") expect(normal.shieldUnderPlus).toBe(true);
      await page.hover(".acpmux-access-trigger");
      expect(await measure()).toEqual(normal);
      await page.close();
    });
  }
});
