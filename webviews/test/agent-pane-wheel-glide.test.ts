// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A mouse wheel's notch glides the transcript over several frames instead of jumping (Leo
// 2026-10-22: "smoother scrolling in webkit: i mean with a mouse instead of just trackpad"), and a
// trackpad's scroll is left to the engine, applied as it comes. (wheelGlide.ts)
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts), in real Chromium and WebKit (the app's engine). Chromium's own wheel
// input is a notch (a legacy wheelDeltaY of 120 per tick). Playwright's WebKit wheel is a precise
// (trackpad) scroll on every platform, so WebKit's notch is the event macOS WebKit dispatches for a
// mouse wheel, built in the page: about 2.5 accelerated lines, 100.006103515625px, wheelDeltaY 300.
// CI fails the file when it cannot launch the engines (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-wheel-glide.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("agent-pane-wheel-glide.test.ts", async () => {
  setDefaultTimeout(300_000);
  /// One macOS WebKit wheel notch: its pixels are 16.16 fixed-point lines times 40.
  const MAC_NOTCH_PX = 100.006103515625;
  // Each engine launches once, here, and is kept for the tests: a launch to probe it, closed, and a
  // second launch in beforeAll left the first page of the run waiting forever on a loaded host
  // (huge-blue, 2026-10-22).
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`agent-pane-wheel-glide: skipping ${name}`);
    }
  }
  const engines = [...browsers.keys()];
  if (engines.length === 0) {
    describe.skip("wheel glide", () => test("browsers", () => {}));
    return;
  }
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => current!, { turns: 40, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  /// The pane scrolled up from its latest message to the middle of the chat, at rest, with the
  /// pointer over the transcript.
  async function open(): Promise<Page> {
    const page = await pane!.open();
    await installPaintedFrames(page);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = Math.round((scroller.scrollHeight - scroller.clientHeight) / 2);
    });
    await still(page);
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 160);
    return page;
  }

  /// Resolves once the transcript's offset has held for 6 painted frames.
  const still = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let last = scroller.scrollTop;
      for (let held = 0, frames = 0; held < 6 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        held = scroller.scrollTop === last ? held + 1 : 0;
        last = scroller.scrollTop;
      }
    });

  type Motion = { moved: number; frames: number; maxStep: number; glideMs: number; prevented: boolean[] };

  /// What `fire` does to the transcript's content, read once per painted frame until it has held for 6: how
  /// far it moved, over how many frames, its biggest move in one frame, how long it took from its
  /// first move to where it came to rest (frame times, so a loaded runner's skipped frames do not
  /// matter), and whether the page took each wheel event (defaultPrevented, read after every
  /// listener ran).
  async function motion(page: Page, fire: () => Promise<void>): Promise<Motion> {
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      // Where the content is, not the offset: rows above that measure while the view moves change the
      // offset to keep the reader's place, and nothing on screen moves for them. The row under the
      // middle is found again by its id each frame (the list may draw it anew).
      const box = scroller.getBoundingClientRect();
      const id = (
        document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!.closest(".acpmux-row") as HTMLElement
      ).dataset.rowId!;
      const content = () => -scroller.querySelector(`[data-row-id="${id}"]`)!.getBoundingClientRect().top;
      const record = { tops: [content()], times: [performance.now()], prevented: [] as boolean[] };
      const page = window as unknown as { wheelGlideRecord: typeof record; wheelGlideHeard?: boolean };
      page.wheelGlideRecord = record;
      // Once per page, reading the record of the moment: a bubbling listener on the window runs after
      // the transcript's own.
      if (!page.wheelGlideHeard)
        addEventListener("wheel", (event) => page.wheelGlideRecord.prevented.push(event.defaultPrevented));
      page.wheelGlideHeard = true;
      let held = 0;
      window.cmuxAfterPaint((time) => {
        const top = content();
        held = top === record.tops.at(-1) ? held + 1 : 0;
        record.tops.push(top);
        record.times.push(time);
        // Long enough for the wheel to arrive and its glide to finish.
        return record.tops.length < 20 || (held < 6 && record.tops.length < 300);
      });
    });
    await fire();
    await still(page);
    await page.waitForFunction(
      () => {
        const record = (window as unknown as { wheelGlideRecord: { tops: number[] } }).wheelGlideRecord;
        return record.tops.length >= 20;
      },
      undefined,
      { timeout: 10_000 },
    );
    const record = await page.evaluate(
      () =>
        (window as unknown as { wheelGlideRecord: { tops: number[]; times: number[]; prevented: boolean[] } })
          .wheelGlideRecord,
    );
    const { tops, times } = record;
    const steps = tops.slice(1).map((top, index) => top - tops[index]!);
    const rest = tops.at(-1)!;
    const first = tops.findIndex((top) => Math.abs(top - tops[0]!) >= 0.5);
    const arrived = tops.findIndex((top) => Math.abs(top - rest) < 1);
    return {
      moved: rest - tops[0]!,
      frames: steps.filter((step) => Math.abs(step) >= 0.5).length,
      maxStep: Math.max(...steps.map(Math.abs)),
      glideMs: first < 0 ? 0 : Math.round(times[arrived]! - times[first]!),
      prevented: record.prevented,
    };
  }

  /// Dispatches macOS WebKit's wheel notches (`deltaY` each) on the row under the middle of the
  /// transcript (found again for each: the list unmounts rows that scroll away), `gapFrames` painted
  /// frames apart (a spun wheel's notches come a few frames apart).
  const macNotches = (page: Page, deltas: number[], gapFrames = 0) =>
    page.evaluate(
      async ([deltas, gapFrames]) => {
        const box = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
        for (const [index, deltaY] of deltas.entries()) {
          if (index > 0) for (let frame = 0; frame < gapFrames; frame += 1) await window.cmuxPaintFrame();
          const row = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!;
          row.dispatchEvent(
            new WheelEvent("wheel", {
              deltaY,
              wheelDeltaY: Math.trunc(-3 * deltaY),
              bubbles: true,
              cancelable: true,
              composed: true,
            } as WheelEventInit),
          );
        }
      },
      [deltas, gapFrames] as const,
    );

  /// A glide: the page took the notch, and the view covered the whole distance through at least two
  /// positions on the way, taking at least 100 ms from its first move to its rest (the glide runs
  /// 180 ms, the motion scale's standard step; the engine's own wheel step lands in one frame in Chromium and two or three in WPE).
  function expectGlide(result: Motion, distance: number) {
    expect(result.prevented.length).toBeGreaterThan(0);
    expect(result.prevented.every(Boolean)).toBe(true);
    expect(Math.abs(result.moved - distance)).toBeLessThan(2);
    expect(result.frames).toBeGreaterThanOrEqual(3);
    expect(result.glideMs).toBeGreaterThanOrEqual(100);
  }

  for (const name of engines) {
    describe(name, () => {
      test("a mouse wheel's notch glides the transcript over several frames", async () => {
        current = browsers.get(name);
        const page = await open();
        const result = await motion(page, () => macNotches(page, [-MAC_NOTCH_PX]));
        console.log(`[wheel-glide] ${name} macOS notch: ${JSON.stringify(result)}`);
        expectGlide(result, -MAC_NOTCH_PX);
        // Down again glides back.
        expectGlide(await motion(page, () => macNotches(page, [MAC_NOTCH_PX])), MAC_NOTCH_PX);
        await page.close();
      });

      test("notches during a glide add to where it is headed", async () => {
        current = browsers.get(name);
        const page = await open();
        const result = await motion(page, () => macNotches(page, [-MAC_NOTCH_PX, -MAC_NOTCH_PX, -MAC_NOTCH_PX], 3));
        expectGlide(result, -3 * MAC_NOTCH_PX);
        await page.close();
      });

      test("a trackpad's scroll is the engine's, not taken by the page", async () => {
        current = browsers.get(name);
        const page = await open();
        // Chromium's precise scroll has a wheelDeltaY of three times its pixels (40px here, against
        // 120 for a tick); every Playwright WebKit wheel is a precise one.
        const delta = name === "chromium" ? -40 : -120;
        const result = await motion(page, () => page.mouse.wheel(0, delta));
        console.log(`[wheel-glide] ${name} trackpad ${delta}: ${JSON.stringify(result)}`);
        expect(result.prevented.length).toBeGreaterThan(0);
        expect(result.prevented.every((taken) => !taken)).toBe(true);
        expect(Math.abs(result.moved - delta)).toBeLessThan(2);
        // Chromium applies it in one frame; Linux WebKit animates any wheel step itself.
        if (name === "chromium") expect(result.frames).toBe(1);
        await page.close();
      });

      test("Reduce Motion and the Debug toggle leave the notch to the engine", async () => {
        current = browsers.get(name);
        for (const setup of ["reduce", "off"] as const) {
          const page = await open();
          if (setup === "reduce") await page.emulateMedia({ reducedMotion: "reduce" });
          else await page.evaluate(() => document.documentElement.setAttribute("data-wheel-glide", "off"));
          const result = await motion(page, () => macNotches(page, [-MAC_NOTCH_PX]));
          expect([setup, result.prevented]).toEqual([setup, [false]]);
          await page.close();
        }
      });

      // The wheel over Jump to latest reaches the transcript as a copy (wheelPassThrough.ts) that keeps
      // the wheel's modifiers, so a modified notch there is read as it would be over the transcript.
      test("a notch over Jump to latest reaches the transcript with its modifiers, and scrolls nothing", async () => {
        current = browsers.get(name);
        const page = await open();
        await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
        const { copies, moved } = await page.evaluate(async () => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          // Where the row under the transcript's middle is on screen: rows that measure change the
          // offset to keep the reader's place, and nothing on screen moves for them.
          const box = scroller.getBoundingClientRect();
          const id = (
            document
              .elementFromPoint(box.x + box.width / 2, box.y + box.height / 2)!
              .closest(".acpmux-row") as HTMLElement
          ).dataset.rowId!;
          const top = () => document.querySelector(`[data-row-id="${id}"]`)!.getBoundingClientRect().top;
          const before = top();
          const seen: { shift: boolean; alt: boolean; meta: boolean; legacy: number }[] = [];
          scroller.addEventListener("wheel", (event) =>
            seen.push({
              shift: event.shiftKey,
              alt: event.altKey,
              meta: event.metaKey,
              legacy: (event as WheelEvent & { wheelDeltaY: number }).wheelDeltaY,
            }),
          );
          const jump = document.querySelector(".acpmux-jump-latest")!;
          for (const modifiers of [{ shiftKey: true }, { altKey: true }, { metaKey: true }]) {
            // wheelDeltaY is WebKit and Chromium legacy, not in WheelEventInit's type.
            const init = { deltaY: -100.006103515625, wheelDeltaY: 300, bubbles: true, cancelable: true, ...modifiers };
            jump.dispatchEvent(new WheelEvent("wheel", init as WheelEventInit));
          }
          for (let frame = 0; frame < 10; frame += 1) await window.cmuxPaintFrame();
          return { copies: seen, moved: Math.round(top() - before) };
        });
        // A modified wheel is the engine's over the transcript itself; outside it, nothing scrolls.
        expect(moved).toBe(0);
        expect(copies).toEqual([
          { shift: true, alt: false, meta: false, legacy: 300 },
          { shift: false, alt: true, meta: false, legacy: 300 },
          { shift: false, alt: false, meta: true, legacy: 300 },
        ]);
        await page.close();
      });

      if (name === "chromium")
        // Chromium's own wheel input: a tick of 100px (as on Windows, or a fast notch on macOS).
        test("Chromium's wheel tick glides the transcript", async () => {
          current = browsers.get(name);
          const page = await open();
          const result = await motion(page, () => page.mouse.wheel(0, -100));
          console.log(`[wheel-glide] chromium tick: ${JSON.stringify(result)}`);
          expectGlide(result, -100);
          await page.close();
        });
    });
  }
});
