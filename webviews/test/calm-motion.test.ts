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

  test("a new message uses the subtle entrance and appears instantly under Reduce Motion", async () => {
    const style = `:root{--agent-motion-in:180ms}${desktop}${conversation}`;
    const normal = await page(style, `<div class="acpmux-row__message-presentation">message</div>`, "no-preference");
    const normalMotion = await normal.$eval(".acpmux-row__message-presentation", (row) => ({
      name: getComputedStyle(row).animationName,
      duration: getComputedStyle(row).animationDuration,
    }));
    await normal.close();
    expect(normalMotion).toEqual({ name: "cv-message-enter", duration: "0.18s" });

    const reduced = await page(style, `<div class="acpmux-row__message-presentation">message</div>`, "reduce");
    const reducedMotion = await reduced.$eval(".acpmux-row__message-presentation", (row) => ({
      name: getComputedStyle(row).animationName,
      duration: getComputedStyle(row).animationDuration,
    }));
    await reduced.close();
    expect(reducedMotion.name).toBe("none");
    expect(Number.parseFloat(reducedMotion.duration)).toBeLessThanOrEqual(0.001);
  });

  test("a message text update keeps its entrance animation object and start time", async () => {
    const p = await page(
      `:root{--agent-motion-in:180ms}${desktop}${conversation}`,
      `<div class="acpmux-row__message-presentation" data-message>first token</div>`,
      "no-preference",
    );
    await p.waitForFunction(() => document.querySelector<HTMLElement>("[data-message]")?.getAnimations().length === 1);
    await p.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));
    await p.$eval("[data-message]", (row) => {
      const animation = row.getAnimations()[0];
      if (!animation) throw new Error("message entrance did not start");
      (row as HTMLElement & { __entrance?: { animation: Animation; startTime: number | null } }).__entrance = {
        animation,
        startTime: animation.startTime,
      };
      row.textContent = "first token and another token";
    });
    await p.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));
    const stable = await p.$eval("[data-message]", (row) => {
      const saved = (row as HTMLElement & { __entrance?: { animation: Animation; startTime: number | null } })
        .__entrance;
      const current = row.getAnimations()[0];
      return { sameObject: current === saved?.animation, sameStart: current?.startTime === saved?.startTime };
    });
    await p.close();
    expect(stable).toEqual({ sameObject: true, sameStart: true });
  });

  test("the Jump to Latest pill rises in without growing", async () => {
    const p = await page(conversation, `<button class="acpmux-jump-latest">v</button>`, "no-preference");
    const hidden = await p.$eval(".acpmux-jump-latest", (pill) => getComputedStyle(pill).transform);
    await p.close();
    expect(scaleOf(hidden)).toBe(1);
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
