// Feel check: the page-drawn context menu (ui/ContextMenu.tsx, ui/pressRelease.ts), on its gallery
// entry ui.context-menu. Leo, 2026-11-22: "these should be doable via automation. the "feel" and
// "vibes" thing. you can simulate cursors clicking around", and on the simulated-cursor check: "i mean
// this to say we can use it on various other parts of the app".
//
// A simulated cursor (test/feel/cursor.ts) right-clicks the target, presses and holds with a shaky
// hand, right-drags onto a row and lets go there, misses the open menu by 3 px on each side, double
// clicks and double right-clicks, and opens the menu at the window's corner, with forty rows and with
// a link-length label. The probe reads every painted frame. Verdicts (numbers, not screenshots;
// test/feel/verdicts.ts):
// - a right-click opens the menu once, under the pointer, within two frames, and it holds still;
// - a press that wobbles or is held picks nothing; a right-drag onto a row picks that row;
// - a click just outside the menu closes it once, picks nothing and moves nothing;
// - a double-click opens no menu (no flicker); a double right-click leaves the menu open;
// - at the corner, with forty rows or a long label, the menu stays in the window and holds still.
// The report and a recording per scenario go to $CMUX_FEEL_OUT/context-menu (test/feel/report.ts).
import { describe, setDefaultTimeout, test } from "bun:test";
import type { Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { aroundHandle, dragPath, play, wobblePath, type Point, type Step } from "./feel/cursor";
import { frames, record } from "./feel/probe";
import { chromiumLaunches, expectPass, feelStage } from "./feel/stage";
import type { FeelTrace, ProbeSpec } from "./feel/trace";
import { churn, flips, still, values } from "./feel/verdicts";

await requireBrowserLane("feel-context-menu.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await chromiumLaunches())) {
    describe.skip("feel: context menu", () => test("chromium", () => {}));
    return;
  }

  const TARGET = '[data-testid="context-target"]';
  const MENU = '.ui-context-menu[role="menu"]';
  // The menu is in the page, hidden, until it is placed: shown is placed.
  const SHOWN = `${MENU}:not([style*="hidden"])`;
  const VIEWPORT = { width: 560, height: 360 };
  const SPEC: ProbeSpec = {
    boxes: { target: TARGET, menu: SHOWN, copy: '[data-testid="selection-target"]' },
    texts: { receipt: '[data-testid="context-menu-gallery-receipt"]' },
    states: { shown: { selector: SHOWN } },
  };

  const { scenario, testFor } = feelStage({
    entry: "ui.context-menu",
    variant: "closed",
    component: "context-menu",
    viewport: VIEWPORT,
    prepare: async (page) => void (await page.waitForSelector(TARGET)),
    known: {
      // Red today, no lane on it yet: the second press lands on the open menu's backdrop, whose
      // contextmenu handler closes the menu and does not open it again at the pointer.
      "double-right-click": "unowned: a second right-click closes the menu it just opened (open, then gone)",
    },
  });

  /** A right-button press at `at`, moved along `steps` while held, `hold` painted frames more, and let go. */
  const rightPress = async (page: Page, at: Point, steps: Step[] = [], hold = 0) => {
    await page.mouse.move(at.x, at.y);
    await frames(page, 1);
    await page.mouse.down({ button: "right" });
    await frames(page, 1);
    await play(page, steps);
    if (hold > 0) await frames(page, hold);
    await page.mouse.up({ button: "right" });
    await frames(page, 1);
  };

  const centreOf = async (page: Page, selector: string) => {
    const box = (await page.locator(selector).boundingBox())!;
    return { x: box.x + box.width / 2, y: box.y + box.height / 2, box };
  };
  /** A point on the target off its centre, so the menu opens where it has room either way. */
  const grab = async (page: Page) => {
    const { box } = await centreOf(page, TARGET);
    return { x: box.x + box.width / 3, y: box.y + box.height / 2 };
  };

  /** Frames from the press to the first frame the menu is drawn (Infinity: it never was). */
  const framesToShow = (trace: FeelTrace) => {
    const down = trace.events.find((event) => event.type === "pointerdown");
    if (!down) return Number.POSITIVE_INFINITY;
    const after = trace.frames.filter((frame) => frame.t > down.t);
    const index = after.findIndex((frame) => frame.states.shown === "1");
    return index < 0 ? Number.POSITIVE_INFINITY : index + 1;
  };
  /** How far the drawn menu moved from its first drawn frame (a reposition after it shows). */
  const menuDrift = (trace: FeelTrace) => {
    const shown = trace.frames.filter((frame) => frame.boxes.menu);
    if (shown.length === 0) return 0;
    const first = shown[0]!.boxes.menu!;
    return Math.max(
      ...shown.map(({ boxes: { menu } }) =>
        Math.max(Math.abs(menu!.x - first.x), Math.abs(menu!.y - first.y), Math.abs(menu!.w - first.w)),
      ),
    );
  };
  const lastMenu = (trace: FeelTrace) => [...trace.frames].reverse().find((frame) => frame.boxes.menu)?.boxes.menu;
  const receiptOf = (trace: FeelTrace) => trace.frames.at(-1)?.texts.receipt?.text ?? null;

  describe("feel: context menu", () => {
    for (const [name, wobble, hold] of [
      ["right-click", 0, 0],
      ["right-wobble-3px", 3, 0],
      ["right-hold-wobble", 3, 18],
    ] as const)
      testFor(name)(
        `${name}: the menu opens once under the pointer within two frames, holds still, picks nothing`,
        async () => {
          const verdicts = await scenario(name, async (page, v) => {
            const at = await grab(page);
            const trace = await record(page, SPEC, () =>
              rightPress(page, at, wobble > 0 ? wobblePath(at, wobble) : [], hold),
            );
            const menu = lastMenu(trace);
            const offset = menu ? Math.max(Math.abs(menu.x - at.x), Math.abs(menu.y - at.y)) : Infinity;
            const shownIn = framesToShow(trace);
            const report = still(trace);
            v.equals("menu shown, once", values(trace, "shown"), [null, "1"]);
            v.atMost("frames from the press to the menu drawn", shownIn, 2);
            v.atMost("menu corner off the press point", offset, wobble + 2, " px");
            v.atMost("menu moved after it showed", menuDrift(trace), 0.5, " px");
            v.equals("picked", receiptOf(trace), "Ready");
            v.atMost("target moved", report.moved.target ?? 0, 0.5, " px");
            v.atMost("layout shift", report.shift, 0.01);
            return { shownIn, offset, drift: menuDrift(trace), moved: report.moved, shift: report.shift };
          });
          expectPass(verdicts);
        },
      );

    for (const style of ["slow", "fast", "jitter"] as const)
      testFor(`right-drag-${style}`)(`a right-drag (${style}) onto Rename, let go there: picks Rename`, async () => {
        const verdicts = await scenario(`right-drag-${style}`, async (page, v) => {
          const at = await grab(page);
          const trace = await record(page, SPEC, async () => {
            await page.mouse.move(at.x, at.y);
            await frames(page, 1);
            await page.mouse.down({ button: "right" });
            await page.waitForSelector(SHOWN);
            const rowBox = (await page.locator(`${MENU} [role="menuitem"]`).nth(1).boundingBox())!;
            const row = { x: rowBox.x + rowBox.width / 2, y: rowBox.y + rowBox.height / 2 };
            await play(page, dragPath(at, row, style));
            await page.mouse.up({ button: "right" });
            await frames(page, 1);
          });
          const receipt = churn(trace, "receipt");
          v.equals("picked", receiptOf(trace), "Renamed");
          v.atMost("receipt swaps", receipt.swaps, 1);
          v.equals("menu shown then closed", values(trace, "shown"), [null, "1", null]);
          v.atMost("menu moved while the hand crossed it", menuDrift(trace), 0.5, " px");
          return { receipt: receiptOf(trace), swaps: receipt.swaps, drift: menuDrift(trace) };
        });
        expectPass(verdicts);
      });

    testFor("miss-around")("a click 3 px outside the open menu closes it once, picks and moves nothing", async () => {
      const verdicts = await scenario("miss-around", async (page, v) => {
        const sides: Record<string, unknown> = {};
        let worstMoved = 0;
        let shift = 0;
        for (const side of ["above", "below", "left", "right"] as const) {
          const at = await grab(page);
          await rightPress(page, at);
          await page.waitForSelector(SHOWN);
          await frames(page, 4);
          const { box } = await centreOf(page, SHOWN);
          const around = aroundHandle({ x: box.x, y: box.y, w: box.width, h: box.height }, 3);
          // aroundHandle's left and right are just inside a handle; a miss is just outside.
          const miss =
            side === "left"
              ? { x: box.x - 3, y: around.centre.y }
              : side === "right"
                ? { x: box.x + box.width + 3, y: around.centre.y }
                : around[side];
          const trace = await record(page, SPEC, async () => {
            await page.mouse.move(miss.x, miss.y);
            await frames(page, 1);
            await page.mouse.down();
            await frames(page, 1);
            await page.mouse.up();
            await frames(page, 1);
          });
          const report = still(trace);
          const shown = values(trace, "shown");
          v.equals(`${side}: menu closed, once`, shown, ["1", null]);
          v.equals(`${side}: picked`, receiptOf(trace), "Ready");
          worstMoved = Math.max(worstMoved, report.moved.target ?? 0, report.moved.copy ?? 0);
          shift += report.shift;
          sides[side] = { miss, shown, receipt: receiptOf(trace) };
          await frames(page, 4);
        }
        v.atMost("target or copy moved (worst side)", worstMoved, 0.5, " px");
        v.atMost("layout shift (all sides)", shift, 0.01);
        return { sides, worstMoved, shift };
      });
      expectPass(verdicts);
    });

    testFor("double-click")("a double-click on the target opens no menu: no flicker", async () => {
      const verdicts = await scenario("double-click", async (page, v) => {
        const at = await grab(page);
        const trace = await record(page, SPEC, async () => {
          await page.mouse.move(at.x, at.y);
          await frames(page, 1);
          await page.mouse.dblclick(at.x, at.y);
          await frames(page, 1);
        });
        const report = still(trace);
        v.atMost("menu shown/hidden changes", flips(trace, "shown"), 0);
        v.equals("picked", receiptOf(trace), "Ready");
        v.atMost("target moved", report.moved.target ?? 0, 0.5, " px");
        return { shown: values(trace, "shown"), moved: report.moved };
      });
      expectPass(verdicts);
    });

    testFor("double-right-click")("a double right-click: the menu ends open, under the pointer", async () => {
      const verdicts = await scenario("double-right-click", async (page, v) => {
        const at = await grab(page);
        // Two right-clicks a hand's double-click apart (about 100 ms: six frames), on one spot.
        const trace = await record(page, SPEC, async () => {
          await rightPress(page, at);
          await frames(page, 5);
          await rightPress(page, at);
        });
        const shown = values(trace, "shown");
        v.equals("menu open at the end", shown.at(-1), "1");
        v.atMost("menu shown/hidden changes", flips(trace, "shown"), 1);
        v.equals("picked", receiptOf(trace), "Ready");
        const events = trace.events.map((event) => `${event.type}:${event.buttons}:${event.detail}`);
        return { shown, events };
      });
      expectPass(verdicts);
    });

    for (const [variant, limit] of [
      ["edge", 0],
      ["overflowing", 0],
      ["long-label", 360],
    ] as const)
      testFor(`extreme-${variant}`)(
        `${variant}: a right-click opens the menu in the window, once, and it holds still`,
        async () => {
          const verdicts = await scenario(
            `extreme-${variant}`,
            async (page, v) => {
              // The variant's own play opened the menu: closed first, so the hand opens it.
              await page.keyboard.press("Escape");
              await page.waitForSelector(MENU, { state: "detached" });
              await frames(page, 4);
              const at = await grab(page);
              const trace = await record(page, SPEC, () => rightPress(page, at));
              const menu = lastMenu(trace);
              const outside = menu
                ? Math.max(0, -menu.x, -menu.y, menu.x + menu.w - VIEWPORT.width, menu.y + menu.h - VIEWPORT.height)
                : Infinity;
              v.equals("menu shown, once", values(trace, "shown"), [null, "1"]);
              v.atMost("frames from the press to the menu drawn", framesToShow(trace), 2);
              v.atMost("menu past the window's edge", outside, 0, " px");
              v.atMost("menu moved after it showed", menuDrift(trace), 0.5, " px");
              if (limit > 0) v.atMost("menu width", menu?.w ?? Infinity, limit, " px");
              v.equals("picked", receiptOf(trace), "Ready");
              return { menu, outside, drift: menuDrift(trace), shownIn: framesToShow(trace) };
            },
            variant,
          );
          expectPass(verdicts);
        },
      );
  });
});
