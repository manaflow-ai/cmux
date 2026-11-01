// Exercise the native palette's bridge entry points in the real chat pane.
// CMUX_BROWSER_TESTS=1 bun test test/session-info-palette.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("session-info-palette.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 4, running: false });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });
  const open = async () => {
    const page = await pane.open({ width: 1400, height: 800 });
    await page.evaluate(() => window.cmuxAcpmuxBridge!.applyHeaderState!({ inspector: true, version: 2 }));
    const toggle = page.locator("button.acpmux-session-info-toggle");
    await toggle.waitFor();
    if ((await toggle.getAttribute("aria-pressed")) === "true") await toggle.click();
    await page.locator("aside.acpmux-session-info").waitFor({ state: "detached" });
    return page;
  };
  const capture = async (page: Page, name: string) => {
    const directory = process.env.SI_PALETTE_CAPTURES;
    if (!directory) return;
    await mkdir(directory, { recursive: true });
    await page.screenshot({ path: `${directory}/${name}.png` });
  };

  test("the event Inspector remains independently reachable", async () => {
    const page = await open();
    try {
      await page.evaluate(() => window.cmuxAcpmuxBridge!.toggleInspector());
      await page.locator("section.acpmux-inspector").waitFor();
      expect(await page.locator("aside.acpmux-session-info").count()).toBe(0);
      await capture(page, "before-event-inspector");
      await page.evaluate(() => window.cmuxAcpmuxBridge!.toggleInspector());
      await page.locator("section.acpmux-inspector").waitFor({ state: "detached" });
    } finally {
      await page.close();
    }
  });

  test("the Session Info bridge toggles the header's panel, including after a header click", async () => {
    const page = await open();
    try {
      const panel = page.locator("aside.acpmux-session-info[data-presence=shown]");
      const toggle = page.locator("button.acpmux-session-info-toggle");
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
      await panel.waitFor({ timeout: 5_000 });
      expect(await toggle.getAttribute("aria-pressed")).toBe("true");
      expect(await page.locator("section.acpmux-inspector").count()).toBe(0);
      await capture(page, "after-session-info");
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
      await page.locator("aside.acpmux-session-info").waitFor({ state: "detached" });
      expect(await toggle.getAttribute("aria-pressed")).toBe("false");
      await toggle.click();
      await panel.waitFor({ timeout: 5_000 });
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
      await page.locator("aside.acpmux-session-info").waitFor({ state: "detached" });
    } finally {
      await page.close();
    }
  });

  test("Session Info uncovers the chat when the event Inspector is in front", async () => {
    const page = await open();
    try {
      await page.evaluate(() => window.cmuxAcpmuxBridge!.toggleInspector(true));
      await page.locator("section.acpmux-inspector").waitFor();
      await page.evaluate(() => window.cmuxAcpmuxBridge!.command!("toggleSessionInfo"));
      await page.locator("aside.acpmux-session-info[data-presence=shown]").waitFor({ timeout: 5_000 });
      await page.locator("section.acpmux-inspector").waitFor({ state: "detached" });
    } finally {
      await page.close();
    }
  });
});
