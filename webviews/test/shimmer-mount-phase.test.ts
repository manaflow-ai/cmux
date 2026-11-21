// Loads real CSS and components to verify the visible sweep separately from its idle cadence.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("shimmer-mount-phase.test.ts", async () => {
  setDefaultTimeout(60_000);
  const src = path.resolve(import.meta.dir, "../src");
  const css = (file: string) => readFileSync(path.join(src, file), "utf8");
  const style = css("pages/shared/desktop.css") + css("agent-session/acpmux/conversation/conversation.css");
  const bundle = await Bun.build({
    entrypoints: ["shimmer-cadence-fixture"],
    target: "browser",
    define: { "process.env.NODE_ENV": '"production"' },
    plugins: [
      {
        name: "shimmer-fixture",
        setup(build) {
          build.onResolve({ filter: /^shimmer-cadence-fixture$/ }, () => ({ path: "fixture", namespace: "shimmer" }));
          build.onLoad({ filter: /.*/, namespace: "shimmer" }, () => ({
            loader: "tsx",
            resolveDir: path.resolve(import.meta.dir, ".."),
            contents: `
            import { flushSync } from "react-dom";
            import { createRoot } from "react-dom/client";
            import { RowShimmer, ShimmerText, ShimmerEnabledContext } from "./src/agent-session/acpmux/conversation/ShimmerText";
            window.mountShimmers = (count, row, id, enabled = true) => {
              const host = document.createElement("div"); host.id = id; document.body.append(host);
              flushSync(() => createRoot(host).render(<ShimmerEnabledContext value={enabled}>
                {Array.from({length: count}, (_, at) => row ?
                  <div key={at} className="cv-tool is-live"><span className="cv-tool__text">Read file {at}<RowShimmer>Read file {at}</RowShimmer></span></div> :
                  <output key={at} className="cv-thinking is-shimmer"><ShimmerText text="Thinking" /></output>)}
              </ShimmerEnabledContext>));
            };
          `,
          }));
        },
      },
    ],
  });
  if (!bundle.success) throw new Error(bundle.logs.join("\n"));
  const script = await bundle.outputs[0].text();
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  async function open(): Promise<Page> {
    const page = await browser.newPage();
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.setContent(`<style>${style}</style>`);
    await page.addScriptTag({ content: script });
    return page;
  }

  async function mount(page: Page, row: boolean, enabled = true) {
    await page.evaluate(
      ([isRow, isEnabled]) => {
        const scope = window as unknown as {
          mountShimmers: (count: number, row: boolean, id: string, enabled: boolean) => void;
        };
        scope.mountShimmers(1, isRow, "fixture", isEnabled);
      },
      [row, enabled],
    );
  }

  const active = (page: Page) => page.locator("#fixture .is-shimmer-active");
  async function expectIdle(page: Page) {
    expect(await active(page).count()).toBe(0);
    expect(
      await page.evaluate(
        () =>
          document
            .getAnimations()
            .filter((animation) => (animation as CSSAnimation).animationName.startsWith("cmux-cadenced-shimmer-"))
            .length,
      ),
    ).toBe(0);
  }

  for (const row of [true, false]) {
    test(`${row ? "tool rows" : "Thinking labels"} use one stepped one-second sweep and no idle animation`, async () => {
      const page = await open();
      try {
        await mount(page, row);
        await expectIdle(page);
        await active(page).waitFor();
        const sweep = await page.evaluate(() => {
          const animations = document
            .getAnimations()
            .filter((animation) => (animation as CSSAnimation).animationName.startsWith("cmux-cadenced-shimmer-"));
          const timings = animations.map((animation) => ({
            name: (animation as CSSAnimation).animationName,
            duration: animation.effect!.getTiming().duration,
            iterations: animation.effect!.getTiming().iterations,
            easing: getComputedStyle((animation.effect as KeyframeEffect).target as Element).animationTimingFunction,
          }));
          for (const animation of animations) {
            animation.pause();
            animation.effect!.updateTiming({ delay: 0 });
          }
          const band = animations.find(
            (animation) => (animation as CSSAnimation).animationName === "cmux-cadenced-shimmer-band",
          )!;
          const lit = animations.find(
            (animation) => (animation as CSSAnimation).animationName === "cmux-cadenced-shimmer-lit",
          )!;
          const target = (band.effect as KeyframeEffect).target as HTMLElement;
          const copy = (lit.effect as KeyframeEffect).target as HTMLElement;
          const positions = [0.125, 0.375, 0.625, 0.875].map((progress) => {
            band.currentTime = lit.currentTime = progress * 1000;
            const bandX = new DOMMatrixReadOnly(getComputedStyle(target).transform).m41;
            const litX = new DOMMatrixReadOnly(getComputedStyle(copy).transform).m41;
            return { fraction: bandX / target.offsetWidth, copyOffset: bandX + litX };
          });
          return { timings, positions };
        });
        expect(sweep.timings).toHaveLength(2);
        for (const timing of sweep.timings) {
          expect(timing.duration).toBe(1000);
          expect(timing.iterations).toBe(1);
          expect(timing.easing).toMatch(/^steps\(48(?:, end)?\)$/);
        }
        for (const [index, position] of sweep.positions.entries()) {
          expect(position.fraction).toBeCloseTo(-0.5 + 1.75 * [0.125, 0.375, 0.625, 0.875][index]!, 2);
          expect(Math.abs(position.copyOffset)).toBeLessThan(0.5);
        }
        await active(page).waitFor({ state: "detached" });
        await expectIdle(page);
        await active(page).waitFor();
      } finally {
        await page.close();
      }
    });
  }

  test("a disabled nested activity scope retains text without shimmer animations", async () => {
    const page = await open();
    try {
      await mount(page, true, false);
      await page.clock.install();
      await page.clock.fastForward(10000);
      expect(await page.locator(".cv-tool__text").textContent()).toContain("Read file 0");
      await expectIdle(page);
    } finally {
      await page.close();
    }
  });

  for (const [attribute, value] of [
    ["data-status-indicators", "static"],
    ["data-cmux-motion", "off"],
    ["data-cmux-motion", "reduced"],
    ["data-agent-motion", "off"],
    ["data-agent-motion", "reduced"],
    ["data-cmux-page-hidden", ""],
  ] as const) {
    test(`${attribute}=${value} stops and restarts the cadence`, async () => {
      const page = await open();
      try {
        await mount(page, false);
        await active(page).waitFor();
        await page.evaluate(
          ([name, setting]) => document.documentElement.setAttribute(name, setting),
          [attribute, value],
        );
        await active(page).waitFor({ state: "detached" });
        await expectIdle(page);
        await page.evaluate((name) => document.documentElement.removeAttribute(name), attribute);
        await expectIdle(page);
        await active(page).waitFor();
      } finally {
        await page.close();
      }
    });
  }

  test("an offscreen label cancels its sweep and resumes when visible", async () => {
    const page = await open();
    try {
      await mount(page, true);
      await active(page).waitFor();
      await page.locator("#fixture").evaluate((element) => {
        element.style.display = "none";
      });
      await active(page).waitFor({ state: "detached" });
      await expectIdle(page);
      await page.locator("#fixture").evaluate((element) => {
        element.style.display = "";
      });
      await expectIdle(page);
      await active(page).waitFor();
    } finally {
      await page.close();
    }
  });

  test("system reduced motion stops an active sweep and allows a fresh visible sweep", async () => {
    const page = await open();
    try {
      await mount(page, false);
      await active(page).waitFor();
      await page.emulateMedia({ reducedMotion: "reduce" });
      await active(page).waitFor({ state: "detached" });
      await expectIdle(page);
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await expectIdle(page);
      await active(page).waitFor();
    } finally {
      await page.close();
    }
  });
});
