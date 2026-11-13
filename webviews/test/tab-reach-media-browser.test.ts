// The transcript's Tab guard (ui/tabReach.ts keepTabOnScreen) counts every control the browser
// tabs to, native players included: a reply's audio or video player in view (ReplyMedia.tsx) is
// where Tab or Shift-Tab goes, never skipped for the composer because the guard did not know it was
// a stop and saw only the control past it, out of view (#38230 review F1).
//
// Real Chromium from Playwright on the tab-reach harness; CI fails the file when it cannot launch.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("tab-reach-media-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  let vite: ViteDevServer;
  let browser: Browser;
  let page: Page;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/tab-reach.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 700, height: 700 } });
    page.setDefaultTimeout(5_000);
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(): Promise<void> {
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/tab-reach.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "1");
  }
  const active = () => page.evaluate(() => document.activeElement?.id ?? "none");
  const scrollTop = () => page.evaluate(() => document.getElementById("region")!.scrollTop);
  const prevented = () => page.evaluate(() => (window as unknown as { lastTabPrevented?: boolean }).lastTabPrevented);

  test("the harness puts the players in view and the outer controls out of it", async () => {
    await open();
    const seen = await page.evaluate(() => {
      const view = document.getElementById("region")!.getBoundingClientRect();
      const inside = (id: string) => {
        const box = document.getElementById(id)!.getBoundingClientRect();
        return box.top >= view.top && box.bottom <= view.bottom;
      };
      return Object.fromEntries(["above", "back", "mid", "audio", "below"].map((id) => [id, inside(id)]));
    });
    expect(seen).toEqual({ above: false, back: true, mid: true, audio: true, below: false });
  });

  test("Tab from a control in view goes to the audio player after it", async () => {
    await open();
    await page.focus("#mid");
    const top = await scrollTop();
    await page.keyboard.press("Tab");
    expect(await active()).toBe("audio");
    expect(await scrollTop()).toBe(top);
  });

  test("Shift-Tab from a control in view goes to the audio player before it", async () => {
    await open();
    await page.focus("#mid");
    const top = await scrollTop();
    await page.keyboard.press("Shift+Tab");
    expect(await active()).toBe("back");
    expect(await scrollTop()).toBe(top);
  });

  // Inside a player, Tab moves through its own controls (play, timeline, volume, ...), and the
  // document's focus stays on the player the whole time. The guard sees only the player, listed once,
  // with the control scrolled out of view after it: it must leave those presses to the browser, not
  // send focus to the composer and skip the player's other controls (#38230 review F1, second round).
  test("Tab inside an audio player moves through its own controls, not to the composer", async () => {
    await open();
    await page.focus("#mid");
    const top = await scrollTop();
    await page.keyboard.press("Tab");
    expect(await active()).toBe("audio");
    await page.keyboard.press("Tab");
    expect(await prevented()).toBe(false);
    expect(await active()).toBe("audio");
    expect(await scrollTop()).toBe(top);
  });

  // Shift-Tab enters a player at its last control, and Chromium keeps some presses inside the player
  // without a keydown reaching the page, so press until focus leaves it: none taken by the guard.
  test("Shift-Tab inside an audio player moves through its own controls, not to the header", async () => {
    await open();
    await page.focus("#mid");
    const top = await scrollTop();
    await page.keyboard.press("Shift+Tab");
    expect(await active()).toBe("back");
    const taken: boolean[] = [];
    for (let press = 0; press < 4 && (await active()) === "back"; press++) {
      await page.evaluate(() => delete (window as unknown as { lastTabPrevented?: boolean }).lastTabPrevented);
      expect(await scrollTop()).toBe(top);
      await page.keyboard.press("Shift+Tab");
      taken.push((await prevented()) === true);
    }
    expect(taken).not.toContain(true);
    expect(await active()).not.toBe("header");
  });
});
