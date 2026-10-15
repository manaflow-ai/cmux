// The chevron after "Worked for 7m 23s" sits on the text's middle (Leo 2026-10-13): its drawn
// center within half a point of the label's x-height midline, closed and open, as Codex and Claude
// desktop draw a disclosure. Before, it sat on the 20px line's middle, above the lowercase text.
// This draws the real WorkedFor row with the real stylesheets in Chromium and measures both.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("worked-chevron-center.test.tsx", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("worked-chevron-center: skipping (run `bunx playwright install chromium`)");
    describe.skip("worked chevron", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const style = css("pages/shared/desktop.css") + css("agent-session/acpmux/conversation/conversation.css");
  const { WorkedFor } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  let browser: Browser | undefined;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const expanded of [false, true])
    test(`the ${expanded ? "open" : "closed"} chevron centers on the label's x-height`, async () => {
      const row = { id: "worked-1", version: 1, at: 0, kind: "worked", status: "completed", durationMs: 443_000 };
      const markup = renderToStaticMarkup(createElement(WorkedFor, { row: row as never, expanded, onToggle() {} }));
      const page = await browser!.newPage();
      await page.setContent(`<style>${style}</style><div style="width:480px">${markup}</div>`);
      const { midline, center } = await page.evaluate(() => {
        const label = document.querySelector<HTMLElement>(".cv-worked__label")!;
        // The baseline: the bottom of an empty inline-block, which sits on it.
        const probe = document.createElement("span");
        probe.style.cssText = "display:inline-block;width:0;height:0";
        label.append(probe);
        const baseline = probe.getBoundingClientRect().bottom;
        const font = getComputedStyle(label);
        const context = document.createElement("canvas").getContext("2d")!;
        context.font = `${font.fontStyle} ${font.fontWeight} ${font.fontSize} ${font.fontFamily}`;
        const xHeight = context.measureText("x").actualBoundingBoxAscent;
        const chevron = document.querySelector(".cv-worked__chevron path")!.getBoundingClientRect();
        return { midline: baseline - xHeight / 2, center: chevron.top + chevron.height / 2 };
      });
      await page.close();
      expect(Math.abs(center - midline)).toBeLessThanOrEqual(0.5);
    });
});
