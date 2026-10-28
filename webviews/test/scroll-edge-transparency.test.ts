// The shared sticky scroll edge has a solid, unblurred fallback for both the system preference and
// the host's data-reduce-transparency attribute (WebKit uses the latter).
import { readFileSync } from "node:fs";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("scroll-edge-transparency.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("scroll-edge-transparency: skipping (run `bunx playwright install chromium`)");
    describe.skip("scroll edge transparency", () => test("chromium", () => {}));
    return;
  }
  const css = readFileSync(path.resolve(import.meta.dir, "../src/ui/scrollEdge.css"), "utf8");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(): Promise<Page> {
    const page = await browser!.newPage();
    await page.setContent(
      `<style>:root{--agent-page-bg:rgb(30, 30, 30);--glass-surface:rgba(30,30,30,.7)}${css}</style>` +
        `<div class="ui-scroll-edge-fade" id="edge"><span>Outputs</span></div>`,
    );
    return page;
  }

  test("the edge blurs by default", async () => {
    const page = await open();
    expect(await page.locator("#edge").evaluate((edge) => getComputedStyle(edge, "::after").backdropFilter)).toContain(
      "blur",
    );
    await page.close();
  });

  test("the host Reduce Transparency attribute removes the edge blur", async () => {
    const page = await open();
    await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
    expect(await page.locator("#edge").evaluate((edge) => getComputedStyle(edge, "::after").backdropFilter)).toBe(
      "none",
    );
    await page.close();
  });
});
