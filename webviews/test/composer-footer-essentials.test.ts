// Leo, 2026-10-13: the composer's footer still "tells too much". The bar and scope row show what a
// person acts on and drop what is implied: the model without its vendor (its mark says that), the
// default access mode as its lock alone, no context reading before anything is used, and this Mac's
// name off the computer control. A mode that is not the default still says what it is, the folder
// still reads, and every control keeps its full text in its title and its accessible text.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer", "agent-pane.composer-context"], { browser });
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

  test("the bar shows the essentials; titles keep the full text", async () => {
    const page = await open("agent-pane.composer", "footer-essentials");
    const model = await read(page, ".acpmux-model .acpmux-picker-button");
    // The title leads with the full name; the context use may follow it.
    expect(model?.visible).toBe("Opus 5.5");
    expect(model?.title).toStartWith("Claude Opus 5.5");
    const access = await read(page, ".acpmux-access-trigger");
    // The mode's symbol and its name, Claude Code's own ("Manual" for its default mode,
    // harnessModes.ts); the full text stays in the title and the accessible text.
    expect(access?.title).toContain("Manual");
    expect(access?.text).toContain("Manual");
    // No usage before anything is used: Claude Code's split keeps the ring's place in the quiet
    // row from the first frame (hq#1957, the composer holds still), but it draws only its track,
    // never a share.
    const rings = await page.$$eval(".acpmux-context-ring", (buttons) =>
      buttons.map((button) => button.querySelectorAll("svg circle").length),
    );
    expect(rings.length).toBeGreaterThan(0);
    for (const marks of rings) expect(marks).toBe(1);
    await page.close();
  });

  // When this Mac's name gives way to its icon is the strip's call (composer-location-strip.test.ts).
  test("a new chat's location row names the folder without this Mac's path", async () => {
    const page = await open("agent-pane.composer", "footer-essentials-new-chat");
    const folder = await read(page, ".acpmux-location-picker .acpmux-location-label");
    // A folder's name may be cut in the middle (head and tail spans), so read it without the seam.
    expect(folder?.visible?.replace(/\s+/g, "")).toBe("atlas-web");
    await page.close();
  });

  test("a chat on another machine keeps that machine's name", async () => {
    const page = await open("agent-pane.composer-context", "ssh-chat");
    const labels = await page.$$eval(".acpmux-location-label", (spans) =>
      spans.map((span) => (span as HTMLElement).innerText.trim()),
    );
    expect(labels.some((label) => label.length > 0 && label !== "This Mac" && !label.includes("/"))).toBe(true);
    await page.close();
  });
});
