// l10n-allow-file: browser fixtures and measurement diagnostics.
// A running turn scrolled away from its end, when the agent's next call arrives (Leo, 2026-11-08:
// "if i have a tool call expanded, the auto folding situation shouldn't collapse it when a new tool
// call comes in and the folds reformat"). Under live-turn-work `line` (the scenes pin it) a running turn
// draws no finished run, only its reply and one live line (turns.ts `codexRuns`), so the next call
// regroups nothing in view: the reply the reader reads stays on the same pixel. At the turn's end in
// the group scene the view's offset holds; the reply moves down by the work the end draws above it. Real Chromium plays the tool-group entry's scenes
// (pinnedToolRowsScenes.ts) on the real transcript and reads where the reply was before and after.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("pinned-tool-rows-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const entry = "agent-pane.tool-group-size";
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
    await warmGalleryFrame(gallery, entry, { browser, params: { variant: "pinned-lone" } });
  });
  afterAll(async () => {
    await browser?.close();
    await gallery?.close();
  });

  // Under live-turn-work `line` (the scenes pin it) a running turn draws no finished run (turns.ts
  // `codexRuns`): the next call moves nothing the reader reads, and neither does the turn's end.
  const titles: Record<string, string> = {
    "pinned-lone": "the next call draws no run and moves nothing in view",
    "pinned-below": "the next call under the view's foot moves nothing in view",
    "pinned-group": "the next call moves nothing in view, and the turn's end keeps the view's offset",
  };
  for (const variant of ["pinned-lone", "pinned-group", "pinned-below"])
    test(`${variant}: ${titles[variant]}`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        await page.addInitScript(() => localStorage.clear());
        const port = (gallery.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}` + galleryFrame(entry, { variant }));
        await page.waitForFunction(
          () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          undefined,
          { timeout: 120_000 },
        );
        const seen = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady,
          play: window.cmuxGalleryPlayReport,
          pinned: window.cmuxPinnedToolRows,
        }));
        console.log(`PINNED_TOOL_ROWS ${variant} ${JSON.stringify(seen.pinned)}`);
        if (seen.play?.status !== "pass") console.log(`PINNED_TOOL_ROWS_PLAY ${variant} ${JSON.stringify(seen.play)}`);
        expect(seen.pinned).toBeDefined();
        expect(seen.pinned!.line).toBe(true);
        expect(seen.pinned!.runs).toBe(0);
        if (variant === "pinned-below")
          // Under the view's foot: the call moves with its row; the text the reader reads does not.
          expect(Math.abs(seen.pinned!.scrollAfter - seen.pinned!.scrollBefore)).toBeLessThanOrEqual(1);
        else expect(Math.abs(seen.pinned!.after - seen.pinned!.before)).toBeLessThanOrEqual(1);
        // Away from the end: the view is the reader's, not following the latest row.
        expect(seen.pinned!.fromEnd).toBeGreaterThan(40);
        if (variant === "pinned-group") {
          // The turn ended and its run folded: the call the reader opened stays open, on its pixel.
          expect(seen.pinned!.ended).toBeDefined();
          expect(Math.abs(seen.pinned!.ended!.scrollAfter - seen.pinned!.scrollAfter)).toBeLessThanOrEqual(1);
        }
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
