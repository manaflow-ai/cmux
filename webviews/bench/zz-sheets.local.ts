/// <reference types="bun" />
import { webkit, chromium } from "playwright";
import { gotoBenchPage, serveBenchPage } from "./support/benchPage";
const served = await serveBenchPage("/test/browser/transcript-fling.html");
for (const bt of [chromium, webkit]) {
  const browser = await bt.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__debug" in window);
  await page.evaluate(`window.__debug.seedRows(3000)`);
  console.log(
    bt.name(),
    served.url,
    await page.evaluate(() => [...document.styleSheets].map((s) => s.href + ":" + s.cssRules.length)),
  );
  await browser.close();
}
await served.close();
