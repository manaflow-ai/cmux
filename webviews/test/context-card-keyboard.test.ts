// cmux-web-test-timeout: 300
// The context ring's card renders in a portal at the end of the page, so before, Tab from the ring
// went to the next control in the row and closed the card: Compact now and Details › could not be
// reached from the keyboard (the review of #23785). Now Tab from the ring moves into the card,
// Tab between its actions stays in it, Tab past the last goes on to what follows the ring, and
// Shift+Tab from the first goes back to the ring. Escape in the card returns focus to the ring.
//
// Real Chromium and WebKit (the app's engine) with real key presses, on the gallery's rich Claude
// card. CI fails the file when it cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/context-card-keyboard.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("context-card-keyboard.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`context-card-keyboard: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("context card keyboard", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const ENTRY = "agent-pane.context-ring";
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 520, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    await warmGalleryFrame(vite, ENTRY, {
      browser: browsers.get("chromium") ?? browsers.get("webkit"),
      params: { variant: "usage-30" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** The rich card's ring at rest (no hover play, which would open the card under the pointer). */
  const open = async (browser: Browser): Promise<Page> => {
    const page = await browser.newPage({ viewport: { width: 520, height: 400 } });
    for (;;) {
      await page.goto(stageURL("rich-at-rest"));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.mouse.move(1, 1);
    return page;
  };
  /** What has focus: the card's action by class, the ring, or the control's name. */
  const focused = (page: Page) =>
    page.evaluate(() => {
      const active = document.activeElement as HTMLElement | null;
      if (!active || active === document.body) return "body";
      if (active.closest(".acpmux-context-card")) return active.className;
      if (active.classList.contains("acpmux-context-ring")) return "ring";
      return active.textContent?.trim() ?? active.tagName;
    });
  const cardShown = (page: Page) => page.evaluate(() => document.querySelector(".acpmux-context-card") !== null);

  for (const [name] of engines)
    test(`${name}: Tab reaches the card's actions and moves on past the ring`, async () => {
      const page = await open(browsers.get(name)!);
      // A key press first, so the focus that follows is keyboard focus, as Tab gives.
      await page.keyboard.press("Shift");
      await page.locator("button.acpmux-context-ring").focus();
      await page.waitForFunction(() => document.querySelector(".acpmux-context-card .acpmux-context-card-compact"));
      expect(await focused(page)).toBe("ring");

      await page.keyboard.press("Tab");
      expect(await focused(page)).toBe("acpmux-context-card-compact");
      await page.keyboard.press("Tab");
      expect(await focused(page)).toBe("acpmux-context-card-details");
      expect(await cardShown(page), "the card stays while focus is in it").toBe(true);

      await page.keyboard.press("Shift+Tab");
      expect(await focused(page)).toBe("acpmux-context-card-compact");
      await page.keyboard.press("Shift+Tab");
      expect(await focused(page)).toBe("ring");

      await page.keyboard.press("Tab");
      await page.keyboard.press("Tab");
      // Past the card's last action: the gallery's next control after the ring.
      await page.keyboard.press("Tab");
      expect(await focused(page)).toBe("Open by automation");
      await page.waitForFunction(() => document.querySelector(".acpmux-context-card") === null);
      await page.close();
    });

  for (const [name] of engines)
    test(`${name}: Escape in the card closes it onto the ring`, async () => {
      const page = await open(browsers.get(name)!);
      await page.keyboard.press("Shift");
      await page.locator("button.acpmux-context-ring").focus();
      await page.waitForFunction(() => document.querySelector(".acpmux-context-card .acpmux-context-card-details"));
      await page.keyboard.press("Tab");
      await page.keyboard.press("Tab");
      expect(await focused(page)).toBe("acpmux-context-card-details");
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => document.querySelector(".acpmux-context-card") === null);
      expect(await focused(page)).toBe("ring");
      await page.close();
    });
});
