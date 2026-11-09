// The prompt rail on the pane's left edge keeps the spacing the right-edge rail has: the same inset from
// its edge to its ticks, the same room from its ticks to the text, the same top, and one pitch between
// rows (ask "Fix scroll redraw flicker in session info; fix left session rail spacing").
// SESSION-RAIL-SPACING lines print each side's measured spacing.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("thread-rail-left-spacing.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    describe.skip("left rail spacing", () => test("chromium", () => {}));
    return;
  }
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => browser!, { turns: 12, running: false });
  });
  afterAll(async () => {
    await browser?.close();
    await pane?.close();
  });

  const settle = (page: Page) =>
    page.evaluate(() =>
      Promise.all(document.getAnimations().map((animation) => animation.finished.catch(() => undefined))),
    );
  /// Settings > Agent Chat > Prompt Rail Side and Session Info's placement, written together (the
  /// display event carries every key: one written alone resets the other).
  const railSide = (page: Page, side: "left" | "right", push = false) =>
    page.evaluate(
      async ({ side, push }) => {
        const url = "/chatDisplay.ts";
        const display = (await import(/* @vite-ignore */ url)) as { setChatDisplay(value: unknown): void };
        display.setChatDisplay({
          "agentPane.display.rail.side": side,
          "agentPane.display.sessionInfo.placement": push ? "push" : "overlay",
        });
      },
      { side, push },
    );
  const closeSessionInfo = async (page: Page) => {
    await page.evaluate(() =>
      (window as any).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
    const toggle = page.locator("button.acpmux-session-info-toggle");
    await toggle.waitFor({ timeout: 10_000 });
    if ((await toggle.getAttribute("aria-pressed")) === "true") await toggle.click({ force: true });
    await page.locator("aside.acpmux-session-info").waitFor({ state: "detached", timeout: 5_000 });
  };

  /// The rail's spacing on its side, in px, each measured from that side's pane edge (the scroller's
  /// content box, so a scrollbar on the right is outside it).
  const spacing = (page: Page) =>
    page.evaluate(() => {
      const nav = document.querySelector<HTMLElement>(".acpmux-minimap__rail:not(.acpmux-scrollmap)")!;
      const side = nav.getAttribute("data-side") ?? "left";
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const box = scroller.getBoundingClientRect();
      const paneLeft = box.left + scroller.clientLeft;
      const paneRight = paneLeft + scroller.clientWidth;
      const rail = nav.getBoundingClientRect();
      const bars = [...nav.querySelectorAll<HTMLElement>(".acpmux-minimap__bar")]
        .map((bar) => bar.getBoundingClientRect())
        .filter((bar) => bar.height > 0 && bar.bottom > rail.top && bar.top < rail.bottom);
      // The text column: the rows' text, the nearest edge on the rail's side.
      const texts = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((row) => row.getBoundingClientRect())
        .filter((row) => row.width > 0 && row.bottom > box.top && row.top < box.bottom);
      const columnLeft = Math.min(...texts.map((row) => row.left));
      const columnRight = Math.max(...texts.map((row) => row.right));
      const barEdge = side === "right" ? Math.max(...bars.map((bar) => bar.right)) : Math.min(...bars.map((bar) => bar.left));
      const barInner = side === "right" ? Math.min(...bars.map((bar) => bar.left)) : Math.max(...bars.map((bar) => bar.right));
      const r = (n: number) => Math.round(n * 10) / 10;
      const tops = bars.map((bar) => bar.top).sort((a, b) => a - b);
      const pitches = [...new Set(tops.slice(1).map((top, i) => r(top - tops[i]!)))];
      return {
        side,
        railEdge: r(side === "right" ? paneRight - rail.right : rail.left - paneLeft),
        tickEdge: r(side === "right" ? paneRight - barEdge : barEdge - paneLeft),
        tickToText: r(side === "right" ? barInner - columnRight : columnLeft - barInner),
        railTop: r(rail.top - box.top),
        railWidth: r(rail.width),
        pitches,
        occluded: nav.hasAttribute("data-occluded"),
        scrollbar: scroller.offsetWidth - scroller.clientWidth - scroller.clientLeft,
        bars: bars.length,
      };
    });

  for (const width of [1600, 1200, 1000, 800])
    test(`in a ${width}px pane the left rail keeps the right rail's spacing`, async () => {
      const page = await pane!.open({ width, height: 760, colorScheme: "dark" });
      try {
        await closeSessionInfo(page);
        const sides: Record<string, Awaited<ReturnType<typeof spacing>>> = {};
        for (const side of ["left", "right"] as const) {
          await railSide(page, side);
          await page.locator(`.acpmux-minimap__rail[data-side="${side}"]:not(.acpmux-scrollmap)`).waitFor();
          await settle(page);
          sides[side] = await spacing(page);
          if (process.env.FAST_CHECKS_OUT) {
            const out = path.join(process.env.FAST_CHECKS_OUT, "rail-spacing");
            await mkdir(out, { recursive: true });
            await page.screenshot({ path: path.join(out, `${width}-${side}.png`) });
          }
        }
        console.log(`SESSION-RAIL-SPACING ${width} ${JSON.stringify(sides)}`);
        const { left, right } = sides as Record<"left" | "right", Awaited<ReturnType<typeof spacing>>>;
        expect(left.tickEdge).toBe(right.tickEdge);
        expect(left.railTop).toBe(right.railTop);
        expect(left.pitches).toEqual(right.pitches);
        expect(Math.abs(left.tickToText - right.tickToText)).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });

  const openSessionInfo = async (page: Page) => {
    const toggle = page.locator("button.acpmux-session-info-toggle");
    if ((await page.locator("aside.acpmux-session-info").count()) === 0) await toggle.click({ force: true });
    await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor({ timeout: 10_000 });
    await settle(page);
  };
  for (const width of [1600, 1400, 1200, 1100, 1000])
    for (const push of [false, true])
      test(`in a ${width}px pane with Session Info ${push ? "pushing" : "open"} the left rail keeps its spacing`, async () => {
        const page = await pane!.open({ width, height: 760, colorScheme: "dark" });
        try {
          await closeSessionInfo(page);
          const sides: Record<string, unknown> = {};
          for (const side of ["left", "right"] as const) {
            await railSide(page, side, push);
            await page.locator(`.acpmux-minimap__rail[data-side="${side}"]:not(.acpmux-scrollmap)`).waitFor();
            await openSessionInfo(page);
            sides[side] = {
              ...(await spacing(page)),
              placement: await page.locator("aside.acpmux-session-info").getAttribute("data-placement"),
            };
            if (process.env.FAST_CHECKS_OUT) {
              const out = path.join(process.env.FAST_CHECKS_OUT, "rail-spacing");
              await mkdir(out, { recursive: true });
              await page.screenshot({ path: path.join(out, `${width}-${push ? "push" : "open"}-${side}.png`) });
            }
            await closeSessionInfo(page);
          }
          console.log(`SESSION-RAIL-SPACING-INFO ${width} ${push ? "push" : "open"} ${JSON.stringify(sides)}`);
        } finally {
          await page.close();
        }
      });
});
