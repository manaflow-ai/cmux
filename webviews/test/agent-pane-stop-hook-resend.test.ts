// l10n-allow-file: test fixture replies, not shipped UI.
// Leo, 2026-11-14, on the same "A few updates:" report drawn twice back to back in his chat: "why did
// u send this twice?". The gallery's `agent-pane.revised-reply` `recorded` variant replays the turn
// as acpmux records it (a reply, a Stop hook's block, the reply again with one line changed) through
// the pane's own client in real Chromium; its play checks that one reply shows, the new one, and that
// the muted Revised under it opens the first (RevisedReply.gallery.ts `checkRevised`).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-stop-hook-resend.test.ts", async () => {
  setDefaultTimeout(120_000);
  const ENTRY = "agent-pane.revised-reply";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-stop-hook-resend: skipping (run `bunx playwright install chromium`)");
    describe.skip("stop hook resend", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a reply sent again after a Stop hook shows once, and Revised opens the first", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "recorded" })}`);
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    // Outside the play too: the transcript draws the reply's heading once, the opened first version aside.
    const headings = await page.evaluate(() => {
      const copy = document.body.cloneNode(true) as HTMLElement;
      for (const earlier of copy.querySelectorAll(".cv-revised__earlier")) earlier.remove();
      return (copy.textContent?.match(/A few updates:/g) ?? []).length;
    });
    await page.close();
    expect(playFailures(report)).toEqual([]);
    expect(headings).toBe(1);
  });
});
