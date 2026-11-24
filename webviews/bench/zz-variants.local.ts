/// <reference types="bun" />
import { chromium, webkit } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await (process.env.WK ? webkit : chromium).launch({ headless: true });
const variants: Record<string, string> = JSON.parse(await Bun.file(process.argv[2]).text());
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(3000)`);
  const out = await page.evaluate(async (variants) => {
    const sc = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    sc.scrollTop = sc.scrollHeight / 2;
    for (let i = 0; i < 20; i++) await new Promise(requestAnimationFrame);
    const rows = [...sc.querySelectorAll<HTMLElement>("[data-row-id]")];
    const parent = rows[0].parentElement!;
    const time = () => {
      const clones = rows.map((r) => r.cloneNode(true) as HTMLElement);
      const t0 = performance.now();
      for (const c of clones) parent.appendChild(c);
      clones[0].getBoundingClientRect();
      const t1 = performance.now();
      for (const c of clones) c.remove();
      parent.getBoundingClientRect();
      return t1 - t0;
    };
    const med = () => {
      const v = Array.from({ length: 15 }, time).sort((a, b) => a - b);
      return +v[7].toFixed(2);
    };
    const big = [...document.styleSheets].find((s) => s.cssRules.length > 1000)!;
    big.disabled = true;
    const sheets: Record<string, CSSStyleSheet> = {};
    for (const [k, t] of Object.entries(variants)) {
      const s = new CSSStyleSheet();
      s.replaceSync(t);
      sheets[k] = s;
    }
    const res: Record<string, number[]> = {};
    for (let round = 0; round < 3; round++)
      for (const k of Object.keys(sheets)) {
        document.adoptedStyleSheets = [sheets[k]];
        await new Promise(requestAnimationFrame);
        (res[k] ??= []).push(med());
      }
    return res;
  }, variants);
  for (const [k, v] of Object.entries(out)) console.log(k.padEnd(20), v.join(" "));
} finally {
  await browser.close();
  await served.close();
}
process.exit(0);
