// l10n-allow-file: sample transcript and screenshot labels, not shipped UI.
// Leo: "when I said move the scrollbar to the right, I do mean to the right". The
// Session Info may move the text column, but never the native scrollbar's own box.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-scrollbar-edge.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] });
    pane = await papercutPane(() => browser, { turns: 40, running: false });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });
  const settled = (page: Page) =>
    page.evaluate(async () => {
      await Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined)));
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
    });
  for (const width of [560, 900, 1200, 1600]) {
    for (const tools of [true, false]) {
      test(`${width}px, header quick tools ${tools}: scrollbar stays at pane edge`, async () => {
        const page = await pane.open({ width, height: 700 });
        try {
          await page.evaluate(async (tools) => {
            const url = "/header/quickActions.ts";
            const actions = await import(/* @vite-ignore */ url);
            actions.configureQuickActions(tools ? undefined : { quickActions: [] });
            window.cmuxAcpmuxBridge?.applyHeaderState?.({ inspector: true, version: 2 });
          }, tools);
          const toggle = page.locator("button.acpmux-session-info-toggle");
          const panel = page.locator("aside.acpmux-session-info");
          await toggle.waitFor();
          if ((await panel.count()) === 0) await toggle.click();
          await page.locator('.acpmux-session-info[data-presence="shown"]').waitFor();
          await settled(page);
          const geometry = await page.evaluate(() => {
            const rect = (selector: string) => document.querySelector(selector)!.getBoundingClientRect();
            const pane = rect(".acpmux-main");
            const scroll = rect(".acpmux-scroll");
            const row = rect(".acpmux-row");
            const composer = rect(".acpmux-composer");
            const scrollNode = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const thumb = getComputedStyle(scrollNode, "::-webkit-scrollbar-thumb");
            return {
              rightInset: pane.right - scroll.right,
              columnOffset: Math.abs((row.left + row.right - composer.left - composer.right) / 2),
              overflow: scrollNode.scrollHeight - scrollNode.clientHeight,
              scrollbarWidth: parseFloat(getComputedStyle(scrollNode, "::-webkit-scrollbar").width),
              thumbInk: thumb.backgroundColor,
            };
          });
          const capture = process.env.NX_SCROLLBAR_MEDIA_DIR;
          if (capture && width === 1200 && tools) {
            await mkdir(capture, { recursive: true });
            await page.screenshot({ path: `${capture}/scrollbar-open.png` });
          }
          console.log(`SCROLLBAR_EDGE ${JSON.stringify({ width, tools, ...geometry })}`);
          expect(geometry.overflow).toBeGreaterThan(0);
          expect(geometry.scrollbarWidth).toBeGreaterThan(0);
          expect(geometry.thumbInk).not.toBe("rgba(0, 0, 0, 0)");
          expect(Math.abs(geometry.rightInset)).toBeLessThanOrEqual(1);
          expect(geometry.columnOffset).toBeLessThanOrEqual(1);
          // Find is sticky chrome inside the scroller.
          await page.evaluate(() => window.cmuxAcpmuxActions?.["chat.find"]({ text: "Answer" }));
          await page.locator(".acpmux-find .find-pill__field").waitFor();
          await settled(page);
          const findOffset = await page.evaluate(() => {
            const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const find = document.querySelector(".acpmux-find__bar")!;
            const inset = parseFloat(getComputedStyle(find).right);
            const contentRight = scroll.getBoundingClientRect().left + scroll.clientLeft + scroll.clientWidth;
            return Math.abs(contentRight - find.getBoundingClientRect().right - inset);
          });
          console.log(`SCROLLBAR_FIND ${JSON.stringify({ width, tools, findOffset })}`);
          expect(findOffset).toBeLessThanOrEqual(1);
          await page.keyboard.press("Escape");
          await page.locator(".acpmux-find").waitFor({ state: "detached" });
          // The toggle remains a real hit target with the panel open at the pane's edge.
          await toggle.click();
          await panel.waitFor({ state: "detached" });
          await settled(page);
          expect(
            await page.locator(".acpmux-scroll").evaluate((node) => {
              const pane = node.closest(".acpmux-main")!.getBoundingClientRect();
              return Math.abs(pane.right - node.getBoundingClientRect().right);
            }),
          ).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      });
    }
  }
});
