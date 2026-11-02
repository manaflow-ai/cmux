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
    await warmGalleryFrame(server, "agent-pane.transcript", { browser, params: { variant: "edit-long-line-code" } });
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
  // Opened in a chat that fit, the edit's placeholder makes the transcript overflow while its fold
  // plays: the chat must open where the reader is, the rows above the clicked card held, not jump a
  // frame to the latest row before the hold puts them back (gallery health, #27650: rows -19 px).
  test.each(["edit-long-line-code", "edit-long-line-prose"])(
    "transcript#%s: opening the edit moves no row above it",
    async (variant) => {
      const page = await browser.newPage({ viewport: { width: 760, height: 560 } });
      // The renderer's chunk is held until the stage is ready, so the placeholder is what the fold
      // opens (as on a cold page) however fast this server answers.
      let release = () => {};
      const held = new Promise<void>((resolve) => (release = resolve));
      await page.route(/EditDiffHunks/, async (route) => {
        await held;
        await route.continue();
      });
      try {
        await page.goto(
          `${base}${galleryFrame("agent-pane.transcript", {
            variant,
            theme: "Apple System Colors",
            colorScheme: "dark",
            width: 760,
            height: 560,
          })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, null, {
          timeout: 60_000,
        });
        const userTop = () =>
          page.evaluate(() => document.querySelector("[data-row-id$='-user']")!.getBoundingClientRect().top);
        const opened = await userTop();
        const moves = await page.evaluate(
          () =>
            (
              window as unknown as { cmuxGalleryPlayReport?: { steps: { boxMoves: unknown[] }[] } }
            ).cmuxGalleryPlayReport?.steps.flatMap((step) => step.boxMoves) ?? null,
        );
        release();
        await page.locator("diffs-container [data-line]").first().waitFor();
        await page.waitForSelector(".cv-edit-diff__stack[data-painted]");
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
        const painted = await userTop();
        console.log({ variant, moves, opened, painted });
        expect(moves).toEqual([]);
        // Still where it was drawn once the rendered lines replaced the placeholder.
        expect(painted).toBe(opened);
      } finally {
        await page.close();
      }
    },
  );
});
