// cmux-web-test-timeout: 240
// A finished thought is one quiet row, "Thought for 12s" with none of its text inline and no tooltip,
// that opens to its text; thoughts side by side are one row; a quiet one draws none (Leo 2026-10-20).
// The transcript gallery's plays check it in Chromium; this checks they passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-thought.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-thought: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript Thought row", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const ENTRY = "agent-pane.transcript";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // Warm the transcript entry's own frame once, through the optimizer's reloads, before the
    // plays. Each dev-server file starts on a cold server and a Vite cache of its own, so this pays
    // for the whole transcript graph every run. The module crawl this used before followed every
    // lazy import too (3,734 modules, 135-140 s on an idle 8 vCPU fleet runner, 2026-11-03) and ran
    // past its 100 s budget on CI; this load is about 4,100 requests in 76-86 s on the same runner.
    // Its budget is about twice that, and the file's limit (header) leaves a minute for the plays.
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "thought-row" }, timeoutMs: 180_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const play = async (variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(stageURL(variant));
    await page.waitForFunction(() => {
      const ready = document.documentElement.dataset.galleryReady;
      return ready === "1" || ready === "error";
    });
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
    const result = await page.evaluate(() => ({
      play: document.documentElement.dataset.galleryPlay,
      report: JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      searches: (
        window as unknown as { cmuxGalleryLog: { method: string; params?: { query?: string } }[] }
      ).cmuxGalleryLog
        .filter(({ method }) => method === "file.search")
        .map(({ params }) => params?.query),
    }));
    await page.close();
    return result;
  };

  test("a finished thought is one quiet row with none of its text inline, and no tooltip", async () => {
    const result = await play("thought-row");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("a folded thought opens to its full text", async () => {
    const result = await play("thought-expanded");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("thoughts side by side in one step are one row for their summed time", async () => {
    const result = await play("thoughts-merged");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("an empty or short quick thought draws no row", async () => {
    const result = await play("thought-quiet");
    expect(playFailures(result.report)).toEqual([]);
  });

  test("Find marks a word in a thought's text, not its Thought label", async () => {
    const result = await play("thought-find");
    expect(playFailures(result.report)).toEqual([]);
  });
});
