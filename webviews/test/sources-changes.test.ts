// The chat's summary card holds the last turn's diffs (cx-ncc.43). In Chromium on the gallery
// stage, a turn that edited fourteen files:
// - the card's Outputs section lists the turn's files, each with its own counts, in the
//   scrollable card (Changes is the one totals row, hq#2569 item 4);
// - a file there opens the turn's diff at that file, and the card hides behind the diff review.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("sources-changes.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("sources-changes: skipping (run `bunx playwright install chromium`)");
    describe.skip("sources changes", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stage = async (entry: string, variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 0; ; attempt += 1) {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        return page;
      } catch (error) {
        // The first load can hit Vite's dependency optimizer, which reloads the page once.
        if (attempt > 1 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  };

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.edited-files", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the summary card lists the turn's changed files and opens each one's diff", async () => {
    const page = await stage("agent-pane.edited-files", "fourteen-files");
    await page.click(".acpmux-summary-button");
    const section = page.locator(".acpmux-summary-card section", { has: page.locator(".acpmux-summary-file") });
    await section.waitFor();
    const files = section.locator(".acpmux-summary-file");
    expect(await files.count()).toBe(14);
    // Each row names its file and carries its own counts.
    const pick = files.filter({ hasText: "jitter/exponential.ts" });
    expect(await pick.count()).toBe(1);
    expect((await pick.innerText()).replace(/\s+/g, " ")).toMatch(/\+\d+/);
    await pick.click();
    // The card is not a popover: it stays, hidden only while the diff review covers the stage.
    await page.waitForSelector(".acpmux-summary-card", { state: "hidden" });
    await page.waitForSelector(".acpmux-diff-panel");
    // The diff opens at that file: its section is the one at the top of the diff body.
    await page.waitForFunction(() => {
      const body = document.querySelector(".acpmux-diff-body");
      const file = [...document.querySelectorAll<HTMLElement>(".acpmux-diff-file")].find((node) =>
        node.dataset.path?.endsWith("jitter/exponential.ts"),
      );
      return Boolean(body && file && Math.abs(file.getBoundingClientRect().top - body.getBoundingClientRect().top) < 8);
    });
    await page.close();
  });
});
