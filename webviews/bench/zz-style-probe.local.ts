/// <reference types="bun" />
import { chromium } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(3000)`);
  const out = await page.evaluate(async () => {
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
    const med = (f: () => number) => { const v = Array.from({ length: 7 }, f).sort((a, b) => a - b); return +v[3].toFixed(2); };
    const sheets = [...document.styleSheets];
    // drop the duplicate copy of the big sheet
    const bigs = sheets.filter((s) => s.cssRules.length > 1000);
    bigs[1].disabled = true;
    const big = bigs[0];
    const base = med(time);
    const texts = [...big.cssRules].map((r) => r.cssText);
    const res: any = { base, rules: texts.length };
    const N = 48;
    const size = Math.ceil(texts.length / N);
    const per: any[] = [];
    const without = (lo: number, hi: number) => {
      for (let i = hi - 1; i >= lo; i--) big.deleteRule(i);
      const t = med(time);
      for (let i = lo; i < hi; i++) big.insertRule(texts[i], i);
      return t;
    };
    for (let c = 0; c < N; c++) {
      const lo = c * size, hi = Math.min(texts.length, lo + size);
      if (lo >= hi) break;
      const t = without(lo, hi);
      per.push([+(base - t).toFixed(2), lo, hi, texts[lo].slice(0, 80)]);
    }
    per.sort((a, b) => b[0] - a[0]);
    res.per = per.slice(0, 12);
    // drill down top chunk to single rules in groups of 8
    const [, lo0, hi0] = per[0];
    const fine: any[] = [];
    for (let i = lo0; i < hi0; i += 8) { const t = without(i, Math.min(hi0, i + 8)); fine.push([+(base - t).toFixed(2), i, texts.slice(i, Math.min(hi0, i + 8)).map((x) => x.slice(0, 160))]); }
    fine.sort((a, b) => b[0] - a[0]);
    res.fine = fine.slice(0, 5);
    return res;
  });
  console.log(JSON.stringify(out, null, 1));
} finally { await browser.close(); await served.close(); }
