// Leo, 2026-11-08, on a hat over the composer with one background command, expanded and folded again:
// "there's a bit of layout shift when I open up the thing. So this, the composer hat area, when I
// expand it and collapse it, sometimes it's like, okay, there's, like, some elements in between and
// then things don't balance out for whatever reason in between."
//
// Expanding and folding the hat is one state transition, sampled on every painted frame from the
// click (real Chromium, gallery `agent-pane.subagent-tray` / `lone-command-folded`, the transcript
// scrolled up so Jump to latest shows):
// - the dock's height moves one way only and ends exactly at the open height, then at the start one;
// - Jump to latest moves with the dock's top on every frame, and the transcript's rows, scrolled up,
//   stay where they were (the hat opens over the transcript's foot, cmux#30141);
// - nothing in the hat's header pops in or out: what comes or goes fades or narrows away, the time
//   keeps its place at the row's end, and the tuck chevron never shows while the hat folds;
// - folded again, every rect is where it started.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Box = { x: number; y: number; w: number; h: number };
type Frame = {
  at: number;
  clicked: boolean;
  dock: Box;
  jump: Box | null;
  row: number;
  /** The hat's elements outside its fold, by a stable key, with their box and drawn opacity. */
  parts: Record<string, Box & { opacity: number }>;
  tuck: number;
};

