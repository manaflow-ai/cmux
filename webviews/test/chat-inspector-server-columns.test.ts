// Dev-server status dots keep the same leading icon column as Background task rows. This is a
// rendered geometry contract: the status mark stays seven pixels, while its slot and text start
// line up with the fourteen-pixel task icon.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-inspector-server-columns.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-inspector-server-columns: skipping (run `bunx playwright install chromium`)");
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

  test("server status and task command columns share their icon slot", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 420, height: 900 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.chat-inspector", { variant: "full", theme: "light" })}`,
    );
    await page.locator(".acpmux-chat-inspector-server__dot").first().waitFor();
    const metrics = await page
      .locator(".acpmux-chat-inspector-server")
      .first()
      .evaluate((server) => {
        const dot = server.querySelector<HTMLElement>(".acpmux-chat-inspector-server__dot")!;
        const text = server.querySelector<HTMLElement>(".acpmux-chat-inspector-server__text")!;
        const task = document.querySelector<HTMLElement>(".acpmux-chat-inspector-task__open")!;
        const icon = task.querySelector<SVGElement>(":scope > svg")!;
        const taskText = task.querySelector<HTMLElement>(".acpmux-chat-inspector-task__command")!;
        const dotBox = dot.getBoundingClientRect();
        const iconBox = icon.getBoundingClientRect();
        return {
          dotWidth: dotBox.width,
          dotCenter: dotBox.left + dotBox.width / 2,
          iconCenter: iconBox.left + iconBox.width / 2,
          serverText: text.getBoundingClientRect().left,
          taskText: taskText.getBoundingClientRect().left,
        };
      });
    expect(metrics.dotWidth).toBe(7);
    expect(Math.abs(metrics.dotCenter - metrics.iconCenter)).toBeLessThanOrEqual(0.5);
    expect(Math.abs(metrics.serverText - metrics.taskText)).toBeLessThanOrEqual(0.5);
    await page.close();
  });
});
