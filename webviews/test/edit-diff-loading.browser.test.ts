import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("edit-diff-loading.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    server = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      plugins: [devHighlightWorker()],
      logLevel: "error",
    });
    await server.listen();
    base = `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, "agent-pane.inline-diff-loading", { browser, params: { variant: "loaded" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });
  const frame = (variant: string, scheme: string, width: number) =>
    `${base}${galleryFrame("agent-pane.inline-diff-loading", {
      variant,
      theme: "Apple System Colors",
      colorScheme: scheme,
      width,
      height: 260,
    })}`;
  const loadedBody = async (page: import("playwright").Page) => {
    await page.locator("diffs-container [data-line]").first().waitFor();
    return page.evaluate(() => {
      const line = document.querySelector("diffs-container")!.shadowRoot!.querySelector<HTMLElement>("[data-line]")!;
      return {
        height: document.querySelector(".cv-edit-diff__body")!.getBoundingClientRect().height,
        x: line.getBoundingClientRect().left + parseFloat(getComputedStyle(line).paddingLeft),
      };
    });
  };
  test.each(["light", "dark"])(
    "%s: placeholders remain visible without borders and match the short loaded body",
    async (scheme) => {
      const page = await browser.newPage({ viewport: { width: 320, height: 260 } });
      try {
        await page.goto(frame("short", scheme, 320));
        await page.locator(".cv-edit-diff__loading-line > span").first().waitFor();
        const pending = await page.evaluate(() => {
          document.documentElement.dataset.borders = "none";
          const text = document.querySelector<HTMLElement>(".cv-edit-diff__loading-line > span")!;
          return {
            height: document.querySelector(".cv-edit-diff__body")!.getBoundingClientRect().height,
            x: text.getBoundingClientRect().left,
            paint: getComputedStyle(text).backgroundColor,
          };
        });
        expect(pending.height).toBeGreaterThan(0);
        expect(pending.paint).toMatch(/(?:rgba\([^)]*, 0\.[1-9]\d*\)|color\([^)]*\/ 0\.[1-9]\d*\))/);
        await page.goto(frame("loaded", scheme, 320));
        const loaded = await loadedBody(page);
        console.log({ scheme, pending, loaded });
        expect(Math.abs(pending.height - loaded.height)).toBeLessThan(1);
        expect(Math.abs(pending.x - loaded.x)).toBeLessThan(1);
      } finally {
        await page.close();
      }
    },
  );
  // The swap must not move the transcript (gallery health's layout-shift check): wrapped lines,
  // separators before mid-file hunks and the unnumbered gutter all keep the rendered diff's height.
  test.each([
    ["fragment", 320],
    ["prose", 320],
    ["prose", 640],
    ["hunks", 320],
  ] as const)("%s at %ipx: the placeholder is as tall as the rendered diff", async (variant, width) => {
    const page = await browser.newPage({ viewport: { width, height: 260 } });
    try {
      await page.goto(frame(variant, "dark", width));
      await page.locator(".cv-edit-diff__loading-lines").first().waitFor();
      const pending = await page.evaluate(
        () => document.querySelector(".cv-edit-diff__body")!.getBoundingClientRect().height,
      );
      await page.goto(frame(`${variant}-loaded`, "dark", width));
      const loaded = await loadedBody(page);
      console.log({ variant, width, pending, loaded });
      expect(Math.abs(pending - loaded.height)).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });
});
