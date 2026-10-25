// Hover action rows keep their lane while the pointer travels from the message through each
// button. User-style agent/subsession prompts keep their metadata under the bubble's right edge.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-hover-actions.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-hover-actions: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.incoming-message", { browser, params: { variant: "hover-actions" } });
    await warmGalleryFrame(vite, "agent-pane.user-bubble", { browser, params: { variant: "hover-actions" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("received row stays active over every action and keeps the lane aligned", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.incoming-message", { variant: "hover-actions" })}`);
    const row = page.locator("[data-hover-action-fixture] .cv-received").first();
    const line = row.locator(".cv-received__line");
    const actions = row.locator(".cv-received-actions");
    await row.waitFor();
    await line.hover();
    await expect(actions).toHaveCSS("opacity", "1");
    const actionCount = await actions.locator("button").count();
    expect(actionCount).toBeGreaterThan(0);
    for (let index = 0; index < actionCount; index++) {
      const button = actions.locator("button").nth(index);
      await button.hover();
      await expect(actions).toHaveCSS("opacity", "1");
      expect(await row.evaluate((node) => node.matches(":hover"))).toBe(true);
    }
    const edges = await page.evaluate(() => {
      const lane = document.querySelector<HTMLElement>("[data-hover-action-fixture] .cv-received-actions")!;
      const line = document.querySelector<HTMLElement>("[data-hover-action-fixture] .cv-received__line")!;
      const rect = (node: HTMLElement) => node.getBoundingClientRect();
      return { laneRight: rect(lane).right, lineRight: rect(line).right };
    });
    expect(Math.abs(edges.lineRight - edges.laneRight)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("user-style agent prompts right-align their action row under the bubble", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.user-bubble", { variant: "hover-actions" })}`);
    const bubble = page.locator("[data-hover-action-fixture] .cv-user__bubble").last();
    const actions = page.locator("[data-hover-action-fixture] .cv-user__actions").last();
    await bubble.waitFor();
    await bubble.hover();
    const edges = await Promise.all([
      bubble.boundingBox(),
      actions.boundingBox(),
    ]);
    expect(edges[0]).not.toBeNull();
    expect(edges[1]).not.toBeNull();
    expect(Math.abs(edges[0]!.x + edges[0]!.width - (edges[1]!.x + edges[1]!.width))).toBeLessThanOrEqual(1);
    await page.close();
  });
});
