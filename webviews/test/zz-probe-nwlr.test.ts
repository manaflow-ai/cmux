import { test } from "bun:test";
import path from "node:path";
import { chromium } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
test("probe", async () => {
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  const vite = await createServer({ configFile: path.join(webviews, "vite.config.gallery-dev.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
  await vite.listen();
  const browser = await chromium.launch({ headless: true });
  await warmGalleryFrame(vite, "agent-pane.chat-width", { browser });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(`http://127.0.0.1:${(vite.httpServer!.address() as any).port}${galleryFrame("agent-pane.chat-width", { variant: "standard", width: 1440 })}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 90000 });
  await page.locator(".cv-codeblock").first().waitFor();
  const out = await page.evaluate(() => {
    const row = document.querySelector<HTMLElement>(".acpmux-row")!;
    const cs = getComputedStyle(row);
    const chain: any[] = [];
    for (let e: HTMLElement | null = row; e && chain.length < 8; e = e.parentElement) {
      const c = getComputedStyle(e); const r = e.getBoundingClientRect();
      chain.push({ cls: e.className, left: r.left, width: r.width, pl: c.paddingLeft, pr: c.paddingRight, ml: c.marginLeft, cssLeft: c.left, cssRight: c.right, inset: c.getPropertyValue("--cv-inset"), insetEnd: c.getPropertyValue("--cv-inset-end"), column: c.getPropertyValue("--cv-column") });
    }
    const rules: string[] = [];
    for (const sheet of [...document.styleSheets]) { try { for (const r of [...(sheet.cssRules as any)]) { const t = (r as CSSStyleRule).selectorText; if (t && row.matches(t) && /left|inset|margin|padding|width/.test((r as CSSStyleRule).style.cssText)) rules.push(t + " {" + (r as CSSStyleRule).style.cssText.slice(0, 300) + "}"); } } catch {} }
    return { chain, rules };
  });
  console.log(JSON.stringify(out, null, 1));
  await browser.close(); await vite.close();
}, 240000);
