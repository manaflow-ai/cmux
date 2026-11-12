// l10n-allow-file: browser fixtures and measurement diagnostics.
// The turn's two levels in Chromium (TurnLevels.gallery.ts): the opened outer "Worked for" line
// counts every call, each run between the agent's asides has its own line and count, and an inner
// line the reader opens stays open while the outer stays open. Writes each arm's capture to
// $FAST_CHECKS_OUT for the PR (Leo, 2026-11-07: "do you think we should distinguish the absolute top
// level one versus the inner ones that are interrupted by your little asides in between?").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("turn-levels-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const output = process.env.FAST_CHECKS_OUT;
  const webviews = path.resolve(import.meta.dir, "..");
  const entry = "agent-pane.turn-levels";
  const { createServer } = await import("vite");
  let gallery: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    gallery = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await gallery.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(gallery, entry, { browser, params: { variant: "outer-line" } });
    if (output) await mkdir(output, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await gallery?.close();
  });

  const lines = (page: import("playwright").Page) =>
    page.locator(".cv-tool.is-run .cv-tool__summary").allTextContents();

  for (const variant of ["outer-line", "indented", "guide", "live"])
    for (const colorScheme of ["light", "dark"])
      test(`${variant} (${colorScheme}): the outer line counts the turn, each run between asides its own`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2 });
        const errors: string[] = [];
        page.on("pageerror", (error) => errors.push(error.message));
        try {
          const port = (gallery.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}` + galleryFrame(entry, { variant, colorScheme, frame: "component" }),
          );
          await page.waitForFunction(() =>
            ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          );
          expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
          const live = variant === "live";
          await page.locator(".cv-tool.is-run").first().waitFor();
          const runs = (await lines(page)).map((text) => text.trim());
          console.log(`TURN_LEVELS ${JSON.stringify({ variant, colorScheme, runs })}`);
          const outers = (await page.locator(".cv-worked").allTextContents()).join(" | ");
          console.log(`TURN_LEVELS_OUTER ${variant} ${outers}`);
          if (live) {
            expect(runs).toEqual(["Ran 4 commands and read a file", "Ran 3 commands"]);
            expect(await page.locator(".cv-tool.is-run").count()).toBe(2);
            expect(await page.locator('.cv-tool.is-run[aria-expanded="true"]').count()).toBe(0);
            expect(await page.locator("output.cv-thinking").count()).toBe(1);
            expect(outers).not.toContain("Worked for");
          } else {
            // 4 commands and a read, then 3 commands after the first aside; the lone call after the
            // second aside is a row of its own.
            expect(runs).toEqual(["Ran 4 commands and read a file", "Ran 3 commands"]);
            const outer = (await page.locator(".cv-worked").textContent())?.trim() ?? "";
            expect(outer).toMatch(/^Worked for 2m 17s · 9 tool calls/);
            expect(await page.locator(".cv-tool-note").count()).toBeGreaterThanOrEqual(1);
          }
          // Toggle the later line: it keeps the reader's state (the outer stays open around it). An
          // ended and running turn's run lines both keep a reader's choice.
          {
            const later = page.locator(".cv-tool.is-run").nth(1);
            await later.click();
            expect(await later.getAttribute("aria-expanded")).toBe("true");
            // Two painted frames: a regrouping or store write after the click would have drawn by then.
            await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
            expect(await later.getAttribute("aria-expanded")).toBe("true");
          }
          if (output) await page.screenshot({ path: path.join(output, `turn-levels-${variant}-${colorScheme}.png`) });
          expect(errors).toEqual([]);
        } finally {
          await page.close();
        }
      });
});
