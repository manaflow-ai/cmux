import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame } from "./test/support/galleryFrame";

const webviews = path.resolve(".");
const { createServer } = await import("vite");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
  root: webviews,
  server: { port: 0, strictPort: false },
});
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
  const s = getComputedStyle(el);
  return {
    focusVisible: el.matches(":focus-visible"),
    outlineStyle: s.outlineStyle, outlineWidth: s.outlineWidth, outlineColor: s.outlineColor, outlineOffset: s.outlineOffset,
    ringWidthVar: s.getPropertyValue("--cmux-focus-ring-width"),
    ringColorVar: s.getPropertyValue("--cmux-focus-ring-color"),
    bg: s.backgroundColor,
    hasDesktopCss: [...document.styleSheets].some((sheet) => {
      try { return [...sheet.cssRules].some((r) => r.cssText.includes("--cmux-focus-ring-width")); } catch { return false; }
    }),
  };
}), null, 1));
await browser.close();
await vite.close();
process.exit(0);
