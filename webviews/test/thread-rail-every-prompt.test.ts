// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts, not shipped UI.
// The windowed rail counts prompts discovered by the index and materializes one through the
// existing history/anchor path when its unloaded tick is clicked (Real Chromium).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("thread-rail-every-prompt.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("thread-rail-every-prompt: skipping (run `bunx playwright install chromium`)");
    describe.skip("rail every prompt", () => test("chromium", () => {}));
    return;
  }

  const TURNS = 100;
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser!, { turns: TURNS, running: false, page: 40 });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  test("counts indexed prompts and loads an unloaded tick through history", async () => {
    const page = await pane!.open({ width: 1200, height: 800 });
    const first = page.locator(".acpmux-minimap__tick").first();
    await first.waitFor({ state: "visible", timeout: 20_000 });
    expect(await first.locator("xpath=ancestor::li[1]").getAttribute("aria-setsize")).toBe(String(TURNS));
    expect(pane!.methods.filter((method) => method === "_acpmux/events").length).toBeGreaterThan(0);

    await first.click();
    await page.waitForFunction(() => !!document.querySelector('.acpmux-row[data-row-id="user-1"]'), undefined, {
      timeout: 20_000,
    });
    expect(await page.locator('.acpmux-row[data-row-id="user-1"]').count()).toBe(1);
    expect(pane!.methods).toContain("_acpmux/events");
    await page.close();
  });
});
