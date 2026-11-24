/// <reference types="bun" />
import { webkit } from "./browsers";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
import { installPaintedFrames } from "../test/support/paintedFrames";
const ROWS = Number(process.argv[2] ?? 3000);
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await webkit.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
await installPaintedFrames(page);
await gotoBenchPage(page, served);
await page.waitForFunction(() => "__debug" in window);
await page.evaluate(`window.__debug.seedRows(${ROWS})`);
await page.locator(".acpmux-scroll").hover();
const fling = async (on: boolean) => {
  await page.evaluate((on) => (window as any).__minimap(on), on);
  for (let i = 0; i < 10; i++) await page.evaluate(() => new Promise(requestAnimationFrame));
  return page.evaluate(async () => {
    const d = (window as any).__debug;
    const s = d.debug ?? d;
    const sc = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    sc.scrollTop = sc.scrollHeight;
    for (let i = 0; i < 20; i++) await new Promise(requestAnimationFrame);
    const f = await d.startFling(3, { wait: true, nominal_ms: 1000 / 120 });
    const p = d.perfStats();
    return `interval=${f.p50_ms}/${f.p95_ms} react=${p.react.p50_ms}/${p.react.p95_ms} layout=${p.layout.p50_ms}/${p.layout.p95_ms} blank=${p.blank_frames}`;
  });
};
await fling(true);
for (let r = 0; r < 3; r++) for (const on of [true, false]) console.log(`minimap=${on}`, await fling(on));
await browser.close();
process.exit(0);
