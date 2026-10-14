// The New Tab style switch is a row of dots (Leo 2026-10-14: "what happened to the dots at the
// bottom, why's there text"). One small round dot per style, the current one in the accent and the
// rest dim; no radio circles and no names at rest; each dot's hit target is larger than the dot; and
// the row keeps one size and place whichever style is current.
//
// Before: #20336 drew the five names as a row of text. The pane does not load ui.css, so the
// radios' .ui-sr-only never applied and each drew a native circle beside its name.
//
// This renders the switch's markup with the pane's real New Tab stylesheet in Chromium and reads
// what it draws.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { chromium, type Browser } from "playwright";
import { StyleSwitch } from "../src/agent-session/acpmux/newtab/StyleSwitch";
import { PAGE_STYLES, type PageStyle } from "../src/agent-session/acpmux/newtab/templates";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-style-dots.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-style-dots: skipping (run `bunx playwright install chromium`)");
    describe.skip("style dots", () => test("chromium", () => {}));
    return;
  }
  const screen = readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/newtab/screen.css"), "utf8");
  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  /// What the switch draws with `current` picked: its row's box, each option's hit box and dot, and
  /// whatever of it is visible besides the dots.
  async function drawn(current: PageStyle) {
    const page = await browser!.newPage({ viewport: { width: 900, height: 400 } });
    const markup = renderToStaticMarkup(createElement(StyleSwitch, { current, onPick() {}, onCancel() {} }));
    await page.setContent(
      `<style>:root{--agent-text:#202020;--agent-accent:#0a84ff;--acpmux-composer-dim:#808080}${screen}` +
        `body{margin:0}.page{position:relative;height:300px}</style><div class="page">${markup}</div>`,
    );
    const result = await page.evaluate(() => {
      const box = (node: Element) => {
        const rect = node.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      };
      const row = document.querySelector("fieldset")!;
      const options = [...document.querySelectorAll<HTMLInputElement>("input[type=radio]")].map((input) => {
        const option = input.closest("label")!;
        const dot = getComputedStyle(option, "::after");
        return {
          hit: box(input),
          dot: { width: dot.width, height: dot.height, radius: dot.borderRadius },
          radioShows: getComputedStyle(input).opacity !== "0" && box(input).width > 0,
        };
      });
      // Text a person can see at rest: any text node whose element is visible.
      const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
      const text: string[] = [];
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const element = node.parentElement!;
        const style = getComputedStyle(element);
        if (node.textContent!.trim() && style.opacity !== "0" && style.visibility !== "hidden")
          text.push(node.textContent!.trim());
      }
      return { row: box(row), options, text };
    });
    await page.close();
    return result;
  }

  test("five round dots, no radio circles and no names at rest, each a target larger than its dot", async () => {
    const { options, text } = await drawn("threads");
    expect(options.length).toBe(PAGE_STYLES.length);
    expect(text).toEqual([]);
    for (const option of options) {
      expect(option.radioShows).toBe(false);
      expect(option.dot.width).toBe(option.dot.height);
      expect(Number.parseFloat(option.dot.width)).toBeGreaterThanOrEqual(5);
      expect(Number.parseFloat(option.dot.width)).toBeLessThanOrEqual(8);
      expect(option.dot.radius).toBe("50%");
      expect(option.hit.width).toBeGreaterThanOrEqual(20);
      expect(option.hit.height).toBeGreaterThanOrEqual(20);
    }
  });

  test("the row keeps one size and place whichever style is current", async () => {
    const rows = await Promise.all(PAGE_STYLES.map(async (style) => (await drawn(style)).row));
    for (const row of rows) expect(row).toEqual(rows[0]!);
  });
});
