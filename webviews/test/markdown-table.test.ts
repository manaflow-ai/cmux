// l10n-allow-file: markdown table regression fixtures.
import { expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, webkit } from "playwright";
import { Markdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { configureLabs } from "../src/agent-session/acpmux/labs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("markdown-table.test.ts", async () => {
  const table =
    "| Strategy | Trigger | Delay | Response |\n| --- | --- | --- | --- |\n| Retry | " +
    "Long description ".repeat(10) +
    " | 0.5s | Complete response |";
  const css = await Bun.file("src/agent-session/acpmux/conversation/conversation.css").text();
  for (const engine of [webkit, chromium])
    test(`${engine.name()} keeps the last column reachable by keyboard and horizontal scrolling`, async () => {
      configureLabs({ labs: { tableScroll: true } });
      const html = renderToStaticMarkup(createElement(Markdown, null, table));
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage({ viewport: { width: 390, height: 600 } });
        await page.setContent(
          `<html data-lab-table-scroll="on"><head><style>${css}</style></head><body style="margin:0"><div style="display:flex;width:390px">${html}</div></body></html>`,
        );
        const wrap = page.locator(".cv-table-wrap");
        expect(await wrap.getAttribute("tabindex")).toBe("0");
        expect(await wrap.getAttribute("aria-label")).toBeTruthy();
        const metrics = await wrap.evaluate((el) => {
          el.scrollLeft = el.scrollWidth;
          const last = el.querySelector("th:last-child")!.getBoundingClientRect();
          const rect = el.getBoundingClientRect();
          return {
            width: el.clientWidth,
            scroll: el.scrollWidth,
            lastRight: last.right,
            right: rect.right,
            scrollLeft: el.scrollLeft,
          };
        });
        expect(metrics.width).toBeLessThanOrEqual(390);
        expect(metrics.scroll).toBeGreaterThan(metrics.width);
        expect(metrics.scrollLeft).toBeGreaterThan(0);
        expect(metrics.lastRight).toBeLessThanOrEqual(metrics.right + 1);
        await wrap.focus();
        expect(await wrap.evaluate((el) => el === document.activeElement)).toBe(true);
      } finally {
        await browser.close();
        configureLabs(undefined);
      }
    }, 20000);
});
