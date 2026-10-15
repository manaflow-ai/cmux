// Leo, 2026-10-13: the composer's footer still "tells too much". The bar and scope row show what a
// person acts on and drop what is implied: the model without its vendor (its mark says that), the
// default access mode as its lock alone, no context ring before anything is used, and this Mac's
// name off the computer control. A mode that is not the default still says what it is, the folder
// still reads, and every control keeps its full text in its title and its accessible text.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-footer-essentials.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-footer-essentials: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer footer essentials", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(entry: string, variant: string): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 760, height: 560 } });
    await page.goto(url(entry, variant));
    // Vite can reload the stage once while it optimizes a dependency on the first load.
    const ready = () =>
      page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30_000 });
    await ready().catch(async () => {
      await page.reload();
      await ready();
    });
    return page;
  }

  /** A control's visible text (not its screen-reader-only text), its title and all its text
   * (visible and for assistive tech). */
  const read = (page: Page, selector: string) =>
    page.evaluate((selector) => {
      const element = document.querySelector<HTMLElement>(selector);
      if (!element) return null;
      // innerText counts screen-reader-only text (it is laid out, only clipped): set it aside.
      const quiet = [...element.querySelectorAll<HTMLElement>(".sr-only")];
      for (const span of quiet) span.style.display = "none";
      const visible = element.innerText.replace(/\s+/g, " ").trim();
      for (const span of quiet) span.style.display = "";
      return {
        visible,
        title: element.title || element.closest<HTMLElement>("[title]")?.title || "",
        text: (element.textContent ?? "").replace(/\s+/g, " ").trim(),
      };
    }, selector);

  test("the bar and scope row show the essentials; titles keep the full text", async () => {
    const page = await open("agent-pane.composer", "footer-essentials");
    const model = await read(page, ".acpmux-model .acpmux-picker-button");
    // The title leads with the full name; usage may follow it (" · 0% of context used").
    expect({ visible: model?.visible, title: model?.title.split(" · ")[0] }).toEqual({
      visible: "Opus 5.5",
      title: "Claude Opus 5.5",
    });
    const access = await read(page, ".acpmux-access-trigger");
    expect(access?.visible).toBe("");
    expect(access?.title).toContain("Default");
    expect(access?.text).toContain("Default");
    expect(await page.locator(".acpmux-context").count()).toBe(0);
    // The computer follows the strip's own rule (its name in a wide pane, its icon alone in a narrow
    // one: composer-location-strip.test.ts); the folder keeps its name.
    const folder = await read(page, ".acpmux-location-picker .acpmux-location-label");
    expect(folder?.text).toBe("atlas-web");
    await page.close();
  });

  test("a mode that is not the default keeps its name in the bar", async () => {
    const page = await open("agent-pane.composer", "footer-full-access");
    expect((await read(page, ".acpmux-access-trigger"))?.visible).toBe("Full access");
    await page.close();
  });
});
