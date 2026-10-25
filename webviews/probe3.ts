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
await page.keyboard.press("Escape");
await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
await page.mouse.move(1, 1);
const BUTTON = ".acpmux-composer-foot .acpmux-model .acpmux-picker-button";
await page.keyboard.press("Shift");
await page.locator(BUTTON).first().focus();
await page.waitForTimeout(400);
console.log(JSON.stringify(await page.locator(BUTTON).first().evaluate((el) => {
  const sel = ':focus-visible:not(:where(input:not([type="button"], [type="submit"], [type="reset"], [type="checkbox"], [type="radio"], [type="range"], [type="color"], [type="file"], [type="image"]), textarea, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="searchbox"], .acpmux-row)):not([data-focus-ring="none"], [data-focus-ring="row"], [data-focus-ring="rows"], [role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"], [role="option"], [role="menu"], .ui-popup)';
  let sharedMatches: unknown;
  try { sharedMatches = el.matches(sel); } catch (e) { sharedMatches = String(e); }
  // count how many author rules mention outline anywhere, to see if the walk saw desktop.css at all
  let outlineRules = 0, sheets = 0, blocked = 0;
  for (const sheet of [...document.styleSheets]) {
    sheets++;
    let rules: CSSRule[] = [];
    try { rules = [...sheet.cssRules]; } catch { blocked++; continue; }
    const walk = (list: CSSRule[]) => { for (const r of list) {
      const a = r as CSSStyleRule & { cssRules?: CSSRuleList };
      if (a.cssRules) walk([...a.cssRules]);
      else if (a.style && /outline/.test(a.style.cssText ?? "")) outlineRules++;
    } };
    walk(rules);
  }
  return { sharedMatches, outlineRules, sheets, blocked, tag: el.tagName, role: el.getAttribute("role"), attrs: [...el.attributes].map((a) => a.name) };
}), null, 1));
await browser.close(); await vite.close(); process.exit(0);
