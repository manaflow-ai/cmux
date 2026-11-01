// SYNCED-SPINNERS (Leo 2026-11-01, on two working spinners side by side, each turning out of phase
// with the other: "why did you desync these"). Every spinner on a page sits at the shared clock's
// angle (ui/spinnerClock.ts): one mounted later joins in step, and the ones a hidden page paused
// come back in step when it shows, instead of resuming where they stopped while a spinner mounted
// after them starts on the clock. This loads the real stylesheets and the page's clock in Chromium.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("spinner-phase.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("spinner-phase: skipping (run `bunx playwright install chromium`)");
    describe.skip("spinner phase", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const style =
    css("pages/shared/desktop.css") +
    css("agent-session/acpmux/conversation/spinner.css") +
    css("agent-session/acpmux/conversation/conversation.css");
  const bundle = await Bun.build({
    entrypoints: [path.join(import.meta.dir, "support/installSpinnerClock.entry.ts")],
    target: "browser",
  });
  if (!bundle.success) throw new Error(bundle.logs.join("\n"));
  const clockScript = await bundle.outputs[0].text();

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const frames = (p: Page) =>
    p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));

  /** Mounts one more working spinner (`Spinner`'s markup) and lets its animation start. */
  async function mount(p: Page, id: string): Promise<void> {
    await p.evaluate((name) => {
      const holder = document.createElement("span");
      holder.innerHTML = `<svg class="cv-spinner" id="${name}" data-working viewBox="0 0 16 16"><g class="cv-spinner__spokes"></g></svg>`;
      document.body.append(holder);
    }, id);
    await frames(p);
  }

  /** Each spinner's phase (ms into its turn) and the clock's, read at one moment. */
  function phases(p: Page): Promise<{ spinners: Record<string, number>; clock: number; period: number }> {
    return p.evaluate(() => {
      const spinners: Record<string, number> = {};
      let period = 0;
      for (const animation of document.getAnimations()) {
        if ((animation as CSSAnimation).animationName !== "cmux-spin") continue;
        const target = (animation.effect as KeyframeEffect | null)?.target as Element | null;
        period = Number(animation.effect?.getTiming().duration);
        spinners[target?.id ?? "?"] = Number(animation.currentTime) % period;
      }
      const clock = (performance.timeOrigin + Number(document.timeline.currentTime)) % period;
      return { spinners, clock, period };
    });
  }

  /** How far apart two phases are around the turn, in ms. */
  const apart = (a: number, b: number, period: number) => {
    const d = Math.abs(a - b) % period;
    return Math.min(d, period - d);
  };

  test("two spinners mounted at different times share a phase", async () => {
    const p = await browser!.newPage();
    try {
      await p.emulateMedia({ reducedMotion: "no-preference" });
      await p.setContent(`<style>${style}</style>`);
      await p.addScriptTag({ content: clockScript });
      await mount(p, "first");
      // fixed-wait: real time must pass between the two mounts; that gap is what the test is about.
      await p.waitForTimeout(337);
      await mount(p, "second");
      const { spinners, clock, period } = await phases(p);
      expect(Object.keys(spinners).sort()).toEqual(["first", "second"]);
      expect(apart(spinners.first, spinners.second, period)).toBeLessThan(2);
      expect(apart(spinners.first, clock, period)).toBeLessThan(2);
    } finally {
      await p.close();
    }
  });

  test("spinners a hidden page paused come back in step with one mounted after it shows", async () => {
    const p = await browser!.newPage();
    try {
      await p.emulateMedia({ reducedMotion: "no-preference" });
      await p.setContent(`<style>${style}</style>`);
      await p.addScriptTag({ content: clockScript });
      await mount(p, "before");
      // Hidden (ui/wave.ts marks `<html>` from visibilityState): every loop pauses (desktop.css).
      await p.evaluate(() => document.documentElement.setAttribute("data-cmux-page-hidden", ""));
      await frames(p);
      // fixed-wait: the page must stay hidden for real time, so its paused loops fall behind the clock.
      await p.waitForTimeout(411);
      await p.evaluate(() => document.documentElement.removeAttribute("data-cmux-page-hidden"));
      await frames(p);
      await mount(p, "after");
      const { spinners, clock, period } = await phases(p);
      expect(Object.keys(spinners).sort()).toEqual(["after", "before"]);
      expect(apart(spinners.before, spinners.after, period)).toBeLessThan(2);
      expect(apart(spinners.before, clock, period)).toBeLessThan(2);
    } finally {
      await p.close();
    }
  });
});
