// l10n-allow-file: the gallery fixture supplies the prompts.
// The real agent pane over the `agent-pane.local-commands` gallery (Leo, 2026-11-10: "session info
// should NOT open by defualt on starting new chat / and typing /mcp or /status on its own should NOT
// queue/steer and wait behind"): a new chat shows Session Info closed; /status and /mcp typed alone
// while a turn runs show their answer at once and add nothing to the queue.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("local-commands-gallery-browser.test.ts", async () => {
  const ENTRY = "agent-pane.local-commands";
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("local-commands-gallery-browser: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const shots = process.env.FAST_CHECKS_OUT;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "new-chat-info-closed" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, played: boolean): Promise<{ page: Page; failures: string[] }> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1100, height: 640 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    let failures: string[] = [];
    if (played) {
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
        timeout: 90_000,
      });
      const report = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      );
      failures = playFailures(report);
    } else {
      await page.waitForSelector("[role=combobox]", { timeout: 90_000 });
      await page.waitForSelector(".acpmux-session-info-toggle", { timeout: 30_000 });
    }
    if (shots) {
      fs.mkdirSync(shots, { recursive: true });
      await page.screenshot({ path: path.join(shots, `local-commands-${variant}.png`) });
    }
    return { page, failures };
  }

  const queued = (page: Page) => page.locator(".acpmux-composer-queue .acpmux-queued").count();
  const sessionInfoShown = (page: Page) =>
    page.evaluate(() => {
      const panel = document.querySelector(".acpmux-session-info[data-presence=shown]");
      return !!panel && panel.getBoundingClientRect().width > 0;
    });

  test("a new chat starts with Session Info closed", async () => {
    const { page } = await open("new-chat-info-closed", false);
    // Session Info is on (its toggle is in the header), and closed.
    await page.waitForSelector(".acpmux-session-info-toggle", { timeout: 30_000 });
    expect(await sessionInfoShown(page)).toBe(false);
    await page.close();
  });

  test("/status typed alone mid-turn shows the status card at once; the queue gains nothing", async () => {
    const { page, failures } = await open("status-mid-turn", true);
    expect(failures).toEqual([]);
    expect(await page.locator(".acpmux-harness-status").count()).toBe(1);
    expect(await queued(page)).toBe(1);
    await page.close();
  });

  test("/mcp typed alone mid-turn opens Session Info at once; the queue gains nothing", async () => {
    const { page, failures } = await open("mcp-mid-turn", true);
    expect(failures).toEqual([]);
    expect(await sessionInfoShown(page)).toBe(true);
    expect(await queued(page)).toBe(1);
    await page.close();
  });

  test("the queue next to them: what the person queued stays", async () => {
    const { page } = await open("queue-beside", false);
    expect(await queued(page)).toBe(2);
    await page.close();
  });
});
