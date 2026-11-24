/// <reference types="bun" />
import { webkit } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await webkit.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(3000)`);
  const out = await page.evaluate(async () => {
    const sc = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    sc.scrollTop = sc.scrollHeight / 2;
    for (let i = 0; i < 20; i++) await new Promise(requestAnimationFrame);
    const els = [...sc.querySelectorAll<HTMLElement>("[data-row-id]")].flatMap((r) => [
      r,
      ...r.querySelectorAll<HTMLElement>("*"),
    ]);
    const hits: Record<string, number> = {};
    const per = new Map<Element, number>();
    const walk = (rules: CSSRuleList, ctx: string) => {
      for (const r of rules) {
        if (r instanceof CSSStyleRule) {
          const names = [...Array(r.style.length).keys()].map((i) => r.style[i]).filter((n) => n.startsWith("--"));
          if (names.length && !/^(:root|html)/.test(r.selectorText)) {
            let n = 0;
            for (const e of els) {
              try {
                if (e.matches(r.selectorText)) {
                  n++;
                  per.set(e, (per.get(e) ?? 0) + 1);
                }
              } catch {
                break;
              }
            }
            if (n) hits[`${n} [${names.length}] ${ctx}${r.selectorText.slice(0, 120)}`] = n;
          }
        }
        if ((r as any).cssRules && !(r instanceof CSSStyleRule))
          walk((r as any).cssRules, (r as any).conditionText ? `@${(r as any).conditionText.slice(0, 30)} ` : ctx);
        else if ((r as any).cssRules?.length) walk((r as any).cssRules, ctx);
      }
    };
    for (const s of document.styleSheets) walk(s.cssRules, "");
    const tags = new Map<string, number>();
    for (const [e] of per) {
      const k = e.tagName.toLowerCase() + "." + [...e.classList].slice(0, 2).join(".");
      tags.set(k, (tags.get(k) ?? 0) + 1);
    }
    return {
      els: els.length,
      elsWithVarDecl: per.size,
      top: Object.entries(hits)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 40)
        .map((x) => x[0]),
      tags: [...tags].sort((a, b) => b[1] - a[1]).slice(0, 20),
    };
  });
  console.log(JSON.stringify(out, null, 1));
} finally {
  await browser.close();
  await served.close();
}
process.exit(0);
