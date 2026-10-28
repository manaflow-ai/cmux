// l10n-allow-file: the gallery fixture supplies the long tool-call transcript.
// A collapsed tool-call group belongs to the transcript's scroll surface. Its rows may be many
// lines tall, but the group itself must not become a second vertical scroller or trap the wheel.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-tool-group-scroll.test.ts", async () => {
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("agent-pane-tool-group-scroll: skipping (run `bunx playwright install chromium`)");
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
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, "agent-pane.transcript", {
      browser,
      params: { variant: "tool-run-scrolled-fade" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("wheel over the collapsed tool rows scrolls the transcript", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.addInitScript(() => localStorage.clear());
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", { variant: "tool-run-scrolled-fade" })}`,
    );
    const worked = page.locator(".cv-worked").first();
    if ((await worked.getAttribute("aria-expanded")) !== "true") await worked.click();
    const runButton = page.locator(".cv-tools > .cv-tool.is-toggle").first();
    await runButton.waitFor();
    if ((await runButton.getAttribute("aria-expanded")) !== "true") await runButton.click();
    const group = page.locator(".cv-tool-run").first();
    await group.waitFor();
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".cv-tool-run");
      return node !== null && node.clientHeight > 0;
    });

    const inner = await group.evaluate((node) => ({
      scrollHeight: node.scrollHeight,
      clientHeight: node.clientHeight,
    }));
    expect(inner.scrollHeight - inner.clientHeight).toBeLessThanOrEqual(1);

    const trailing = await group.locator(".cv-tool.is-toggle .cv-tool__chevron").evaluateAll((nodes) => {
      const values = nodes.map((node) => {
        const button = node.closest<HTMLElement>(".cv-tool")!;
        return button.getBoundingClientRect().right - node.getBoundingClientRect().right;
      });
      return { count: values.length, spread: Math.max(...values) - Math.min(...values) };
    });
    expect(trailing.count).toBeGreaterThan(3);
    expect(trailing.spread).toBeLessThanOrEqual(0.5);

    const transcript = page.locator(".acpmux-scroll");
    await transcript.evaluate((node) => {
      node.scrollTop = 0;
    });
    const before = await transcript.evaluate((node) => node.scrollTop);
    const box = (await group.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + Math.min(box.height / 2, 200));
    await page.mouse.wheel(0, 420);
    await page.waitForFunction(
      (start) => (document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0) > start + 2,
      before,
    );
    expect(await transcript.evaluate((node) => node.scrollTop)).toBeGreaterThan(before + 2);
    expect(await group.evaluate((node) => node.scrollTop)).toBe(0);
    await page.close();
  });
});
