/// <reference types="bun" />
import { chromium } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
await gotoBenchPage(page, served);
await page.waitForFunction(() => "__debug" in window);
await page.evaluate(`window.__debug.seedRows(3000)`);
console.log(
  JSON.stringify(
    await page.evaluate(async () => {
      const sc = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      sc.scrollTop = sc.scrollHeight / 2;
      for (let i = 0; i < 20; i++) await new Promise(requestAnimationFrame);
      const rows = [...sc.querySelectorAll<HTMLElement>("[data-row-id]")];
      const cs = getComputedStyle(rows[0]);
      let vars = 0;
      for (let i = 0; i < cs.length; i++) if (cs[i].startsWith("--")) vars++;
      const rootcs = getComputedStyle(document.documentElement);
      let rv = 0;
      for (let i = 0; i < rootcs.length; i++) if (rootcs[i].startsWith("--")) rv++;
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
        const v = Array.from({ length: 9 }, time).sort((a, b) => a - b);
        return +v[4].toFixed(2);
      };
      const els = rows.reduce((n, r) => n + r.querySelectorAll("*").length + 1, 0);
      const base = med();
      // disable layout: display none parent? measure style only via getComputedStyle on last element
      const kinds: Record<string, number> = {};
      for (const r of rows) {
        const k = r.className.split(" ").slice(0, 3).join(".");
        kinds[k] = (kinds[k] ?? 0) + 1;
      }
      const walk = (list: CSSRuleList, f: (r: CSSStyleRule) => void) => {
        for (const r of [...list]) {
          if (r instanceof CSSStyleRule) f(r);
          if ("cssRules" in r && (r as any).cssRules) walk((r as any).cssRules, f);
        }
      };
      const big = [...document.styleSheets].find((x) => x.cssRules.length > 1000)!;
      let declVars = 0;
      const removed: [CSSStyleRule, string, string][] = [];
      walk(big.cssRules, (r) => {
        if (/^(:root|html)\b/.test(r.selectorText)) return;
        for (const p of [...r.style])
          if (p.startsWith("--")) {
            declVars++;
            removed.push([r, p, r.style.getPropertyValue(p)]);
          }
      });
      for (const [r, p] of removed) r.style.removeProperty(p);
      const noVarDecls = med();
      for (const [r, p, v] of removed) r.style.setProperty(p, v);
      // test: transitions/animations off
      const st = document.createElement("style");
      st.textContent = "*{transition:none!important;animation:none!important}";
      document.head.append(st);
      const noAnim = med();
      st.remove();
      const st2 = document.createElement("style");
      st2.textContent = ".acpmux-row{content-visibility:auto}";
      return {
        declVars,
        noVarDecls,
        noAnim,
        rows: rows.length,
        els,
        base,
        rowVars: vars,
        rootVars: rv,
        sheets: document.styleSheets.length,
        kinds,
      };
    }),
    null,
    1,
  ),
);
await browser.close();
await served.close();
