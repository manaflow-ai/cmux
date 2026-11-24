/// <reference types="bun" />
import { chromium, webkit } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await (process.env.WK ? webkit : chromium).launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(3000)`);
  await page.evaluate("window.__QUICK = 1");
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
    const med = (f: () => number) => {
      const v = Array.from({ length: 7 }, f).sort((a, b) => a - b);
      return +v[3].toFixed(2);
    };
    const sheets = [...document.styleSheets];
    // drop the duplicate copy of the big sheet
    const bigs = sheets.filter((s) => s.cssRules.length > 1000);
    if (bigs[1]) bigs[1].disabled = true;
    const big = bigs[0];
    const base = med(time);
    const texts = [...big.cssRules].map((r) => r.cssText);
    const res: any = {
      base,
      rules: texts.length,
      nodes: rows.reduce((a, r) => a + 1 + r.querySelectorAll("*").length, 0),
      rows: rows.length,
    };
    res.noBig = (() => {
      big.disabled = true;
      const t = med(time);
      big.disabled = false;
      return t;
    })();
    res.noSheets = (() => {
      for (const s of sheets) s.disabled = true;
      const t = med(time);
      for (const s of sheets) s.disabled = false;
      if (bigs[1]) bigs[1].disabled = true;
      return t;
    })();
    const walk = (rules: CSSRuleList, f: (r: CSSStyleRule) => void) => {
      for (const r of rules) {
        if (r instanceof CSSStyleRule) f(r);
        if ((r as any).cssRules) walk((r as any).cssRules, f);
      }
    };
    let decl = 0,
      varUses = 0,
      rootDecl = 0;
    for (const sh of sheets)
      if (!sh.disabled)
        walk(sh.cssRules, (r) => {
          for (let i = 0; i < r.style.length; i++) {
            const n = r.style[i];
            if (n.startsWith("--")) {
              decl++;
              if (/:root|^html/.test(r.selectorText)) rootDecl++;
            }
            if (r.style.getPropertyValue(n).includes("var(")) varUses++;
          }
        });
    Object.assign(res, { decl, rootDecl, varUses });
    // strip non-root custom property declarations
    const saved: [CSSStyleRule, string][] = [];
    for (const sh of sheets)
      if (!sh.disabled)
        walk(sh.cssRules, (r) => {
          if (/:root|^html/.test(r.selectorText)) return;
          const names = [...Array(r.style.length).keys()].map((i) => r.style[i]).filter((n) => n.startsWith("--"));
          if (names.length) {
            saved.push([r, r.style.cssText]);
            for (const n of names) r.style.removeProperty(n);
          }
        });
    res.noNonRootVars = med(time);
    res.strippedRules = saved.length;
    for (const [r, t] of saved) r.style.cssText = t;
    // replace var() uses on non-custom properties with 'initial'-ish: remove them
    const saved2: [CSSStyleRule, string][] = [];
    for (const sh of sheets)
      if (!sh.disabled)
        walk(sh.cssRules, (r) => {
          const names = [...Array(r.style.length).keys()]
            .map((i) => r.style[i])
            .filter((n) => !n.startsWith("--") && r.style.getPropertyValue(n).includes("var("));
          if (names.length) {
            saved2.push([r, r.style.cssText]);
            for (const n of names) r.style.removeProperty(n);
          }
        });
    res.noVarUses = med(time);
    for (const [r, t] of saved2) r.style.cssText = t;
    res.base2 = med(time);
    const drop = (re: RegExp) => {
      const gone: [CSSStyleSheet | CSSGroupingRule, number, string][] = [];
      const rec = (owner: any) => {
        for (let i = owner.cssRules.length - 1; i >= 0; i--) {
          const r = owner.cssRules[i];
          if (r instanceof CSSStyleRule && re.test(r.selectorText)) {
            gone.push([owner, i, r.cssText]);
            owner.deleteRule(i);
          } else if (r.cssRules) rec(r);
        }
      };
      for (const sh of sheets) if (!sh.disabled) rec(sh);
      const t = med(time);
      for (const [o, i, txt] of gone.reverse()) o.insertRule(txt, i);
      return [t, gone.length];
    };
    res.base3 = med(time);
    res.noHighlightSel = drop(/::(highlight|selection)/);
    res.noHas = drop(/:has\(/);
    res.noIsWhereNot = drop(/:(is|where|not)\(/);
    res.noRootPrefix = drop(/^:root|^html/);
    res.noHover = drop(/:hover|:focus/);
    res.base4 = med(time);
    if ((window as any).__QUICK) return res;
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
      const lo = c * size,
        hi = Math.min(texts.length, lo + size);
      if (lo >= hi) break;
      const t = without(lo, hi);
      per.push([+(base - t).toFixed(2), lo, hi, texts[lo].slice(0, 80)]);
    }
    per.sort((a, b) => b[0] - a[0]);
    res.per = per.slice(0, 12);
    // drill down top chunk to single rules in groups of 8
    const [, lo0, hi0] = per[0];
    const fine: any[] = [];
    for (let i = lo0; i < hi0; i += 8) {
      const t = without(i, Math.min(hi0, i + 8));
      fine.push([+(base - t).toFixed(2), i, texts.slice(i, Math.min(hi0, i + 8)).map((x) => x.slice(0, 160))]);
    }
    fine.sort((a, b) => b[0] - a[0]);
    res.fine = fine.slice(0, 5);
    return res;
  });
  console.log(JSON.stringify(out, null, 1));
} finally {
  await browser.close();
  await served.close();
}
