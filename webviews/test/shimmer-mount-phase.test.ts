// The shimmer of a running row or Thinking line takes the shared clock's phase (ui/spinnerClock.ts
// `setLoopPhase`) without asking an element for its animations in React's commit: `getAnimations`
// flushes style, and doing it in every running row's mount was about 8% of a streaming chat's main
// thread on Leo's Mac (2026-11-11, "not sure what's up with 100% cpu still :("). The exact start comes
// in the next animation frame, once for all of that frame's rows. Loads the real stylesheets, the
// page's clock and the real components in Chromium.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("shimmer-mount-phase.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("shimmer-mount-phase: skipping (run `bunx playwright install chromium`)");
    describe.skip("shimmer mount phase", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const style = css("pages/shared/desktop.css") + css("agent-session/acpmux/conversation/conversation.css");
  const bundle = await Bun.build({
    entrypoints: [path.join(import.meta.dir, "support/shimmerMount.entry.tsx")],
    target: "browser",
    define: { "process.env.NODE_ENV": '"production"' },
  });
  if (!bundle.success) throw new Error(bundle.logs.join("\n"));
  const script = await bundle.outputs[0].text();

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const frames = (p: Page) =>
    p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));

  async function open(): Promise<Page> {
    const p = await browser!.newPage();
    await p.emulateMedia({ reducedMotion: "no-preference" });
    await p.setContent(`<style>${style}</style>`);
    await p.addScriptTag({ content: script });
    // Counts every ask for an element's or the page's animations from here on.
    await p.evaluate(() => {
      const scope = window as unknown as { asks: number };
      scope.asks = 0;
      const element = Element.prototype.getAnimations;
      Element.prototype.getAnimations = function (this: Element, options?: GetAnimationsOptions) {
        scope.asks += 1;
        return element.call(this, options);
      };
    });
    return p;
  }

  /** Each shimmer loop's phase (ms into its period, its delay counted) and the clock's, at one moment. */
  function phases(p: Page) {
    return p.evaluate(() => {
      const loops: { name: string; host: string; phase: number }[] = [];
      let period = 0;
      for (const animation of document.getAnimations()) {
        const name = (animation as CSSAnimation).animationName;
        if (name !== "cmux-shimmer-band" && name !== "cmux-shimmer-lit") continue;
        const timing = animation.effect!.getComputedTiming();
        period = Number(timing.duration);
        const target = (animation.effect as KeyframeEffect).target as Element;
        loops.push({ name, host: target.closest("div[id]")?.id ?? "?", phase: Number(timing.progress) * period });
      }
      const clock = (performance.timeOrigin + Number(document.timeline.currentTime)) % period;
      return { loops, clock, period };
    });
  }

  /// The loops take their start exactly (Animation.startTime), as the spinners do (spinner-phase.test.ts).
  const TOLERANCE_MS = 4;
  const apart = (a: number, b: number, period: number) => {
    const d = Math.abs(a - b) % period;
    return Math.min(d, period - d);
  };

  for (const row of [true, false]) {
    const what = row ? "running rows" : "Thinking lines";
    test(`${what} mount on the clock's phase without asking for animations`, async () => {
      const p = await open();
      try {
        expect(await p.evaluate((isRow) => (window as any).mountShimmers(20, isRow, "first"), row)).toBe(0);
        await frames(p);
        // fixed-wait: real time must pass between the two mounts; that gap is what the test is about.
        await p.waitForTimeout(337);
        expect(await p.evaluate((isRow) => (window as any).mountShimmers(20, isRow, "second"), row)).toBe(0);
        await frames(p);
        const { loops, clock, period } = await phases(p);
        expect(loops.filter((loop) => loop.host === "second").length).toBe(40);
        for (const loop of loops)
          expect(apart(loop.phase, clock, period), `${loop.host} ${loop.name}`).toBeLessThan(TOLERANCE_MS);
      } finally {
        await p.close();
      }
    });
  }

  for (const restart of ["an ancestor shown again", "the static status look turned off"] as const)
    test(`shimmers mounted apart restart on the clock's phase: ${restart}`, async () => {
      const p = await open();
      try {
        await p.evaluate(() => (window as any).mountShimmers(3, false, "first"));
        await frames(p);
        // fixed-wait: real time must pass between the mounts and while the loops are off; that gap is the test.
        await p.waitForTimeout(337);
        await p.evaluate(() => (window as any).mountShimmers(3, false, "second"));
        await frames(p);
        const off = (on: boolean) =>
          p.evaluate(
            ([value, how]) => {
              if (how === "an ancestor shown again")
                for (const host of document.querySelectorAll<HTMLElement>("body > div"))
                  host.style.display = value ? "none" : "";
              else if (value) document.documentElement.setAttribute("data-status-indicators", "static");
              else document.documentElement.removeAttribute("data-status-indicators");
            },
            [on, restart] as const,
          );
        await off(true);
        await frames(p);
        // fixed-wait: the loops must stay off for real time, so a restart at its mount-time delay would show.
        await p.waitForTimeout(523);
        await off(false);
        await frames(p);
        await frames(p);
        const { loops, clock, period } = await phases(p);
        expect(loops.length).toBe(12);
        for (const loop of loops)
          expect(apart(loop.phase, clock, period), `${loop.host} ${loop.name}`).toBeLessThan(TOLERANCE_MS);
      } finally {
        await p.close();
      }
    });

  test("a hidden page's paused shimmer comes back on the clock's phase", async () => {
    const p = await open();
    try {
      await p.evaluate(() => (window as any).mountShimmers(3, true, "before"));
      await frames(p);
      await p.evaluate(() => document.documentElement.setAttribute("data-cmux-page-hidden", ""));
      await frames(p);
      // fixed-wait: the page must stay hidden for real time, so its paused loops fall behind the clock.
      await p.waitForTimeout(411);
      await p.evaluate(() => document.documentElement.removeAttribute("data-cmux-page-hidden"));
      await frames(p);
      const { loops, clock, period } = await phases(p);
      expect(loops.length).toBe(6);
      for (const loop of loops)
        expect(apart(loop.phase, clock, period), `${loop.host} ${loop.name}`).toBeLessThan(TOLERANCE_MS);
    } finally {
      await p.close();
    }
  });
});
