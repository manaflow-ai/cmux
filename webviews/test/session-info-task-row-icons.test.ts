// cmux-web-test-timeout: 300
//
// Background tasks' row glyphs (a command's >_, a wakeup's clock, a cron job's arrow, a server's
// globe) draw at the row text's icon size, fitted, in Session Info's one icon column (Leo,
// 2026-11-07, of a wakeup's clock: "this is too big"). Before, a blanket rule forced each one to the
// full 16px box with the row crop and no fit, and the clock's ring ran past every Environment glyph.
//
// Real Chromium from Playwright on the gallery stage agent-pane.session-info-task-row-icons;
// CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-task-row-icons.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-task-row-icons: skipping (run `bunx playwright install chromium`)");
    describe.skip("Session Info task row icons", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.session-info-task-row-icons";
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
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("every task glyph is the row text's icon size, no larger than Environment's, on its column", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 700, height: 600 } });
    try {
      for (;;) {
        try {
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "fit-14" })}`);
          await page.waitForFunction(
            () => {
              const root = document.documentElement.dataset;
              return root.galleryReady === "error" || (root.galleryReady === "1" && Boolean(root.galleryPlay));
            },
            undefined,
            { timeout: 90_000 },
          );
          break;
        } catch (error) {
          if (!/context was destroyed|navigat/i.test(String(error))) throw error;
        }
      }
      // The stage's own play holds the ink and column rules; it reports a broken one as `error`.
      const play = await page.evaluate(
        () => (window as unknown as { cmuxGalleryPlayReport?: { error?: string } }).cmuxGalleryPlayReport,
      );
      expect(play?.error).toBeUndefined();
      const measured = await page.evaluate(() => {
        const box = (svg: Element) => {
          const rect = svg.getBoundingClientRect();
          return {
            icon: (svg as SVGElement).dataset.icon,
            width: rect.width,
            height: rect.height,
            center: rect.left + rect.width / 2,
          };
        };
        const env = [...document.querySelectorAll(".acpmux-session-info-row > svg[data-icon]")].map(box);
        const tasks = [
          ...document.querySelectorAll(
            ":is(.acpmux-session-info-task, .acpmux-session-info-task__open) > svg.acpmux-row-glyph",
          ),
        ].map((svg) => ({ ...box(svg), fitted: svg.getAttribute("viewBox") !== "2.5 2.5 19 19" }));
        return { env, tasks };
      });
      expect(measured.env.length).toBeGreaterThan(0);
      expect(measured.tasks.map((task) => task.icon).sort((a, b) => String(a).localeCompare(String(b)))).toEqual([
        "automation",
        "history",
        "link.web",
        "terminal.prompt",
      ]);
      const column = measured.env[0]!.center;
      for (const task of measured.tasks) {
        // rowIconSize(12): the 14px step of the icon scale, for a 12-13px label.
        expect({ icon: task.icon, width: task.width, height: task.height, fitted: task.fitted }).toEqual({
          icon: task.icon,
          width: 14,
          height: 14,
          fitted: true,
        });
        expect(Math.abs(task.center - column)).toBeLessThanOrEqual(0.5);
      }
    } finally {
      await page.close();
    }
  });
});