await requireBrowserLane("composer-hat-fold-balance.test.ts", async () => {
  const ENTRY = "agent-pane.subagent-tray";
  const VARIANT = "lone-command-folded";
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  /** The folded hat, the transcript scrolled up until Jump to latest shows, every motion settled. */
  async function open(): Promise<Page> {
    const port = (server.httpServer!.address() as { port: number }).port;
    const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.waitForSelector(".acpmux-running-tray__head[data-lone]");
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + 40);
    for (let turn = 0; turn < 4; turn++) await page.mouse.wheel(0, -240);
    await page.waitForSelector(".acpmux-jump-latest[data-shown]");
    await page.mouse.move(0, 0);
    await settle(page);
    return page;
  }

  /** Ends every finite animation and waits two frames. */
  const settle = (page: Page) =>
    page.evaluate(async () => {
      await new Promise((resolve) => setTimeout(resolve, 450));
      for (const animation of document.getAnimations())
        if (Number.isFinite(animation.effect?.getComputedTiming().endTime as number)) animation.finish();
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null))));
    });

  /** Starts sampling each painted frame (after paint: a task queued from its animation frame). */
  const startSampling = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: unknown[]; __sampling: boolean; __clicked: boolean };
      w.__frames = [];
      w.__sampling = true;
      w.__clicked = false;
      const tray = () => document.querySelector<HTMLElement>(".acpmux-dock > .acpmux-running-tray")!;
      tray().addEventListener("click", () => (w.__clicked = true), { capture: true });
      const box = (node: Element): { x: number; y: number; w: number; h: number } => {
        const rect = node.getBoundingClientRect();
        return { x: rect.x, y: rect.y, w: rect.width, h: rect.height };
      };
      const drawnOpacity = (node: Element, stop: Element): number => {
        let value = 1;
        for (let at: Element | null = node; at && at !== stop.parentElement; at = at.parentElement) {
          const style = getComputedStyle(at);
          if (style.visibility === "hidden" || style.display === "none") return 0;
          value *= Number(style.opacity);
        }
        return value;
      };
      // A stable key per element: its class (or tag) and its index among same-keyed siblings' path.
      const keyOf = (node: Element, stop: Element): string => {
        const parts: string[] = [];
        for (let at: Element | null = node; at && at !== stop; at = at.parentElement) {
          const name = (at.getAttribute("class") ?? at.tagName).split(/\s+/)[0] || at.tagName;
          parts.unshift(name);
        }
        return parts.join(">");
      };
      // The middle row of the view, to tell whether the transcript moved.
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const anchor = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => {
        const rect = row.getBoundingClientRect();
        return rect.top > view.top + 20 && rect.bottom < view.top + view.height / 2;
      });
      const sample = () => {
        const hat = tray();
        const fold = hat.querySelector(":scope > .acpmux-running-tray__fold");
        const parts: Record<string, { x: number; y: number; w: number; h: number; opacity: number }> = {};
        for (const node of hat.querySelectorAll("*")) {
          if (fold?.contains(node)) continue;
          // A ticking cell is one element: its leaving and entering words are its own motion.
          if (node.parentElement?.closest(".acpmux-tick")) continue;
          if (!(node instanceof HTMLElement) && node.tagName.toLowerCase() !== "svg") continue;
          const b = box(node);
          const opacity = drawnOpacity(node, hat);
          if (b.w < 0.5 || b.h < 0.5 || opacity < 0.01) continue;
          let key = keyOf(node, hat);
          while (parts[key]) key += "+";
          parts[key] = { ...b, opacity };
        }
        const tuck = hat.querySelector(".acpmux-running-tray__tuck");
        const jump = document.querySelector(".acpmux-jump-latest[data-shown]");
        w.__frames.push({
          at: performance.now(),
          clicked: w.__clicked,
          dock: box(document.querySelector(".acpmux-dock")!),
          jump: jump ? box(jump) : null,
          row: anchor ? anchor.getBoundingClientRect().top : Number.NaN,
          parts,
          tuck: tuck ? drawnOpacity(tuck, hat) : 0,
        });
      };
      const tick = () =>
        requestAnimationFrame(() => {
          const channel = new MessageChannel();
          channel.port1.onmessage = () => {
            if (!w.__sampling) return;
            sample();
            tick();
          };
          channel.port2.postMessage(0);
        });
      sample();
      tick();
    });

  const stopSampling = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: Frame[]; __sampling: boolean };
      w.__sampling = false;
      return w.__frames;
    });

  /** Clicks the header (a real pointer, `hover` first for that long, or a bare click) and returns the
   *  frames from the last one before the click through the motion's end. */
  async function toggle(page: Page, hover: number | undefined): Promise<Frame[]> {
    const chevron = page.locator(".acpmux-running-tray__chevron");
    if (hover !== undefined) {
      await chevron.hover();
      await page.waitForTimeout(hover);
    }
    await startSampling(page);
    if (hover !== undefined) await page.mouse.click(...(await center(page, ".acpmux-running-tray__chevron")));
    else await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-running-tray__head")!.click());
    await page.waitForTimeout(700);
    const frames = await stopSampling(page);
    const first = frames.findIndex((frame) => frame.clicked);
    expect(first).toBeGreaterThan(0);
    return frames.slice(first - 1);
  }

  const center = async (page: Page, selector: string): Promise<[number, number]> => {
    const b = (await page.locator(selector).boundingBox())!;
    return [b.x + b.width / 2, b.y + b.height / 2];
  };

  /** The dock's height moves one way only and lands exactly on `end`. */
  function oneWay(frames: Frame[], grows: boolean, end: number) {
    for (let index = 1; index < frames.length; index++) {
      const step = frames[index]!.dock.h - frames[index - 1]!.dock.h;
      if (grows) expect(step).toBeGreaterThanOrEqual(-0.5);
      else expect(step).toBeLessThanOrEqual(0.5);
    }
    expect(Math.abs(frames.at(-1)!.dock.h - end)).toBeLessThanOrEqual(0.5);
  }

  /** Jump to latest rides the dock's top, and the transcript's rows stay put, on every frame. */
  function together(frames: Frame[]) {
    const start = frames[0]!;
    for (const frame of frames) {
      expect(frame.jump).not.toBeNull();
      const dockMoved = frame.dock.y - start.dock.y;
      expect(Math.abs(frame.jump!.y - start.jump!.y - dockMoved)).toBeLessThanOrEqual(1);
      expect(Math.abs(frame.row - start.row)).toBeLessThanOrEqual(0.5);
    }
  }

  /** What comes or goes in the hat's header does so through motion: an element first drawn, or last
   *  drawn, is faint or narrow then, never a pop at full size. Returns the offenders. */
  function pops(frames: Frame[]): string[] {
    const found = new Set<string>();
    for (let index = 1; index < frames.length; index++) {
      const before = frames[index - 1]!.parts;
      const now = frames[index]!.parts;
      const faint = (part: Box & { opacity: number }) => part.opacity <= 0.35 || part.w <= 4;
      for (const [key, part] of Object.entries(now)) if (!before[key] && !faint(part)) found.add(`in: ${key}`);
      for (const [key, part] of Object.entries(before)) if (!now[key] && !faint(part)) found.add(`out: ${key}`);
    }
    return [...found];
  }

  /** The header's time keeps its place: no frame draws it anywhere but where it started. */
  function timeStill(frames: Frame[]) {
    const key = (frame: Frame) => Object.keys(frame.parts).find((name) => name.endsWith("acpmux-running-tray__time"));
    const start = frames[0]!.parts[key(frames[0]!)!]!;
    for (const frame of frames) {
      const name = key(frame);
      expect(name).toBeDefined();
      const time = frame.parts[name!]!;
      expect(Math.abs(time.x + time.w - (start.x + start.w))).toBeLessThanOrEqual(1);
    }
  }

  test("a bare click: one transition each way, and folded again every rect is where it started", async () => {
    const page = await open();
    try {
      const opened = await toggle(page, undefined);
      expect(await page.locator(".acpmux-running-tray__head").getAttribute("aria-expanded")).toBe("true");
      const start = opened[0]!;
      const openHeight = await page.evaluate(
        () => document.querySelector(".acpmux-dock")!.getBoundingClientRect().height,
      );
      expect(openHeight - start.dock.h).toBeGreaterThan(20);
      oneWay(opened, true, openHeight);
      together(opened);
      expect(pops(opened)).toEqual([]);
      timeStill(opened);
      for (const frame of opened) expect(frame.tuck).toBe(0);

      await settle(page);
      const folded = await toggle(page, undefined);
      expect(await page.locator(".acpmux-running-tray__head").getAttribute("aria-expanded")).toBe("false");
      oneWay(folded, false, start.dock.h);
      together(folded);
      expect(pops(folded)).toEqual([]);
      timeStill(folded);
      for (const frame of folded) expect(frame.tuck).toBe(0);

      // Folded again, the layout is the one it started from.
      const end = folded.at(-1)!;
      for (const key of ["x", "y", "w", "h"] as const) {
        expect(Math.abs(end.dock[key] - start.dock[key])).toBeLessThanOrEqual(0.5);
        expect(Math.abs(end.jump![key] - start.jump![key])).toBeLessThanOrEqual(0.5);
      }
      expect(Object.keys(end.parts).sort()).toEqual(Object.keys(start.parts).sort());
      for (const [name, part] of Object.entries(start.parts))
        for (const key of ["x", "y", "w", "h"] as const)
          expect({ name, key, delta: Math.abs(end.parts[name]![key] - part[key]) <= 0.5 }).toEqual({
            name,
            key,
            delta: true,
          });
    } finally {
      await page.close();
    }
  });

  test("Leo's pointer on the chevron: the tuck chevron fades away and never comes back mid-way", async () => {
    const page = await open();
    try {
      // The pointer dwells on the hat first, as Leo's did, so its hover reveal has run.
      const opened = await toggle(page, 600);
      for (let index = 1; index < opened.length; index++)
        expect(opened[index]!.tuck).toBeLessThanOrEqual(opened[index - 1]!.tuck + 0.01);
      expect(opened.at(-1)!.tuck).toBe(0);
      oneWay(opened, true, opened.at(-1)!.dock.h);
      together(opened);
      expect(pops(opened.slice(1))).toEqual([]);

      await settle(page);
      const folded = await toggle(page, 0);
      for (const frame of folded.slice(1)) expect(frame.tuck).toBe(0);
      oneWay(folded, false, opened[0]!.dock.h);
      together(folded);
      expect(pops(folded.slice(1))).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
