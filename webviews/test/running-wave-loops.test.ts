// RUNNING-WAVE (ui/wave.ts) in Chromium: the real stylesheet gives each running item its index
// offset of the one `cmux-wave` loop, all items take one shared start, and the motion gate
// (`data-cmux-motion` off or reduced, set by the app's WebTheme bootstrap), static status
// indicators, Reduce Motion and a hidden page stop it.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { readWebThemeBootstrap } from "../dev-server/galleryHost";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("running-wave-loops.test.ts", async () => {
  setDefaultTimeout(60_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("running-wave-loops: skipping (run `bunx playwright install chromium`)");
    describe.skip("running wave loops", () => test("chromium", () => {}));
    return;
  }

  const src = path.resolve(import.meta.dir, "../src");
  const css = readFileSync(path.join(src, "ui/wave.css"), "utf8");
  const bootstrap = readWebThemeBootstrap();
  // The wave's runtime half (ui/wave.ts installWave), as the page bundle runs it.
  const install = await Bun.build({
    entrypoints: [path.join(import.meta.dir, "support/installWave.entry.ts")],
    target: "browser",
  }).then((result) => result.outputs[0].text());
  const items =
    `<span class="acpmux-wave-item" style="--wave-index:0"></span>` +
    `<span class="still"></span>` +
    `<span class="acpmux-wave-item" style="--wave-index:2"></span>`;

  let browser: Browser | undefined;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  const frames = (p: Page) =>
    p.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));

  async function page(reducedMotion: "reduce" | "no-preference"): Promise<Page> {
    const p = await browser!.newPage();
    await p.emulateMedia({ reducedMotion });
    await p.setContent(`<style>${css}</style>`);
    await p.addScriptTag({ content: bootstrap });
    await p.addScriptTag({ content: install });
    await p.evaluate((body) => (document.body.innerHTML = body), items);
    await frames(p);
    return p;
  }

  /** The running wave loops: each one's delay and start. */
  const waves = (p: Page) =>
    p.evaluate(() =>
      document
        .getAnimations()
        .filter(
          (animation) => (animation as CSSAnimation).animationName === "cmux-wave" && animation.playState === "running",
        )
        .map((animation) => ({
          delay: Number(animation.effect?.getTiming().delay),
          start: Number(animation.startTime),
        })),
    );

  async function setTheme(p: Page, payload: object) {
    await p.evaluate(
      (value) =>
        (window as unknown as { cmuxTheme: { apply(payload: object): void } }).cmuxTheme.apply({
          variables: {},
          colorScheme: "light",
          ...value,
        }),
      payload,
    );
    await frames(p);
  }

  test("running items sweep by index on one shared start; a still item runs nothing", async () => {
    const p = await page("no-preference");
    const running = await waves(p);
    await p.close();
    expect(running.length).toBe(2);
    // Two steps of 120 ms apart, both pulled back whole periods so neither waits at rest.
    expect(running[1].delay - running[0].delay).toBeCloseTo(240, 3);
    expect(Math.max(...running.map((loop) => loop.delay))).toBeLessThan(0);
    expect(running[0].start).toBe(running[1].start);
  });

  test("the motion gate, static indicators, Reduce Motion and a hidden page stop it", async () => {
    for (const payload of [{ motion: "off" }, { motion: "reduced" }, { statusIndicators: "static" }]) {
      const p = await page("no-preference");
      expect((await waves(p)).length).toBe(2);
      await setTheme(p, payload);
      expect({ payload, running: await waves(p) }).toEqual({ payload, running: [] });
      await p.close();
    }
    const reduced = await page("reduce");
    expect(await waves(reduced)).toEqual([]);
    await reduced.close();
    const hidden = await page("no-preference");
    // The page goes hidden (a tab or workspace switch), then shows again.
    const visibility = (state: "hidden" | "visible") =>
      hidden.evaluate((value) => {
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => value });
        document.dispatchEvent(new Event("visibilitychange"));
      }, state);
    await visibility("hidden");
    await frames(hidden);
    expect(await waves(hidden)).toEqual([]);
    await visibility("visible");
    await frames(hidden);
    const back = await waves(hidden);
    expect(back.length).toBe(2);
    expect(back[0].start).toBe(back[1].start);
    await hidden.close();
  });
});
