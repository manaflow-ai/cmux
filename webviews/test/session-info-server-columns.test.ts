// A dev server is a Background task row of its own (ServersSection.tsx): its globe and its address sit
// in the same icon and text columns as a command task's glyph and command. This is a rendered geometry
// contract: the glyphs share their column and the texts start at one edge.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-server-columns.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-server-columns: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.chat-inspector", {
      browser,
      params: { variant: "full", theme: "light" },
    });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["light", "dark"] as const)
    test(`${theme}: server status and task command columns share their icon slot`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "full", theme })}`,
      );
      const server = page
        .locator('.acpmux-session-info-task[data-kind="server"] .acpmux-session-info-task__open')
        .first();
      await server.waitFor();
      const metrics = await server.evaluate((row) => {
        const task = document.querySelector<HTMLElement>(
          '.acpmux-session-info-task--command:not([data-kind="server"]) .acpmux-session-info-task__open',
        )!;
        const glyph = (button: Element) =>
          button.querySelector<SVGElement>(".acpmux-row-glyph")!.getBoundingClientRect();
        const serverIcon = glyph(row);
        const taskIcon = glyph(task);
        return {
          serverIcon: serverIcon.left + serverIcon.width / 2,
          taskIcon: taskIcon.left + taskIcon.width / 2,
          serverText: row.querySelector<HTMLElement>(".acpmux-session-info-task__address")!.getBoundingClientRect()
            .left,
          taskText: task.querySelector<HTMLElement>(".acpmux-session-info-task__command")!.getBoundingClientRect().left,
        };
      });
      expect(Math.abs(metrics.serverIcon - metrics.taskIcon)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(metrics.serverText - metrics.taskText)).toBeLessThanOrEqual(0.5);
      await page.close();
    });
});
