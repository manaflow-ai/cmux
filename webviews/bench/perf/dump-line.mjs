// Bench helper: prints the visible file headers and the first visible diff lines at two moments,
// so two pages' first viewports can be compared.
import { chromium } from "playwright";
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
await page.goto(process.argv[2]);
const grab = () =>
  page.evaluate(() => {
    const lines = [];
    const headers = [];
    const visible = (el) => {
      const r = el.getBoundingClientRect();
      return r.height > 0 && r.bottom > 0 && r.top < innerHeight;
    };
    const walk = (root) => {
      for (const el of root.querySelectorAll("*")) {
        if (el.hasAttribute("data-diffs-header") && visible(el))
          headers.push((el.textContent || "").trim().slice(0, 80));
        if (
          el.hasAttribute("data-line") &&
          el.hasAttribute("data-line-type") &&
          visible(el) &&
          (el.textContent || "").trim()
        )
          lines.push([
            el.getAttribute("data-line-type"),
            !!el.querySelector("span[style]"),
            (el.textContent || "").slice(0, 50),
          ]);
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(document);
    return {
      headers: headers.slice(0, 8),
      lineCount: lines.length,
      highlighted: lines.filter((l) => l[1]).length,
      first: lines.slice(0, 2),
    };
  });
await page.waitForTimeout(1500);
console.log("AT1.5s", JSON.stringify(await grab()));
await page.waitForTimeout(5000);
console.log("AT6.5s", JSON.stringify(await grab()));
await browser.close();
