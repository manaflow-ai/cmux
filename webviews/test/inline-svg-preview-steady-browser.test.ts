// l10n-allow-file: the gallery fixtures supply the transcript's messages.
// A reply's ```svg fence previewed inline (InlinePreview.tsx) draws at its final height in the
// frame it first draws in: opening a chat that holds one moves no row. The preview's frame reports
// its document's height only after it loads, so a card that waited for that report opened at the
// frame's 48 px floor (and with no frame at all until it neared the viewport) and then grew by the
// image's height, pushing the reply up and its footer down. That was the gallery's largest layout
// shift a reader sees in the app (agent-pane.artifact-panel#svg, 0.63 in shift-baseline.json).
// An SVG image's height is known from its own width, height and viewBox, so the card holds it from
// its first frame. Each case reads the stage's load report (box shift, shift.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("inline-svg-preview-steady-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("inline-svg-preview-steady-browser: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.inline-preview", { browser, params: { variant: "svg-bar-chart" } });
    await warmGalleryFrame(vite, "agent-pane.artifact-panel", { browser, params: { variant: "svg" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Load = { boxShift: number; layoutShift: number; boxMoves: { label: string; dy: number }[] };
  async function load(entry: string, variant: string, width: number): Promise<Load> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 640 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, frame: "component", width })}`);
    // The stage writes its load report once the page has settled (the frame's height report included).
    await page.waitForFunction(
      () => Boolean((window as unknown as { cmuxGalleryLoadReport?: unknown }).cmuxGalleryLoadReport),
      undefined,
      { timeout: 90_000 },
    );
    const report = (await page.evaluate(
      () => (window as unknown as { cmuxGalleryLoadReport: Load }).cmuxGalleryLoadReport,
    )) as Load;
    await page.close();
    return report;
  }

  // The SVG of a reply with a viewBox only (it fills the card's width), and one with its own width and
  // height (drawn at its size), at the pane's normal and narrow widths.
  for (const [entry, variant] of [
    ["agent-pane.artifact-panel", "svg"],
    ["agent-pane.inline-preview", "svg-bar-chart"],
  ] as const)
    for (const width of [760, 420])
      test(`${entry}#${variant} at ${width}px opens with no row moving`, async () => {
        const report = await load(entry, variant, width);
        expect({ boxShift: report.boxShift, moves: report.boxMoves.slice(0, 4) }).toEqual({ boxShift: 0, moves: [] });
      });
});
