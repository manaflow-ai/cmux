// Address a review comment (cx-ncc.77.3): one click on a review thread's Address sends the agent
// a prompt to address it. The gallery's `agent-pane.diff-panel` `address-thread` play fails unless
// the prompt names the file and line with each comment attributed outside its quote, exactly one
// prompt is sent, and the thread says it was sent, still after a reload.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("changes-address-thread.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("changes-address-thread: skipping (run `bunx playwright install chromium`)");
    describe.skip("address thread", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.diff-panel", { browser, params: { variant: "address-thread" } });
  });

  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.diff-panel", { variant: "address-thread" })}`;

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("Address sends the thread to the chat", async () => {
    const page = await browser!.newPage({ viewport: { width: 860, height: 620 } });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const report = await page.evaluate(() =>
      JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    );
    await page.close();
    // The play throws when the prompt or the thread's state is wrong: the report then has `error`.
    expect((JSON.parse(report ?? "{}") as { error?: string }).error, report).toBeUndefined();
  });
});
