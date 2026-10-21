// Stage hunk's key (cx-ncc.74): in Unstaged, n moves between changes and s stages the hunk it
// stopped at. The gallery's `agent-pane.diff-panel` `stage-hunk` play presses n, n, s and fails
// unless the source got the second hunk alone; this runs the play in Chromium.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("changes-stage-hunk-keys.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("changes-stage-hunk-keys: skipping (run `bunx playwright install chromium`)");
    describe.skip("stage hunk keys", () => test("chromium", () => {}));
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
    await warmGalleryFrame(vite, "agent-pane.diff-panel", { browser, params: { variant: "stage-hunk" } });
  });

  const url = () =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.diff-panel", { variant: "stage-hunk" })}`;

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("n then s stages the hunk n stopped at", async () => {
    const page = await browser!.newPage({ viewport: { width: 860, height: 620 } });
    await page.goto(url());
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
    }));
    await page.close();
    // The play throws when s staged anything but the second hunk: the report then has `error`.
    // Its status also folds in the stage's own measures of each step, and switching to Unstaged
    // replaces the files (a layout shift, a cold page's long frame), which is not what this tests.
    const report = JSON.parse(result.report ?? "{}") as { error?: string; steps?: { step: string }[] };
    expect(report.error, result.report).toBeUndefined();
    expect(report.steps?.map((step) => step.step).slice(-3), result.report).toEqual(["press n", "press n", "press s"]);
  });
});
