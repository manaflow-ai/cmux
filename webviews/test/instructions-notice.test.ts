// The chat menu's Edit CLAUDE.md (cx-ncc.65) when the app refuses to open the file: the pane says
// why above the composer, with Retry and Dismiss, instead of nothing happening (cx-bopcl).
// The gallery play answers the host call with a refusal in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("instructions-notice.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("instructions-notice: skipping (run `bunx playwright install chromium`)");
    describe.skip("instructions notice", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.instructions-notice", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a refused Edit CLAUDE.md says why, retries and dismisses", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    // A busy runner (dev server files run side by side, #19831): opening the chat menu drew one
    // 80-90 ms frame there. The same frame here, every run.
    await page.addInitScript(() => {
      document.addEventListener(
        "click",
        (event) => {
          if ((event.target as Element | null)?.closest?.('[aria-label="Chat actions"]')) {
            const until = performance.now() + 120;
            while (performance.now() < until) {}
          }
        },
        true,
      );
    });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.instructions-notice", { variant: "outside-folder" })}`,
    );
    // The first page waits on a cold Vite compiling the gallery, past 30 s on a busy runner.
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
      timeout: 90_000,
    });
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    // The play checks the behavior: the alert says why, Retry asks the host again, Dismiss clears it.
    expect(playFailures(report)).toEqual([]);
    expect((JSON.parse(report ?? "{}") as { steps?: unknown[] }).steps?.length, report).toBe(4);
  });
});
