// The composer marks Claude's compact grid on its box and form (`data-composer-grid`, ComposerBox.tsx
// and Composer.tsx), and composerLocation.css keys the grid to that mark instead of a
// `:has(> .acpmux-chrome-area > .acpmux-composer-inner)` on the box, the form and the dock: those
// `:has()` rules made every node inserted in the agent pane restyle the whole pane
// (pane-has-restyle.browser.test.ts). The mark must stand exactly where the old selector matched,
// in Claude's look and in Codex's, and the box must still lay out as the grid.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-grid-attribute.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-grid-attribute: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer grid attribute", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer-look";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "claude-chat" } });
  }, 110_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [variant, grid] of [
    ["claude-chat", true],
    ["permission-pill-claude", true],
    // Both looks draw the grid (composerLook.ts; Leo 2026-11-01: "we already have a good version").
    ["codex-chat", true],
  ] as const)
    test(`${variant}: the grid mark stands where the old :has() matched`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 760, height: 420 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        await page.waitForSelector(".acpmux-composer-box");
        const state = await page.evaluate(() => {
          const box = document.querySelector(".acpmux-composer-box")!;
          const form = box.closest(".acpmux-composer")!;
          return {
            boxHas: box.matches(":has(> .acpmux-chrome-area > .acpmux-composer-inner)"),
            boxMark: box.hasAttribute("data-composer-grid"),
            formHas: form.matches(":has(.acpmux-composer-box > .acpmux-chrome-area > .acpmux-composer-inner)"),
            formMark: form.hasAttribute("data-composer-grid"),
            display: getComputedStyle(box).display,
          };
        });
        expect(state).toEqual({
          boxHas: grid,
          boxMark: grid,
          formHas: grid,
          formMark: grid,
          display: grid ? "grid" : expect.any(String),
        });
        if (!grid) expect(state.display).not.toBe("grid");
      } finally {
        await page.close();
      }
    });
});
