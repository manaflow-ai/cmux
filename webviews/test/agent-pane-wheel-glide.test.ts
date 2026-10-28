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
            const values = [node.scrollTop];
            const times = [performance.now()];
            const prevented: boolean[] = [];
            node.addEventListener("wheel", (event) => prevented.push(event.defaultPrevented));
            (window as any).__wheelTrace = { values, times, prevented };
            window.cmuxAfterPaint(() => {
              values.push(node.scrollTop);
              times.push(performance.now());
              return values.length < 35;
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
          await page.waitForFunction(() => (window as any).__wheelTrace.values.length === 35);
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
          expect(Math.max(...steps)).toBeLessThan(60);
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
            await window.cmuxAcpmuxActions!["chat.send"]!({ text: "Wheel ownership" });
            const gaps: number[] = [];
            for (let i = 0; i < 30; i++) {
              await window.cmuxPaintFrame();
              gaps.push(node.scrollHeight - node.clientHeight - node.scrollTop);
            }
            return gaps;
          });
          expect(Math.max(...gaps.slice(3))).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
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
