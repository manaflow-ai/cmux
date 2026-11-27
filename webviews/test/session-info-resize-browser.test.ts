// l10n-allow-file: the gallery fixture supplies the prompts.
// The real agent pane over the `agent-pane.session-info-resize` gallery (Leo, 2026-11-10: "It's the
// resizing of the window itself, potentially... Like the size of the window itself being resized or
// whatever. Maybe making a new workspace."): resizing the window across the narrow-pane breakpoint
// either way never opens or closes Session Info, and a new workspace's new chat starts closed. Each
// variant runs in a narrow window (560px, under the 648px breakpoint) and a wide one (1100px).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-resize-browser.test.ts", async () => {
  const ENTRY = "agent-pane.session-info-resize";
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("session-info-resize-browser: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "narrow" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const NARROW = 560;
  const WIDE = 1100;

  async function open(variant: string, width: number, played: boolean): Promise<{ page: Page; failures: string[] }> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height: 640 } });
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
      await page.screenshot({ path: path.join(shots, `session-info-resize-${variant}-${width}.png`) });
    }
    return { page, failures };
  }

  const toggled = (page: Page) =>
    page.evaluate(() => document.querySelector(".acpmux-session-info-toggle")?.getAttribute("aria-pressed") === "true");
  const resizeTo = async (page: Page, width: number, height = 640) => {
    await page.setViewportSize({ width, height });
    await page.waitForFunction(
      (w) => Math.abs((document.querySelector<HTMLElement>(".acpmux-shell")?.clientWidth ?? 0) - w) <= 1,
      width,
    );
    await page.evaluate(
      () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(null)))),
    );
  };

  test("saved open in a narrow pane is held closed; in a wide pane it shows", async () => {
    const narrow = await open("narrow", NARROW, false);
    expect(await toggled(narrow.page)).toBe(false);
    await narrow.page.close();
    const wide = await open("wide", WIDE, false);
    expect(await toggled(wide.page)).toBe(true);
    await wide.page.close();
  });

  test("the window widened past the breakpoint keeps a held Session Info closed", async () => {
    const { page } = await open("narrow", NARROW, false);
    for (const width of [WIDE, NARROW, 1400]) {
      await resizeTo(page, width);
      expect({ width, open: await toggled(page) }).toEqual({ width, open: false });
    }
    await page.close();
  });

  test("the window narrowed and widened again keeps an open Session Info open", async () => {
    const { page } = await open("wide", WIDE, false);
    for (const width of [NARROW, WIDE, 420, 1400]) {
      await resizeTo(page, width);
      expect({ width, open: await toggled(page) }).toEqual({ width, open: true });
    }
    await page.close();
  });

  test("the window made shorter keeps an open Session Info open, over the chat as a popover too", async () => {
    const { page } = await open("wide", WIDE, false);
    // At 700px it lies over the chat (a push would leave the chat too narrow): there a short window
    // makes it a popover, the case a resize closed before.
    const width = 700;
    for (const height of [640, 400, 640, 360]) {
      await resizeTo(page, width, height);
      expect({ height, open: await toggled(page) }).toEqual({ height, open: true });
    }
    expect(await page.locator(".acpmux-session-info[data-popover]").count()).toBe(1);
    await page.close();
  });

  for (const variant of ["after-resize", "opened-then-resized", "new-workspace", "new-chat-resized"])
    for (const width of [NARROW, WIDE])
      test(`${variant} at ${width}px: no resize toggles Session Info`, async () => {
        const { page, failures } = await open(variant, width, true);
        expect(failures).toEqual([]);
        await page.close();
      });
});
