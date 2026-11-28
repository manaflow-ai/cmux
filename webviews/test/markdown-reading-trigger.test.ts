// cmux-web-test-timeout: 300
// The real Reading Settings trigger keeps its fill while focus and the pointer enter its popup.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-reading-trigger.test.ts", async () => {
  const root = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  let base: string;

  beforeAll(async () => {
    server = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await server.listen();
    base = `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(server, "pages.markdown", {
      browser: browsers.get("chromium"),
      params: { variant: "readme" },
    });
  }, 120_000);

  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await server?.close();
  });

  for (const engine of ["chromium", "webkit"])
    for (const theme of ["light", "dark"] as const)
      for (const width of [320, 1000])
        for (const reducedMotion of ["reduce", "no-preference"] as const)
          test(`${engine} ${theme} ${width} ${reducedMotion}: open, leave trigger, dismiss and reopen`, async () => {
            const context = await browsers.get(engine)!.newContext({
              viewport: { width, height: 720 },
              colorScheme: theme,
              reducedMotion,
            });
            try {
              const page = await context.newPage();
              await page.goto(
                base +
                  galleryFrame("pages.markdown", {
                    variant: "readme",
                    colorScheme: theme,
                    width,
                    reducedMotion: reducedMotion === "reduce" ? "1" : "0",
                  }),
              );
              const trigger = page.locator(".md-reading-button");
              await trigger.waitFor({ state: "visible" });
              await page.mouse.move(0, 700);
              const idle = await trigger.evaluate((el) => getComputedStyle(el).backgroundColor);
              await trigger.click();
              await page.locator(".md-reading").waitFor({ state: "visible" });
              await page.locator(".md-reading").hover();
              expect(await trigger.getAttribute("aria-pressed")).toBe("true");
              // Sample the selected fill only after the pointer's hover transition has finished.
              const open = await trigger.evaluate(async (el) => {
                await Promise.all(el.getAnimations().map((animation) => animation.finished));
                return getComputedStyle(el).backgroundColor;
              });
              if (
                process.env.MENU_CAPTURE_DIR &&
                engine === "chromium" &&
                width === 1000 &&
                reducedMotion === "no-preference"
              ) {
                await mkdir(process.env.MENU_CAPTURE_DIR, { recursive: true });
                await page.screenshot({ path: path.join(process.env.MENU_CAPTURE_DIR, `reading-open-${theme}.png`) });
              }
              expect(open).not.toBe(idle);
              await page.keyboard.press("Escape");
              await page.locator(".md-reading").waitFor({ state: "hidden" });
              expect(await trigger.getAttribute("aria-pressed")).toBe("false");
              await page.mouse.move(0, 700);
              // Reduced Motion applies a 0.01ms transition globally. Finish the pointer-leave
              // transition before comparing resting fills, rather than sampling its first tick.
              const closed = await trigger.evaluate(async (el) => {
                await Promise.all(el.getAnimations().map((animation) => animation.finished));
                return getComputedStyle(el).backgroundColor;
              });
              expect(closed).toBe(idle);
              await trigger.click();
              await page.locator(".md-reading").waitFor({ state: "visible" });
              await page.mouse.click(8, 680);
              await page.locator(".md-reading").waitFor({ state: "hidden" });
              expect(await trigger.getAttribute("aria-pressed")).toBe("false");
            } finally {
              await context.close();
            }
          }, 30_000);
});
