// History > Team's key column reads in full: the team-audit gallery's variants at the entry's narrow
// (380) and wide (960) widths, in a real engine, so the check covers the table's CSS geometry. The
// key column takes the room the measures leave and never less than 12ch; a long name ellipsizes only
// past that, and a pane too narrow for both scrolls the table sideways instead of cutting names
// (review of #39345: a max-width: 0 column showed "Person" as "P"). Screenshots go to
// $FAST_CHECKS_OUT when it is set.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-team-audit-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-team-audit-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("team audit key column", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.team-audit";
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, width })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "loaded", width: 960 } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 620 }, deviceScaleFactor: 2 });
    for (;;) {
      try {
        await page.goto(url(variant, width));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.locator(".tma-table tbody tr").first().waitFor();
    return page;
  };

  const out = process.env.FAST_CHECKS_OUT;
  for (const variant of ["loaded", "by-model", "not-admin"])
    for (const width of [380, 960])
      test(`${variant} at ${width}px: every key reads in full`, async () => {
        const page = await open(variant, width);
        const keys = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>(".tma-key-text")].map((label) => ({
            text: label.textContent ?? "",
            cut: label.scrollWidth > label.clientWidth + 1,
            width: label.clientWidth,
            ch: parseFloat(getComputedStyle(label).minWidth),
          })),
        );
        if (out) {
          await mkdir(out, { recursive: true });
          await page.screenshot({ path: path.join(out, `team-audit-${variant}-${width}.png`), fullPage: true });
        }
        await page.close();
        expect(keys.length).toBeGreaterThan(1);
        expect(keys.filter((key) => key.cut)).toEqual([]);
        // Never narrower than its 12ch minimum, at either width.
        for (const key of keys) expect(key.width).toBeGreaterThanOrEqual(Math.floor(key.ch));
      });
});
