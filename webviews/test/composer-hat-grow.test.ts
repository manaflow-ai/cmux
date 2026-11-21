// cmux-web-test-timeout: 300
// The tucked composer hat (subagents/TrayPullTab.tsx) is just the chevron, centred on the composer,
// while nothing runs, and grows into chevron and count when work runs (Leo, 2026-11-07: "if there's
// no running work, it should just be centered, right? But when there is a number, it can, like, you
// know, grow into that."). It renders the gallery stage `agent-pane.composer-hat` in Chromium and
// samples every frame of idle → count → idle: the hat's centre stays on the composer's centre in
// both states and through the transition, the chevron never jumps, the count is there from the first
// frame (no pop-in after the motion), a count tick keeps the width, idle keeps no count element and
// no room for one, and with motion off the change lands in one frame.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-hat-grow.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-hat-grow.test.ts", async () => {
  const ENTRY = "agent-pane.composer-hat";
  /** One frame's geometry, in page px. `hat` is the drawn control's centre and width (its glass pill
   *  when it has one, else the union of the chevron and the visible count). */
  type Frame = {
    composer: number;
    chevron: number;
    hat: number;
    hatWidth: number;
    count: boolean;
    countOpacity: number;
  };
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("composer hat grow", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 640, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 640, height: 260 } });
    for (;;) {
      await page.goto(stageURL(variant));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.evaluate(() => document.fonts.ready);
    await page.mouse.move(1, 1);
    await page.waitForSelector(".acpmux-tray-pull svg");
    // The measuring function, installed once per page.
    await page.evaluate(() => {
      const w = window as unknown as { hatFrame: () => unknown };
      w.hatFrame = () => {
        const center = (rect: DOMRect) => rect.left + rect.width / 2;
        const composer = document.querySelector("[data-stage-composer]")!.getBoundingClientRect();
        const chevron = document.querySelector(".acpmux-tray-pull svg")!.getBoundingClientRect();
        const countEl = document.querySelector<HTMLElement>(".acpmux-tray-pull__count");
        const pill = document.querySelector(".acpmux-tray-pull__hat")?.getBoundingClientRect();
        let left = chevron.left;
        let right = chevron.right;
        let countOpacity = 0;
        if (countEl) {
          const rect = countEl.getBoundingClientRect();
          // The count as drawn: cut by any clipping box between it and the tab.
          let visibleRight = rect.right;
          let visibleLeft = rect.left;
          for (
            let node = countEl.parentElement;
            node && !node.matches(".acpmux-tray-pull");
            node = node.parentElement
          ) {
            if (getComputedStyle(node).overflow !== "visible") {
              const clip = node.getBoundingClientRect();
              visibleRight = Math.min(visibleRight, clip.right);
              visibleLeft = Math.max(visibleLeft, clip.left);
            }
          }
          if (visibleRight > visibleLeft) {
            left = Math.min(left, visibleLeft);
            right = Math.max(right, visibleRight);
          }
          countOpacity = 1;
          for (
            let node: HTMLElement | null = countEl;
            node && !node.matches(".acpmux-tray-pull");
            node = node.parentElement
          )
            countOpacity *= Number(getComputedStyle(node).opacity);
        }
        return {
          composer: center(composer),
          chevron: center(chevron),
          hat: pill ? center(pill) : (left + right) / 2,
          hatWidth: pill ? pill.width : right - left,
          count: !!countEl,
          countOpacity,
        };
      };
    });
    await eased(page);
    return page;
  };
  const frame = (page: Page) => page.evaluate(() => (window as unknown as { hatFrame: () => Frame }).hatFrame());
  /** Presses a stage button and records every frame for `ms`. */
  const play = (page: Page, button: string, ms = 450) =>
    page.evaluate(
      ([button, ms]) =>
        new Promise<Frame[]>((resolve) => {
          const measure = (window as unknown as { hatFrame: () => Frame }).hatFrame;
          const frames: Frame[] = [];
          document.querySelector<HTMLElement>(`[data-stage="${button}"]`)!.click();
          const start = performance.now();
          const tick = () => {
            frames.push(measure());
            // raf-read: each sample is the geometry that frame lays out; before or after its paint is the same.
            if (performance.now() - start < ms) requestAnimationFrame(tick);
            else resolve(frames);
          };
          requestAnimationFrame(tick);
        }),
      [button, ms] as const,
    );

  const centred = (frames: Frame[], label: string) => {
    for (const [index, f] of frames.entries())
      expect(Math.abs(f.hat - f.composer), `${label}: frame ${index}: the hat's centre on the composer's`).toBeLessThan(
        0.75,
      );
  };
  const noJump = (frames: Frame[], label: string) => {
    for (let index = 1; index < frames.length; index += 1) {
      const step = Math.abs(frames[index]!.chevron - frames[index - 1]!.chevron);
      expect(step, `${label}: frame ${index}: the chevron moves by ${step}px in one frame`).toBeLessThan(3);
    }
  };

  test("idle: the hat is just the chevron, centred on the composer, with no count and no room for one", async () => {
    const page = await open("idle");
    const idle = await frame(page);
    await page.close();
    expect(idle.count, "no count element").toBe(false);
    expect(Math.abs(idle.chevron - idle.composer), "the chevron is on the composer's centre").toBeLessThan(0.75);
    expect(Math.abs(idle.hat - idle.composer), "the hat is on the composer's centre").toBeLessThan(0.75);
  });

  test("count: chevron and count stay centred on the composer", async () => {
    const page = await open("count");
    const shown = await frame(page);
    await page.close();
    expect(shown.count, "the count shows").toBe(true);
    expect(Math.abs(shown.hat - shown.composer), "the hat is on the composer's centre").toBeLessThan(0.75);
    expect(shown.countOpacity, "the count is fully drawn").toBe(1);
  });

  for (const variant of ["count", "two-digits"])
    test(`${variant}: the count is whole, never cut by the hat`, async () => {
      const page = await open(variant);
      const cut = await page.evaluate(() => {
        const count = document.querySelector(".acpmux-tray-pull__count")!.getBoundingClientRect();
        const hat = document.querySelector(".acpmux-tray-pull__hat")?.getBoundingClientRect();
        let left = count.left;
        let right = count.right;
        for (
          let node = document.querySelector(".acpmux-tray-pull__count")!.parentElement;
          node && !node.matches(".acpmux-tray-pull");
          node = node.parentElement
        )
          if (getComputedStyle(node).overflow !== "visible") {
            const clip = node.getBoundingClientRect();
            left = Math.max(left, clip.left);
            right = Math.min(right, clip.right);
          }
        return { cut: count.width - (right - left), inside: hat ? count.right <= hat.right : true };
      });
      await page.close();
      expect(cut.cut, "no part of the count is clipped").toBeLessThan(0.5);
      expect(cut.inside, "the count sits inside the hat").toBe(true);
    });

  test("idle → count → idle is one transition: centred every frame, no jump, no pop-in, no room left", async () => {
    const page = await open("idle");
    const rest = await frame(page);
    const grow = await play(page, "count");
    await eased(page);
    const grown = await frame(page);
    const tick = await play(page, "more");
    await eased(page);
    const shrink = await play(page, "idle");
    await eased(page);
    const back = await frame(page);
    await page.close();

    centred(grow, "grow");
    centred(tick, "tick");
    centred(shrink, "shrink");
    noJump(grow, "grow");
    noJump(shrink, "shrink");
    // The count is in the first frame after the press, and the motion ends drawn, not popped in later.
    expect(grow[0]!.count, "the count is there from the first frame").toBe(true);
    expect(grow.at(-1)!.countOpacity, "the count is drawn when the motion ends").toBe(1);
    expect(grown.hatWidth, "the hat grows into the count").toBeGreaterThan(rest.hatWidth + 4);
    // It grows over frames, not in one step: some frames draw a width between the two ends.
    const between = (frames: Frame[], a: number, b: number) =>
      frames.filter((f) => f.hatWidth > Math.min(a, b) + 0.5 && f.hatWidth < Math.max(a, b) - 0.5).length;
    expect(between(grow, rest.hatWidth, grown.hatWidth), "frames between idle and counted widths").toBeGreaterThan(2);
    expect(between(shrink, rest.hatWidth, grown.hatWidth), "frames between counted and idle widths").toBeGreaterThan(2);
    // The chevron moves aside for the count, so the pair is centred.
    expect(grown.chevron, "the chevron makes room for the count").toBeLessThan(grown.composer - 2);
    // 3 → 4: tabular numerals, the width holds every frame.
    for (const [index, f] of tick.entries())
      expect(Math.abs(f.hatWidth - grown.hatWidth), `tick: frame ${index}: the width holds`).toBeLessThan(0.5);
    // Back to idle: the count is gone, and so is its room.
    expect(back.count, "idle again: no count element").toBe(false);
    expect(Math.abs(back.hatWidth - rest.hatWidth), "idle again: the hat's idle width").toBeLessThan(0.5);
    expect(Math.abs(back.chevron - back.composer), "idle again: the chevron on the centre").toBeLessThan(0.75);
  });

  test("motion off: the hat takes its count state in one frame", async () => {
    const page = await open("idle");
    await page.evaluate(() => document.documentElement.setAttribute("data-cmux-motion", "off"));
    const grow = await play(page, "count", 120);
    await eased(page);
    const grown = await frame(page);
    const shrink = await play(page, "idle", 120);
    await page.close();
    expect(Math.abs(grow[0]!.hatWidth - grown.hatWidth), "the first frame is the end state").toBeLessThan(0.5);
    expect(grow[0]!.countOpacity, "the count is drawn in the first frame").toBe(1);
    expect(shrink[0]!.count, "idle in the first frame: no count element").toBe(false);
  });
});
