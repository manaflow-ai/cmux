// The running tray moves on the transcript's motion (Leo 2026-10-27: "plus the bottom running situation
// still not animating correctly"; 2026-10-28: "the background section area ... how it animates
// differently from everything else"). The card settles in on the house settle (#37845: Leo, "they dont
// overshoot but they decelerate at the end"; cubic-bezier(0.16, 1, 0.3, 1) over 180 ms), and its copy
// leaves on the same settle, folding its height away as it fades. A line that
// joins or leaves the open hat moves its height and opacity on the shared fold, a Web Animation
// (SubagentTray.tsx `TrayRow`; Leo, 2026-11-07: "they shouldn't just, like, pop in, burst in"), so
// its stylesheet adds no animation of its own; the gallery's `fade` and `slide` row arms do. This
// loads the real stylesheets in Chromium and reads those keyframes, under Reduce Motion too.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("subagent-tray-line-motion.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("subagent-tray-line-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("tray line motion", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const sheets = [
    ":root{--agent-motion-in:120ms;--agent-motion-out:80ms;--agent-ease-out:cubic-bezier(0, 0, 0.58, 1)}",
    css("ui/popupSurface.css"),
    css("agent-session/acpmux/conversation/conversation.css"),
    css("agent-session/acpmux/subagents/subagents.css"),
    css("gallery/fixtures/trayMotionArms.css"),
  ].join("\n");
  // A line that joined (`data-arrived`) in the hat's row-motion arm (hatParts.experiment.ts).
  const tray = (rows = "height") =>
    `<section class="acpmux-running-tray" data-tray-enter data-row-motion="${rows}">` +
    `<ul class="acpmux-running-tray__list"><li data-arrived><div class="acpmux-running-tray__row">Review the diff</div></li></ul></section>`;
  let browser: Browser | undefined;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function page(body: string, reducedMotion: "reduce" | "no-preference"): Promise<Page> {
    const page = await browser!.newPage();
    await page.emulateMedia({ reducedMotion });
    await page.setContent(`<style>${sheets}</style>${body}`);
    return page;
  }
  const motionOf = (p: Page, selector: string) =>
    p.$eval(selector, (node) => {
      const style = getComputedStyle(node);
      return `${style.animationName} ${style.animationDuration} ${style.animationTimingFunction}`;
    });

  test("the tray card settles in and leaves on the house settle; a joining line has no CSS animation of its own", async () => {
    const p = await page(
      `<div class="acpmux-row acpmux-activity acpmux-row--enter">row</div>${tray()}`,
      "no-preference",
    );
    const row = await motionOf(p, ".acpmux-row--enter");
    const card = await motionOf(p, ".acpmux-running-tray");
    const leave = await p.$eval(".acpmux-running-tray", (node) => {
      node.classList.add("acpmux-running-tray--ghost");
      const style = getComputedStyle(node);
      return `${style.animationName} ${style.animationDuration} ${style.animationTimingFunction}`;
    });
    const line = await motionOf(p, ".acpmux-running-tray__list > li");
    const body = await motionOf(p, ".acpmux-running-tray__row");
    await p.close();
    // A row that arrives in the transcript fades in on the arrival step (--agent-motion-arrive, the
    // quick step: Leo, 2026-11-09: "thinking, tool calls, etc... cannot lag nor can they take long").
    expect(row).toBe("cv-enter-fade 0.08s cubic-bezier(0, 0, 0.58, 1)");
    // The hat's appearance: the settle's duration and curve (--cmux-motion-settle, --cmux-ease-settle).
    expect(card).toBe("acpmux-tray-settle-in 0.18s cubic-bezier(0.16, 1, 0.3, 1)");
    // Its copy leaves on the same settle, folding its height away as it fades (trayMotionModel.ts
    // `playTrayExit`).
    expect(leave).toBe("acpmux-tray-leave 0.18s cubic-bezier(0.16, 1, 0.3, 1)");
    // Its height and opacity move on the shared fold (SubagentTray.tsx `TrayRow`), a Web Animation.
    expect(line.split(" ")[0]).toBe("none");
    expect(body.split(" ")[0]).toBe("none");
  });

  test("the gallery's row arms: fade is the opacity-only arrival; slide rises on the fold's clock", async () => {
    const fade = await page(tray("fade"), "no-preference");
    const faded = await motionOf(fade, ".acpmux-running-tray__list > li");
    await fade.close();
    expect(faded).toBe("cv-enter-fade 0.12s cubic-bezier(0, 0, 0.58, 1)");
    const slide = await page(tray("slide"), "no-preference");
    const rise = await motionOf(slide, ".acpmux-running-tray__row");
    await slide.close();
    expect(rise.split(" ")[0]).toBe("acpmux-hat-row-rise");
  });

  test("under Reduce Motion a tray line has no CSS motion of its own (the tray marks no arrival then)", async () => {
    const p = await page(tray(), "reduce");
    const line = await motionOf(p, ".acpmux-running-tray__list > li");
    await p.close();
    expect(line.split(" ")[0]).toBe("none");
  });
});
