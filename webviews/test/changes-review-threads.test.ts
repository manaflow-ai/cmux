// Review comments in the Changes view (cx-ncc.77.2): Branch shows the pull request's review
// threads under their lines. The gallery's `agent-pane.diff-panel` `review-threads` play fails
// unless the open and resolved threads sit in the diff (the resolved one folded), the outdated
// and moved ones above their file, and one on an unlisted file in its own group.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("changes-review-threads.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("changes-review-threads: skipping (run `bunx playwright install chromium`)");
    describe.skip("review threads", () => test("chromium", () => {}));
    return;
  }

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
    await warmGalleryFrame(vite, "agent-pane.diff-panel", { browser, params: { variant: "review-threads" } });
  });

  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.diff-panel", { variant: "review-threads" })}`;

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("each review thread sits under its line, or above when its line is gone or moved", async () => {
    const page = await browser!.newPage({ viewport: { width: 860, height: 620 } });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    // The play throws when a thread is missing or misplaced: the report then has `error`.
    expect((JSON.parse(report ?? "{}") as { error?: string }).error, report).toBeUndefined();
  });
});
