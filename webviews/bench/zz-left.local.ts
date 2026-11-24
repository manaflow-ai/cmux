/// <reference types="bun" />
import { webkit } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
const browser = await webkit.launch({ headless: true });
const orig = await Bun.file("/tmp/tsprof/out/assets/transcript-fling.css").text();
for (const w of [280, 330, 420, 900]) {
  const page = await browser.newPage({ viewport: { width: w, height: 700 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(50)`);
  const r = await page.evaluate(async (orig) => {
    for (let i = 0; i < 5; i++) await new Promise(requestAnimationFrame);
    const read = () =>
      [...document.querySelectorAll<HTMLElement>("article.acpmux-row")]
        .slice(0, 3)
        .map((e) => `${getComputedStyle(e).left}|${e.getBoundingClientRect().width.toFixed(1)}`)
        .join(",");
    const now = read();
    const big = [...document.styleSheets].find((s) => s.cssRules.length > 1000)!;
    big.disabled = true;
    const s = new CSSStyleSheet();
    s.replaceSync(orig);
    document.adoptedStyleSheets = [s];
    for (let i = 0; i < 3; i++) await new Promise(requestAnimationFrame);
    return { now, orig: read() };
  }, orig);
  console.log(w, r.now === r.orig ? "SAME" : "DIFF", JSON.stringify(r));
  await page.close();
}
await browser.close();
await served.close();
process.exit(0);
