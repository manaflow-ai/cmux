// cmux-web-test-timeout: 180
// These are mounted New Tab gallery interactions: a rendered screenshot alone can miss a thrown
// play, so keep the final play receipt and the user-visible state together.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-gallery-reached.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const entries = ["agent-pane.new-tab-headline", "agent-pane.new-tab"];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entries, { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant] of [
    ["agent-pane.new-tab-headline", "picked"],
    ["agent-pane.new-tab-headline", "picker-open"],
    ["agent-pane.new-tab", "attachment-menu"],
    ["agent-pane.new-tab", "style-switch"],
  ] as const) {
    test(`${entry}#${variant} reaches its mounted interaction`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 1000, height: 800 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
          timeout: 90_000,
        });
        const receipt = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady,
          report: (
            window as unknown as {
              cmuxGalleryPlayReport?: {
                status?: string;
                error?: string;
                steps?: Array<{
                  step?: string;
                  layoutShift?: number;
                  problems?: string[];
                  popupProblems?: string[];
                  anchorMoves?: unknown[];
                }>;
              };
            }
          ).cmuxGalleryPlayReport,
          headline: document.querySelector(".nt-headline-text")?.textContent ?? "",
          menu: document.querySelector(".acpmux-project-menu") !== null,
          attach: document.querySelector(".acpmux-newtab-plus [data-value=attach]") !== null,
          multi: document.querySelector<HTMLInputElement>(".nt-composer .acpmux-attach-input")?.multiple ?? false,
          threads: document.querySelector(".nt-style input[value=threads]:checked") !== null,
        }));
        expect(receipt.ready).toBe("1");
        expect(receipt.report?.error).toBeUndefined();
        const steps = receipt.report?.steps ?? [];
        expect(steps.length).toBeGreaterThan(0);
        for (const step of steps) {
          expect(step.popupProblems ?? []).toEqual([]);
          expect(step.anchorMoves ?? []).toEqual([]);
        }
        // Graded as every play test is (support/galleryPlay.ts): a thrown play, a moved anchor and a
        // layout shift fail it; the runner's frame timing does not (cx-mfkky). Picking a project
        // keeps its layout too, at CLS 0 (#26850; new-tab-headline-selection-cls.test.ts).
        expect(playFailures(JSON.stringify(receipt.report))).toEqual([]);
        if (variant === "picked" || variant === "picker-open") {
          expect(receipt.headline).toContain("cmux");
          expect(receipt.menu).toBe(variant === "picker-open");
        }
        if (variant === "attachment-menu") {
          expect(receipt.attach).toBe(true);
          expect(receipt.multi).toBe(true);
        }
        if (variant === "style-switch") expect(receipt.threads).toBe(true);
      } finally {
        await page.close();
      }
    });
  }
});
