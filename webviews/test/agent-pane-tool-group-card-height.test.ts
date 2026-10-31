// l10n-allow-file: deterministic geometry assertions for the tool-group fixture.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-tool-group-card-height.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-tool-group-card-height: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.tool-group-card-height", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("an expanded two-row group card ends at its last row at transcript end", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 680 } });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.tool-group-card-height", { variant: "default" })}`,
    );
    const toggle = page.locator(".cv-tool[data-tool-group]").first();
    await toggle.waitFor();
    await page.waitForFunction(
      () => document.querySelector(".cv-tool[data-tool-group]")?.getAttribute("aria-expanded") === "false",
    );
    await toggle.click();
    await page.waitForFunction(
      () => document.querySelector(".cv-tool[data-tool-group]")?.getAttribute("aria-expanded") === "true",
    );
    await page.waitForFunction(
      () => document.querySelector<HTMLElement>(".cv-fold")?.getAnimations().length === 0,
    );
    const card = page.locator(".cv-steps");
    await card.waitFor();
    const geometry = await card.evaluate((node) => {
      const card = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      const steps = [...node.querySelectorAll<HTMLElement>(":scope > .cv-step")].map((step) =>
        step.getBoundingClientRect(),
      );
      const last = steps.at(-1)!;
      const transcript = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return {
        cardHeight: card.height,
        contentHeight: last.bottom - card.top,
        trailing: card.bottom - last.bottom,
        cardBottomFromTranscriptBottom: transcript.bottom - card.bottom,
        border: style.borderTopWidth,
      };
    });
    expect(Number.parseFloat(geometry.border)).toBeGreaterThan(0);
    expect(geometry.cardHeight).toBeGreaterThan(0);
    expect(geometry.trailing).toBeLessThanOrEqual(1.5);
    expect(Math.abs(geometry.cardHeight - geometry.contentHeight)).toBeLessThanOrEqual(1.5);
    expect(geometry.cardBottomFromTranscriptBottom).toBeGreaterThan(1);
    await page.close();
  });
});
