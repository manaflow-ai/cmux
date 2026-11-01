// The running tray moves on the transcript's motion (Leo 2026-10-27: "plus the bottom running situation
// still not animating correctly"; 2026-10-28: "the background section area ... how it animates
// differently from everything else"). The card already entered on a live row's cv-enter (#25719); a
// line joining its open list could move the visible transcript as the dock changed height. This
// loads the real stylesheets in Chromium and reads that activity rows, the tray card and a tray
// line arriving all use an opacity-only keyframe on one duration and one curve, in every gallery
// arm the card and its lines stay in step, and Reduce Motion keeps the same fade.
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
  const tray = (arm?: string) =>
    `<section class="acpmux-running-tray" data-tray-enter${arm ? ` data-motion="${arm}"` : ""}>` +
    `<ul class="acpmux-running-tray__list"><li data-enter="bottom">Review the diff</li></ul></section>`;
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

  test("a tray line arriving, the tray card and a live activity row fade without moving the transcript", async () => {
    const p = await page(
      `<div class="acpmux-row acpmux-activity acpmux-row--enter">row</div>${tray()}`,
      "no-preference",
    );
    const row = await motionOf(p, ".acpmux-row--enter");
    const card = await motionOf(p, ".acpmux-running-tray");
    const line = await motionOf(p, ".acpmux-running-tray__list > li");
    await p.close();
    expect(row).toBe("cv-enter-fade 0.12s cubic-bezier(0, 0, 0.58, 1)");
    expect(card).toBe(row);
    expect(line).toBe(row);
  });

  test("in every gallery arm a line joining the list moves as the card does", async () => {
    for (const arm of ["tight", "spring"]) {
      const p = await page(tray(arm), "no-preference");
      const card = await motionOf(p, ".acpmux-running-tray");
      const line = await motionOf(p, ".acpmux-running-tray__list > li");
      await p.close();
      expect(line).not.toContain("ui-enter");
      expect(line.split(" ")[0]).toBe(card.split(" ")[0]);
    }
  });

  test("under Reduce Motion a tray line keeps a transcript row's fade without the rise", async () => {
    const p = await page(`<div class="acpmux-row--enter">row</div>${tray()}`, "reduce");
    const row = await motionOf(p, ".acpmux-row--enter");
    const line = await motionOf(p, ".acpmux-running-tray__list > li");
    await p.close();
    expect(row.split(" ")[0]).toBe("cv-enter-fade");
    expect(line).toBe(row);
  });
});
