// Reply tables at chat width (Leo 2026-11-05, a status table clipped mid-word): every gallery
// state at three pane widths, and each actions arm hovered. A table whose words can wrap fits its
// column and never scrolls sideways; only the unbreakable one may, and then its edge fades. The screenshots go to
// $FAST_CHECKS_OUT for a before/after (cmux-ci test --artifact).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-table-capture.test.ts", async () => {
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT ?? path.resolve(webviews, "../artifacts/fleet/table-capture");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const port = () => (vite!.httpServer!.address() as { port: number }).port;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.table-block", { browser, params: { variant: "status", width: 640 } });
    await mkdir(out, { recursive: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const cases: { variant: string; width: number; arm?: string }[] = [];
  for (const width of [480, 640, 960])
    for (const variant of ["status", "status-hover", "first-block", "unbreakable"]) cases.push({ variant, width });
  for (const arm of ["corner", "above", "beside"]) cases.push({ variant: "status-hover", width: 640, arm });

  describe("reply table captures", () => {
    for (const { variant, width, arm } of cases)
      test(`${variant} at ${width}${arm ? ` (${arm})` : ""}`, async () => {
        const page = await browser!.newPage({ viewport: { width, height: 760 }, deviceScaleFactor: 2 });
        await page.goto(
          `http://127.0.0.1:${port()}${galleryFrame("agent-pane.table-block", { variant, width, arm, exp: arm ? "table-actions-place" : undefined })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        const block = page.locator(".cv-table-block").first();
        await block.waitFor();
        if (variant !== "status") {
          await block.hover();
          await page.waitForFunction(
            () => getComputedStyle(document.querySelector(".cv-table-tools")!).opacity === "1",
          );
        }
        await page.screenshot({ path: path.join(out, `${variant}-${width}${arm ? `-${arm}` : ""}.png`) });
        const m = await page.evaluate(() => {
          const block = document.querySelector<HTMLElement>(".cv-table-block")!;
          const wrap = block.querySelector<HTMLElement>(".cv-table-wrap")!;
          const column = block.parentElement!.getBoundingClientRect();
          const overflowing = [...block.querySelectorAll<HTMLElement>("td, th")].filter(
            (cell) => cell.scrollWidth > cell.clientWidth + 1,
          ).length;
          return {
            block: block.getBoundingClientRect().right,
            column: column.right,
            sideways: wrap.scrollWidth - wrap.clientWidth,
            moreRight: wrap.hasAttribute("data-more-right"),
            overflowing,
          };
        });
        console.log(`${variant}@${width}${arm ? `/${arm}` : ""}`, JSON.stringify(m));
        expect(m.overflowing).toBe(0);
        expect(m.block).toBeLessThanOrEqual(m.column + 0.5);
        // Paths break at their slashes and a 40-character hash fits at 480 px, so the
        // unbreakable table may fit too; whenever one does scroll, its edge says so.
        if (variant !== "unbreakable") expect(m.sideways).toBeLessThanOrEqual(0.5);
        else if (m.sideways > 0.5) expect(m.moreRight).toBe(true);
        await page.close();
      });
  });
});
