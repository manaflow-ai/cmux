// cmux-web-test-timeout: 300
//
// The Background tasks panel takes the chat's right column, as the side panel does, so the inline
// Summary column (300px beside the transcript, summary/cardState.ts `useSummaryColumn`) gives way
// while it is open, as it does for the side panel: the Summary stays a popover from its button.
// Before, a wide pane kept both columns and squeezed the transcript and composer.
//
// Real Chromium from Playwright on the gallery's agent pane (agent-pane.background-tasks, three
// agents and a summary); CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-tasks-summary-column.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("background-tasks-summary-column: skipping (run `bunx playwright install chromium`)");
    describe.skip("background tasks and the summary column", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.background-tasks";
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

  const open = async (): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1800, height: 900 } });
    for (;;) {
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "closed" })}`);
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
    return page;
  };
  const openPanel = async (page: Page) => {
    await page.getByRole("button", { name: "Chat actions" }).focus();
    await page.keyboard.press("Enter");
    await page.getByRole("menuitem", { name: "Background tasks" }).click();
    await page.locator(".acpmux-bg").waitFor();
  };
  test("the inline Summary column gives way while Background tasks is open", async () => {
    const page = await open();
    try {
      const summary = () => page.locator(".acpmux-main").getAttribute("data-summary");
      // A wide pane with a summary to show: the Summary is an inline column before the panel opens.
      expect(await summary()).toBe("inline");
      await openPanel(page);
      await page.waitForFunction(
        () => document.querySelector(".acpmux-main")?.getAttribute("data-summary") !== "inline",
      );
      expect(await summary()).toBe("popover");
      await page.locator(".acpmux-bg__head").getByRole("button", { name: "Close" }).click();
      await page.waitForFunction(
        () => document.querySelector(".acpmux-main")?.getAttribute("data-summary") === "inline",
      );
    } finally {
      await page.close();
    }
  });
});
