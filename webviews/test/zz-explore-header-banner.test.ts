import { afterAll, beforeAll, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { papercutPane } from "./support/papercutChat";
setDefaultTimeout(300_000);
let browser: Browser;
let pane: Awaited<ReturnType<typeof papercutPane>>;
let pane2: Awaited<ReturnType<typeof papercutPane>>;
beforeAll(async () => {
  browser = await chromium.launch({ headless: true });
  pane = await papercutPane(() => browser, { turns: 2, running: false });
  pane2 = await papercutPane(() => browser, { turns: 2, running: false, session: { watching: "claude" } });
});
afterAll(async () => { await pane?.close(); await pane2?.close(); await browser?.close(); });
const offer = (page: Page, row: unknown) =>
  page.evaluate(async (value) => {
    const m = (await import(/* @vite-ignore */ "/header/tabRow.ts")) as { setTabRow(v: unknown): void };
    m.setTabRow(value);
  }, row);
const tools = (page: Page) => page.evaluate(() => [...document.querySelectorAll<HTMLElement>(".acpmux-handoff-header-tools button")].map((b) => { const r = b.getBoundingClientRect(); return `${b.getAttribute("aria-label")}@${Math.round(r.x)},${Math.round(r.y)}`; }).join(" | "));
for (const width of [280, 480, 900]) for (const tab of [0, 1, 2]) {
  test(`w${width} tab${tab}`, async () => {
    for (const [name, p] of [["plain", pane], ["watch", pane2]] as const) {
      const page = await p.open({ width, height: 500 });
      if (tab) { await offer(page, { height: 40, trailingInset: 12, soloTab: tab === 1 }); await page.waitForTimeout(500); }
      await page.waitForTimeout(800);
      console.log(width, tab, name, await tools(page));
      await page.screenshot({ path: `/tmp/hb/w${width}-t${tab}-${name}.png` });
      await page.close();
    }
  });
}
