// l10n-allow-file: browser fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { chromium, webkit } from "playwright";
import { JSDOM } from "jsdom";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { renderFrameCSS } from "../src/agent-session/acpmux/conversation/renderBase";
import { RENDER_KIT_CSS } from "../src/agent-session/acpmux/conversation/renderKit";
import { renderChartSource } from "../src/agent-session/acpmux/conversation/renderChart";

await requireBrowserLane("render-kit-css.test.ts", async () => {
  const dom = new JSDOM(
    '<body style="--agent-page-bg:rgba(23, 41, 59, 0.0);--agent-accent-text:rgb(23, 41, 59);--agent-text:rgb(220, 221, 222)"></body>',
  );
  const saved = { document: globalThis.document, getComputedStyle: globalThis.getComputedStyle };
  let css: string;
  try {
    Object.assign(globalThis, {
      document: dom.window.document,
      getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    });
    css = renderFrameCSS();
  } finally {
    Object.assign(globalThis, saved);
    dom.window.close();
  }
  for (const engine of [chromium, webkit]) {
    test(`${engine.name()} keeps opaque canvas colors in a transparent native theme`, async () => {
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage();
        await page.setContent(
          `<style>${css}${RENDER_KIT_CSS}</style><div id="chart"></div><fieldset class="segmented"><label><input type="radio" checked>Selected</label></fieldset>`,
        );
        await page.evaluate(
          `(() => { ${renderChartSource()}; window.cmux = { onTheme() {} }; installCharts(); cmux.chart('#chart', {type:'donut',labels:['A','B'],series:[{values:[2,3]}]}); })()`,
        );
        const colors = await page.evaluate(() => ({
          hole: getComputedStyle(document.querySelector("#chart circle")!).fill,
          selected: getComputedStyle(document.querySelector("label")!).backgroundColor,
          slice: getComputedStyle(document.querySelector("#chart path")!).fill,
          token: getComputedStyle(document.documentElement).getPropertyValue("--cmux-text").trim(),
        }));
        expect(colors).toEqual({
          hole: "rgb(23, 41, 59)",
          selected: "rgb(23, 41, 59)",
          slice: "rgb(0, 122, 255)",
          token: "rgb(220, 221, 222)",
        });
        await page.evaluate("cmux.chart('#chart', {labels:['A'],series:[{values:[2]}]})");
        expect(await page.locator("#chart g rect").evaluate((el) => getComputedStyle(el).fill)).toBe("rgb(23, 41, 59)");
      } finally {
        await browser.close();
      }
    }, 15_000);
    test(`${engine.name()} lets agent layers override base, kit, and root tokens`, async () => {
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage();
        for (const kit of ["", RENDER_KIT_CSS]) {
          await page.setContent(
            `<style>${css}${kit}</style><style>@layer theme, utilities;@layer theme{:root{--cmux-text:rgb(12, 34, 56)}}@layer utilities{p{margin:0;color:var(--cmux-text)}body{margin:0}}</style><p>Agent styles</p>`,
          );
          expect(
            await page.locator("p").evaluate((el) => ({
              margin: getComputedStyle(el).margin,
              color: getComputedStyle(el).color,
              bodyMargin: getComputedStyle(document.body).margin,
            })),
          ).toEqual({ margin: "0px", color: "rgb(12, 34, 56)", bodyMargin: "0px" });
        }
      } finally {
        await browser.close();
      }
    }, 15_000);
    test(`${engine.name()} scales inherited line height with large agent text`, async () => {
      const browser = await engine.launch(
        engine === chromium && process.env.CI !== "true" ? { channel: "chrome" } : {},
      );
      try {
        const page = await browser.newPage();
        await page.setContent(`<style>${css}${RENDER_KIT_CSS}</style><div style="font-size:40px">Large<br>text</div>`);
        expect(await page.locator("div").evaluate((el) => getComputedStyle(el).lineHeight)).toBe("65px");
      } finally {
        await browser.close();
      }
    }, 15_000);
  }
});
