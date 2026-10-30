// POLISH audit, batch 4 (cx-2grmt): "No bouncy or weird transforms", and Reduce Motion keeps
// fades (plans/cmux-next/motion.md rule 7). A live transcript row appeared in one frame under
// Reduce Motion, and the settings Reset button, the settings notes and badges, and the transcript's
// Jump to Latest pill grew from 0.8 / 0.92. This loads the real stylesheets in Chromium and reads
// what they do.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("calm-motion.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("calm-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("calm motion", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const conversation = css("agent-session/acpmux/conversation/conversation.css");
  const settings = css("pages/settings/layout.css");
  // The pages' shared stylesheet: its Reduce Motion rule cuts every other animation to 0.01ms.
  const desktop = css("pages/shared/desktop.css");
  let browser: Browser | undefined;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function page(style: string, body: string, reducedMotion: "reduce" | "no-preference"): Promise<Page> {
    const page = await browser!.newPage();
    await page.emulateMedia({ reducedMotion });
    await page.setContent(`<style>${style}</style>${body}`);
    return page;
  }

  /** The scale `transform` draws (1 when it only moves or is `none`). */
  const scaleOf = (transform: string) => {
    const matrix = /^matrix\(([^,]+),\s*([^,]+)/.exec(transform);
    return matrix ? Math.hypot(Number(matrix[1]), Number(matrix[2])) : 1;
  };

  test("under Reduce Motion a live transcript row, new text and a highlighted code card still fade in", async () => {
    const p = await page(
      `:root{--agent-motion-in:120ms}${desktop}${conversation}`,
      `<div class="cv-enter">reply</div><div class="acpmux-row--enter">tool</div><span class="cv-fresh">new text</span>` +
        `<div class="cv-code-handoff is-fading"><div class="cv-code-handoff__real">code</div></div>`,
      "reduce",
    );
    const fades = await p.$$eval(".cv-enter, .acpmux-row--enter, .cv-fresh, .cv-code-handoff__real", (rows) =>
      rows.map((row) => `${getComputedStyle(row).animationName} ${getComputedStyle(row).animationDuration}`),
    );
    await p.close();
    expect(fades).toEqual(["cv-enter-fade 0.12s", "cv-enter-fade 0.12s", "cv-enter-fade 0.12s", "cv-enter-fade 0.12s"]);
  });

  // It fades in place: its 6px rise read as the button jumping the moment the reader scrolled up
  // (Leo 2026-10-28), so hidden and shown it sits on the same pixels.
  test("the Jump to Latest pill fades in place, without growing or rising", async () => {
    const p = await page(
      conversation,
      `<button class="acpmux-jump-latest">v</button><button class="acpmux-jump-latest" data-shown>v</button>`,
      "no-preference",
    );
    const [hidden, shown] = await p.$$eval(".acpmux-jump-latest", (pills) =>
      pills.map((pill) => getComputedStyle(pill).transform),
    );
    await p.close();
    expect(scaleOf(hidden!)).toBe(1);
    expect(hidden).toBe(shown);
  });

  test("the settings Reset button, notes and badges fade in without growing", async () => {
    const p = await page(
      settings,
      `<span class="reset-slot"><button class="reset-button">r</button></span>`,
      "no-preference",
    );
    const hidden = await p.$eval(".reset-button", (button) => getComputedStyle(button).transform);
    const pop = await p.evaluate(() => {
      for (const sheet of document.styleSheets)
        for (const rule of sheet.cssRules)
          if (rule instanceof CSSKeyframesRule && rule.name === "settings-pop")
            return rule.findRule("from")?.style.transform ?? "";
      return "missing";
    });
    await p.close();
    expect(scaleOf(hidden)).toBe(1);
    expect(pop).toBe("");
  });
});
