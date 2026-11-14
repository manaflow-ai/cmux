// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// Find in Chat and the text selection over every surface a chat draws (agent-pane.highlight-contrast,
// HighlightContrast.gallery.tsx), in real Chromium on the gallery frame, light and dark. Leo
// 2026-11-07: "we don't want it to be coverable by other sorts of things. Like, for example, these
// hover previews" and "sometimes there's, like, low contrast on the highlight".
//
// The find bar is the top layer of its pane: a timestamp's tooltip right under it opens below its
// row, its box clear of the bar's. Each strategy variant draws its matches as fit groups (one per
// surface) with the current match apart. Every state's still goes to $FAST_CHECKS_OUT for the PR.
// CI fails the file when Chromium cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("highlight-contrast-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.highlight-contrast";
  const WIDTH = 640;
  const HEIGHT = 520;
  const VARIANTS = ["theme-colors", "fit-soft", "fit", "fit-strong", "find-bar-layer"] as const;
  const out = process.env.FAST_CHECKS_OUT;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "fit" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, colorScheme: "light" | "dark"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT } });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(ENTRY, { variant, colorScheme, width: WIDTH, height: HEIGHT }));
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    return page;
  }

  describe("find and selection contrast", () => {
    for (const variant of VARIANTS)
      for (const scheme of ["light", "dark"] as const)
        test(`${variant} in ${scheme}`, async () => {
          const page = await open(variant, scheme);
          const errors: string[] = [];
          page.on("pageerror", (error) => errors.push(error.message));
          try {
            if (variant === "find-bar-layer") {
              await page.hover(".hc-time");
              await page.locator(".ui-tooltip").waitFor();
              // Base UI places the popup after it mounts; read once it has a size.
              await page.waitForFunction(
                () => (document.querySelector(".ui-tooltip")?.getBoundingClientRect().height ?? 0) > 0,
              );
              const boxes = await page.evaluate(() => {
                const box = (selector: string) => {
                  const rect = document.querySelector(selector)!.getBoundingClientRect();
                  return { top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right };
                };
                return { bar: box(".acpmux-find__bar"), tooltip: box(".ui-tooltip"), time: box(".hc-time") };
              });
              // Below the bar, and below its row (it flipped from its usual place above).
              expect(boxes.tooltip.top).toBeGreaterThanOrEqual(boxes.bar.bottom);
              expect(boxes.tooltip.top).toBeGreaterThanOrEqual(boxes.time.bottom);
            } else {
              const groups = await page.evaluate(() => {
                const registry = (CSS as unknown as { highlights: Map<string, { size: number }> }).highlights;
                return [...registry.keys()].filter((name) => name.startsWith("gallery-contrast-fit-")).length;
              });
              // The current match's group and at least one for the other matches.
              expect(groups).toBeGreaterThanOrEqual(2);
            }
            if (out) await page.screenshot({ path: path.join(out, `highlight-contrast-${variant}-${scheme}.png`) });
            expect(errors).toEqual([]);
          } finally {
            await page.close();
          }
        });
  });
});
