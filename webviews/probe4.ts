import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame } from "./test/support/galleryFrame";
const webviews = path.resolve(".");
const { createServer } = await import("vite");
const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), root: webviews, server: { port: 0 } });
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const url = `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", { variant: "quiet-chips", frame: "component", width: 760 })}`;
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 760, height: 600 } });
await page.goto(url);
await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 120_000 });
await page.evaluate(() => document.fonts.ready);
const out = await page.evaluate(() => {
  const found: string[] = [];
  for (const sheet of [...document.styleSheets]) {
    let rules: CSSRule[] = [];
    try { rules = [...sheet.cssRules]; } catch { continue; }
    const walk = (list: CSSRule[], ctx: string) => { for (const r of list) {
      const a = r as CSSStyleRule & { cssRules?: CSSRuleList; conditionText?: string };
      if (a.cssRules) walk([...a.cssRules], ctx + "@" + (a.conditionText ?? "?") + " ");
      else if (a.style && /outline-style\s*:\s*solid/.test(a.style.cssText ?? "") && /focus-visible/.test(a.selectorText ?? ""))
        found.push(ctx + (a.selectorText ?? "").slice(0, 120) + " || " + a.style.cssText.slice(0, 200));
    } };
    walk(rules, "");
  }
  return found;
});
console.log(JSON.stringify(out, null, 1));
await browser.close(); await vite.close(); process.exit(0);
