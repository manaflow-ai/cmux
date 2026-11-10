// The turn-end fold's clock grows when a later pass finds a move too long for it (turnEndFold.ts
// `turnEndFoldMs`: a long move runs longer so no frame moves more than 0.6 of a line). When it grows
// after a frame has painted, every row and copy goes on from where it was drawn, never from the
// swap's places: a row the growth did not move keeps going one way, and a copy that has started to
// fade never comes back up (review of #40350: a restart from the swap's places drew an unchanged row
// 10.5 px back and brightened a fading copy from 0.737 to 1).
//
// The page is the transcript's shape without the pane: rows placed by `top` in a thread, as the
// virtualizer places them. The fold plays on its first pass's moves (the copies tuck 70 px: 272 ms);
// two painted frames later one row below is placed 274 px lower, as rows the virtualizer mounts move
// the rows under them, a move that needs the longest clock (720 ms), and the clock grows.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("turn-end-fold-clock-growth-browser.test.ts", async () => {
  setDefaultTimeout(60_000);
  let browser: Browser;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("turn-end-fold-clock-growth-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn end fold clock growth", () => test("chromium", () => {}));
    return;
  }
  let script = "";
  let scratch = "";

  beforeAll(async () => {
    // The module under test, bundled for the page: window.__fold holds its capture and play.
    scratch = await mkdtemp(path.join(os.tmpdir(), "turn-end-growth-"));
    const entry = path.join(scratch, "entry.ts");
    const module = path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/turnEndFold.ts");
    await writeFile(
      entry,
      `import { captureTurnEnd, playTurnEnd } from ${JSON.stringify(module)};\n` +
        `(window as any).__fold = { captureTurnEnd, playTurnEnd };\n`,
    );
    const built = await Bun.build({ entrypoints: [entry], format: "iife", target: "browser" });
    if (!built.success) throw new Error(built.logs.map(String).join("\n"));
    script = await built.outputs[0]!.text();
  });
  afterAll(async () => {
    await browser?.close();
    if (scratch) await rm(scratch, { recursive: true, force: true });
  });

  /// Rows: id, top, height (px), in order.
  const BEFORE: [string, number, number][] = [
    ["a", 0, 30],
    ["work", 30, 10],
    ["b", 40, 30],
    ["c", 70, 30],
    ["thinking-live", 100, 30],
  ];
  const AFTER: [string, number, number][] = [
    ["a", 0, 30],
    ["worked", 30, 4],
    ["b", 34, 30],
    ["c", 64, 30],
  ];

  test("a clock that grows after a painted frame draws nothing back and brightens no fading copy", async () => {
    const page = await browser.newPage({ viewport: { width: 600, height: 500 } });
    try {
      const rows = (list: [string, number, number][]) =>
        list
          .map(
            ([id, top, height], index) =>
              `<div class="acpmux-row" data-row-id="${id}" aria-posinset="${index + 1}" ` +
              `style="position:absolute;left:0;right:0;top:${top}px;height:${height}px">${id}</div>`,
          )
          .join("");
      await page.setContent(
        `<!doctype html><html style="--cmux-motion-settle:180ms;--cv-fold-duration:180ms">` +
          `<body style="margin:0"><div class="acpmux-scroll" style="height:400px;overflow:auto">` +
          `<div class="acpmux-thread" style="position:relative;height:400px">${rows(BEFORE)}</div></div></body></html>`,
      );
      await page.addScriptTag({ content: script });
      const out = await page.evaluate(
        async ({ after, html }) => {
          const fold = (window as any).__fold;
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const thread = document.querySelector<HTMLElement>(".acpmux-thread")!;
          const afterRows = after.map(([id]: [string, number, number]) => ({ id, version: 1, at: 1, kind: "assistant" }));
          const capture = fold.captureTurnEnd(thread, scroller, afterRows, "s");
          if (!capture) return { error: "nothing captured" };
          // The swap: the work and the running line go, "Worked for" comes, the rows below close up.
          thread.innerHTML = html;
          const played = fold.playTurnEnd(thread, capture, "s", scroller);
          if (!played) return { error: "nothing played" };
          const copy = thread.querySelector<HTMLElement>(".acpmux-row--fold-ghost");
          const b = thread.querySelector<HTMLElement>('[data-row-id="b"]')!;
          const c = thread.querySelector<HTMLElement>('[data-row-id="c"]')!;
          const samples: { t: number; b: number; ink: number }[] = [];
          const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
          for (let index = 0; index < 90; index++) {
            await frame();
            samples.push({
              t: performance.now(),
              b: b.getBoundingClientRect().top,
              ink: copy ? Number.parseFloat(getComputedStyle(copy).opacity) : 0,
            });
            // A frame painted with the fold under way (b drawn part way up, the copies part faded), still
            // inside the growth window (one 60 Hz frame after the first): c is placed 274 px lower, and
            // the clock grows. Grown at the first frame, nothing has moved yet to be drawn back.
            if (index === 1) c.style.top = "344px";
          }
          return { samples, copy: Boolean(copy) };
        },
        {
          after: AFTER,
          html: AFTER.map(
            ([id, top, height], index) =>
              `<div class="acpmux-row" data-row-id="${id}" aria-posinset="${index + 1}" ` +
              `style="position:absolute;left:0;right:0;top:${top}px;height:${height}px">${id}</div>`,
          ).join(""),
        },
      );
      expect(out.error).toBeUndefined();
      expect(out.copy).toBe(true);
      const samples = out.samples!;
      // b starts 6 px below its place (40 -> 34) and only ever rises to it.
      const rose = samples.map((sample, index) => (index ? sample.b - samples[index - 1]!.b : 0));
      const back = rose.map((step, index) => ({ index, step })).filter(({ step }) => step > 0.05);
      console.log(
        `turn-end clock growth: b ${samples.map((s) => s.b.toFixed(2)).join(" ")}; ` +
          `ink ${samples.map((s) => s.ink.toFixed(3)).join(" ")}`,
      );
      expect(back).toEqual([]);
      expect(samples.at(-1)!.b).toBeCloseTo(34, 1);
      // The clock grew: b still moves past 200 ms (on the first pass's 272 ms it rests at about 170 ms).
      const moving = samples.filter((sample) => sample.b > 34.02).at(-1)!;
      expect(moving.t - samples[0]!.t).toBeGreaterThan(200);
      // The copy of the work only ever fades.
      const brightened = samples
        .map((sample, index) => ({ index, step: index ? sample.ink - samples[index - 1]!.ink : 0 }))
        .filter(({ step }) => step > 0.005);
      expect(brightened).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
