// cmux-web-test-timeout: 240
// The ask card is the same content material as the card: fill, ring and blur equal the card's in
// light and dark, and its corner is the transcript card corner (--grid-cards-radius).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("surface-ask-matches-card.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY_PATH = "src/ui/surface/Surface.gallery.tsx";
  const url = (scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=ui.surface&entryPath=${ENTRY_PATH}&variant=ask&colorScheme=${scheme}`;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const file of [ENTRY_PATH, "src/gallery/frame/component.tsx"])
      if ((await warmViteServer(vite, `/gallery/${file}`)) === 0)
        throw new Error(`warmViteServer: ${file} is not served`);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  describe("ask card on the card's material", () => {
    for (const scheme of ["light", "dark"] as const) {
      test(`fill, stroke and blur equal the card's, radius is the card corner (${scheme})`, async () => {
        const page = await browser!.newPage({ viewport: { width: 900, height: 700 }, colorScheme: scheme });
        for (;;) {
          try {
            await page.goto(url(scheme));
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
              timeout: 60_000,
            });
            break;
          } catch (error) {
            if (!/context was destroyed|navigat/i.test(String(error))) throw error;
          }
        }
        const read = (role: string) =>
          page.locator(`.ui-surface[data-surface-role="${role}"]`).evaluate((node) => {
            const style = getComputedStyle(node);
            return {
              background: style.backgroundColor,
              ring: style.boxShadow,
              blur: style.backdropFilter,
              radius: style.borderTopLeftRadius,
            };
          });
        const ask = await read("ask");
        const card = await read("card");
        expect(ask.background).toBe(card.background);
        expect(ask.ring).toBe(card.ring);
        expect(ask.blur).toBe(card.blur);
        const corner = await page.evaluate(() => {
          const probe = document.createElement("div");
          probe.style.borderTopLeftRadius = "var(--grid-cards-radius)";
          document.body.append(probe);
          const radius = getComputedStyle(probe).borderTopLeftRadius;
          probe.remove();
          return radius;
        });
        expect(ask.radius).toBe(corner);
        await page.close();
      });
    }
  });
});
