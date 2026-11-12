// cmux-web-test-timeout: 420
// l10n-allow-file: wheel-motion fixtures, not shipped text.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, webkit, type Browser } from "playwright";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-wheel-glide.test.ts", async () => {
  setDefaultTimeout(120_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch();
    pane = await papercutPane(() => browser, { turns: 60, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });
  for (const engine of ["chromium", "webkit"] as const) {
    describe(engine, () => {
      test("a notch covers its distance over several painted frames", async () => {
        await browser.close();
        browser = await (engine === "chromium" ? chromium : webkit).launch();
        if (process.env.CMUX_WHEEL_TRACE_DIR) {
          const openPage = browser.newPage.bind(browser);
          browser.newPage = (options) =>
            openPage({
              ...options,
              recordVideo: {
                dir: process.env.CMUX_WHEEL_TRACE_DIR!,
                size: { width: 900, height: 700 },
              },
            });
        }
        const page = await pane.open();
        try {
          const trace = await page.evaluate(async (engine) => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            // The glide runs on the clock, so a loaded runner painting a frame every ~76 ms fit the
            // ~190 ms move into two frames (#27710's base replay). A 1 s move spans several painted
            // frames however slowly they come; a jump still lands in one.
            node.style.setProperty("--agent-motion-move", "1s");
            const values = [node.scrollTop];
            const times = [performance.now()];
            const prevented: boolean[] = [];
            let sawMotion = false;
            node.addEventListener("wheel", (event) => prevented.push(event.defaultPrevented));
            node.addEventListener("acpmux-motion-scroll", () => {
              sawMotion = true;
            });
            (window as any).__wheelTrace = { values, times, prevented };
            (window as any).__wheelSettled = false;
            let steady = 0;
            let previous = node.scrollTop;
            window.cmuxAfterPaint(() => {
              const current = node.scrollTop;
              values.push(current);
              times.push(performance.now());
              // The eased tail writes whole pixels and may rest a few frames short of the notch, so
              // the glide has settled only once it has also covered the notch's 100 px.
              const arrived = Math.abs(current - values[0]!) >= 99.5;
              if (sawMotion && arrived && Math.abs(current - previous) <= 0.5) steady += 1;
              else steady = 0;
              previous = current;
              if (steady >= 3) {
                (window as any).__wheelSettled = true;
                return false;
              }
              return true;
            });
            if (engine === "webkit") {
              // macOS WebKit's non-precise wheel: accelerated lines use 16.16 fixed point.
              const event = new WheelEvent("wheel", { deltaY: -100.006103515625, cancelable: true });
              Object.defineProperty(event, "wheelDeltaY", { value: 300 });
              node.dispatchEvent(event);
            }
            return { start: node.scrollTop };
          }, engine);
          if (engine === "chromium") {
            const box = await page.locator(".acpmux-scroll").boundingBox();
            await page.mouse.move(box!.x + box!.width / 2, box!.y + box!.height / 2);
            await page.mouse.wheel(0, -100);
          }
          await page.waitForFunction(() => (window as any).__wheelSettled === true, undefined, { timeout: 5_000 });
          const result = await page.evaluate(
            () =>
              (window as any).__wheelTrace as {
                values: number[];
                times: number[];
                prevented: boolean[];
              },
          );
          const steps = result.values.slice(1).map((top, i) => Math.abs(top - result.values[i]!));
          const moved = steps.filter((by) => by > 0.5);
          const metrics = {
            engine,
            start: trace.start,
            end: result.values.at(-1),
            movingFrames: moved.length,
            maxStep: Math.max(...steps),
            prevented: result.prevented,
            values: result.values,
          };
          console.log("wheel-glide-trace", JSON.stringify(metrics));
          if (process.env.CMUX_WHEEL_TRACE_DIR) {
            await mkdir(process.env.CMUX_WHEEL_TRACE_DIR, { recursive: true });
            await writeFile(`${process.env.CMUX_WHEEL_TRACE_DIR}/${engine}.json`, JSON.stringify(metrics));
            await page.screenshot({ path: `${process.env.CMUX_WHEEL_TRACE_DIR}/${engine}.png` });
          }
          expect(result.prevented).toContain(true);
          expect(result.values.slice(1).every((top, index) => top <= result.values[index]!)).toBe(true);
          expect(Math.abs(result.values.at(-1)! - result.values[0]!)).toBeCloseTo(100, 0);
          expect(moved.length).toBeGreaterThanOrEqual(3);
          const distance = Math.abs(result.values.at(-1)! - result.values[0]!);
          expect(Math.max(...steps)).toBeLessThan(distance);
        } finally {
          await page.close();
          if (process.env.CMUX_WHEEL_TRACE_DIR && page.video())
            await page.video()!.saveAs(`${process.env.CMUX_WHEEL_TRACE_DIR}/${engine}.webm`);
        }
      });
      test("an asynchronous send takes the view from an unfinished wheel glide", async () => {
        const page = await pane.open();
        try {
          const gaps = await page.evaluate(async () => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            node.style.setProperty("--agent-motion-move", "1s");
            node.dispatchEvent(new WheelEvent("wheel", { deltaY: -20, deltaMode: 1, cancelable: true }));
            await window.cmuxPaintFrame();
            // The wheel glide read its 1s step at the wheel; the send's ride reads the standard step.
            node.style.setProperty("--agent-motion-move", "180ms");
            await window.cmuxAcpmuxActions!["chat.send"]!({ text: "Wheel ownership" });
            const gaps: number[] = [];
            for (let i = 0; i < 60; i++) {
              await window.cmuxPaintFrame();
              gaps.push(node.scrollHeight - node.clientHeight - node.scrollTop);
            }
            return gaps;
          });
          // The send rides the view down to the latest message (Jump to latest's ride): the wheel's
          // unfinished glide never pulls it back up, and it rests at the end.
          for (let i = 4; i < gaps.length; i++) expect(gaps[i]!).toBeLessThanOrEqual(gaps[i - 1]! + 1);
          // A ride, not a cut: the view is still on its way to the end over several painted frames.
          expect(gaps.filter((gap) => gap > 1).length).toBeGreaterThanOrEqual(3);
          expect(Math.max(...gaps.slice(-10))).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
        // With CMUX_MOTION_STILLS=<dir>: whole-window stills of the same steps, for review (#41456):
        // the wheel's glide under way, then frames of the send's ride to the new message, which rests
        // there with no cut. Each still is taken between painted frames, so the ride shows its curve.
        const stills = process.env.CMUX_MOTION_STILLS;
        if (!stills) return;
        const dir = `${stills}/send-during-wheel-glide/${engine}`;
        await mkdir(dir, { recursive: true });
        const shot = await pane.open();
        try {
          await shot.evaluate(async () => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            node.style.setProperty("--agent-motion-move", "1s");
            node.dispatchEvent(new WheelEvent("wheel", { deltaY: -20, deltaMode: 1, cancelable: true }));
            await window.cmuxPaintFrame();
            await window.cmuxPaintFrame();
          });
          await shot.screenshot({ path: `${dir}/0-wheel-glide-under-way.png` });
          await shot.evaluate(async () => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            node.style.setProperty("--agent-motion-move", "180ms");
            await window.cmuxAcpmuxActions!["chat.send"]!({ text: "Wheel ownership" });
          });
          for (let frame = 1; frame <= 40; frame += 1) {
            await shot.evaluate(() => window.cmuxPaintFrame());
            if ([1, 3, 6, 10, 40].includes(frame))
              await shot.screenshot({ path: `${dir}/${String(frame).padStart(2, "0")}-send-ride-frame-${frame}.png` });
          }
        } finally {
          await shot.close();
        }
      });
      test("precise, modified and reduced-motion wheels remain native", async () => {
        const page = await pane.open();
        try {
          const result = await page.evaluate(() => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const wheel = (deltaY: number, extra: WheelEventInit = {}) => {
              const event = new WheelEvent("wheel", { deltaY, cancelable: true, ...extra });
              Object.defineProperty(event, "wheelDeltaY", { value: -deltaY * 3 });
              node.dispatchEvent(event);
              return event.defaultPrevented;
            };
            const precise = wheel(-40);
            const modified = wheel(-100.006103515625, { metaKey: true });
            document.documentElement.dataset.agentMotion = "off";
            const motionOff = wheel(-100.006103515625);
            return { precise, modified, motionOff };
          });
          expect(result).toEqual({ precise: false, modified: false, motionOff: false });
        } finally {
          await page.close();
        }
      });
    });
  }
});
