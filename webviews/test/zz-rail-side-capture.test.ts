// Throwaway capture harness (not committed): real before/after images of the prompt rail moving to
// the right edge through its own right-click menu, for PR #24131's body. Emits each PNG as base64
// between markers so the dispatching lane can rebuild the files from the job log.
import { test, setDefaultTimeout } from "bun:test";
import { webkit, chromium, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("zz-rail-side-capture.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser | undefined;
  let engineName = "";
  for (const [name, engine] of [
    ["webkit", webkit],
    ["chromium", chromium],
  ] as [string, BrowserType][]) {
    try {
      browser = await engine.launch({ headless: true });
      engineName = name;
      break;
    } catch {
      console.warn(`zz-rail-side-capture: cannot launch ${name}`);
    }
  }
  if (!browser) return;

  const settle = (page: Page) =>
    page.evaluate(() =>
      Promise.all(document.getAnimations().map((a) => a.finished.catch(() => undefined))),
    );
  const emit = async (page: Page, label: string) => {
    await settle(page);
    const shot = await page.locator(".acpmux-shell").screenshot({ type: "png" });
    const b64 = Buffer.from(shot).toString("base64");
    console.log(`@@CAPTURE_BEGIN ${label} ${engineName} ${shot.length}`);
    for (let i = 0; i < b64.length; i += 200) console.log(`@@B64 ${b64.slice(i, i + 200)}`);
    console.log(`@@CAPTURE_END ${label}`);
  };
  const railBox = (page: Page) =>
    page.evaluate(() => {
      const nav = document.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
      const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
      if (!nav) return null;
      const box = nav.getBoundingClientRect();
      return { left: Math.round(box.left - shell.left), right: Math.round(shell.right - box.right) };
    });

  const pane = await papercutPane(() => browser!, { turns: 8, running: false });
  try {
    await (await pane.open()).close();
    const page = await pane.open({ width: 1240, height: 700 });
    try {
      console.log(`@@RAIL before ${JSON.stringify(await railBox(page))}`);
      await emit(page, "before-rail-left");

      // The feature itself: right-click the rail, then pick its one menu item.
      await page.locator(".acpmux-minimap__rail:not(.acpmux-scrollmap)").click({ button: "right" });
      const menu = page.locator('.ui-context-menu[role="menu"]');
      await menu.waitFor({ timeout: 10_000 });
      await emit(page, "menu-open-on-the-rail");
      const label = await menu.locator(".ui-menu-item").first().innerText();
      console.log(`@@MENU_ITEM ${label.replace(/\s+/g, " ").trim()}`);
      await menu.locator(".ui-menu-item").first().click();
      await menu.waitFor({ state: "detached", timeout: 10_000 });
      await page.waitForTimeout(400);
      await settle(page);

      console.log(`@@RAIL after ${JSON.stringify(await railBox(page))}`);
      await emit(page, "after-rail-right");
    } finally {
      await page.close();
    }
  } finally {
    await browser.close();
    await pane.close();
  }

  test("captured", () => {});
});
