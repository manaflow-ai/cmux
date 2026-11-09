// l10n-allow-file: test fixture prompts, not shipped UI.
// The prompt rail ends above the bottom stack, and its preview card centers on the tick it previews
// (Leo, 2026-11-03: "this left scroll rail prob goes a little bit too far down now and also the hover
// previews are offset strangely"). The rail's box latched the bottom stack at its smallest (the
// composer at rest, VirtualTranscript `railBox`), so a composer that grew left the rail's foot under
// it; since the rail is full length from the prompt count (#32894) the rail reaches that foot. The card
// kept itself above a different foot: the view less the room under the last row, which is the stack
// plus the 56 px rest gap, counted from the rail's origin, which a one-tab pane moves down by its tab
// row. So the last ticks' card sat far above them. Both now read one foot, the stack's top as it is.
//
// Real Chromium on the whole pane (the gallery's agent-pane.thread-minimap-foot), composer included: a
// long chat at its end, in a pane with a tab row band and in a one-tab pane, at rest and after eight
// composer lines are typed. The pointer is moved onto each tick as a person moves it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("thread-rail-foot-card.test.ts", async () => {
  const ENTRY = "agent-pane.thread-minimap-foot";
  const WIDTH = 1040;
  const HEIGHT = 720;
  /// The card's margin from the view's edges (model.ts EDGE_MARGIN).
  const MARGIN = 8;
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true, timeout: 30_000 });
  } catch {
    console.warn("thread-rail-foot-card: chromium cannot launch here; skipping");
    describe.skip("thread rail foot and card", () => test("browser", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.FAST_CHECKS_OUT;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, ENTRY, { params: { variant: "resting" } });
    if (out) await mkdir(out, { recursive: true });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: HEIGHT }, reducedMotion: "reduce" });
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, colorScheme: "dark", width: WIDTH, height: HEIGHT })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    await page.waitForSelector(".acpmux-minimap__list [data-tick]");
    await settle(page);
    return page;
  };
  const settle = (page: Page) =>
    page.evaluate(async () => {
      await document.fonts.ready;
      for (let frame = 0; frame < 4; frame++) await new Promise((done) => requestAnimationFrame(done));
    });

  /// The rail's box, the bottom stack's top, and the rail's drawn ticks, in the page's coordinates.
  const measure = (page: Page) =>
    page.evaluate(() => {
      const rail = document.querySelector(".acpmux-minimap__rail")!.getBoundingClientRect();
      const dock = document.querySelector(".acpmux-dock")!.getBoundingClientRect();
      const list = document.querySelector(".acpmux-minimap__list")!.getBoundingClientRect();
      const origin = document.querySelector(".acpmux-minimap")!.getBoundingClientRect().top;
      // Ticks drawn inside the list's box (a scrolled list clips the rest).
      const ticks = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__list [data-tick]")]
        .map((tick) => ({ index: Number(tick.dataset.tick), box: tick.getBoundingClientRect() }))
        .filter(({ box }) => box.top >= list.top - 0.5 && box.bottom <= list.bottom + 0.5)
        .map(({ index, box }) => ({ index, center: box.top + box.height / 2, x: box.left + 6 }));
      return { rail: { top: rail.top, bottom: rail.bottom }, dockTop: dock.top, origin, ticks };
    });

  /// Hovers tick `index` and reads where its card centers, and where it should: on the tick, kept
  /// inside the view between the rail's origin and the stack's top.
  const hoverCard = async (page: Page, index: number) => {
    const { ticks, dockTop, origin } = await measure(page);
    const tick = ticks.find((entry) => entry.index === index)!;
    await page.mouse.move(WIDTH / 2, HEIGHT / 3);
    await page.mouse.move(tick.x, tick.center, { steps: 4 });
    await page.waitForSelector(".acpmux-minimap__card");
    await settle(page);
    const card = await page.evaluate(() => {
      const box = document.querySelector(".acpmux-minimap__card")!.getBoundingClientRect();
      return { top: box.top, bottom: box.bottom, height: box.height };
    });
    const center = (card.top + card.bottom) / 2;
    const expected = Math.max(
      origin + MARGIN + card.height / 2,
      Math.min(tick.center, dockTop - MARGIN - card.height / 2),
    );
    return { tick: tick.center, center, expected, card, dockTop };
  };

  /// Types eight composer lines: the stack grows over the view after the rail drew at rest.
  const growDraft = async (page: Page) => {
    await page.locator(".acpmux-composer-prompt [contenteditable]").click();
    for (let line = 1; line <= 8; line++) {
      await page.keyboard.type(`Line ${line} of a long draft`);
      if (line < 8) await page.keyboard.press("Shift+Enter");
    }
    await settle(page);
  };

  test("the shift gallery's four-line composer: the rail keeps its top, inset and full length while the stack leaves it room", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "reduce" });
    try {
      const frame = (variant: string) =>
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.thread-minimap-shift", { variant, colorScheme: "dark", width: 900, height: 640 })}`;
      const read = async (variant: string) => {
        await page.goto(frame(variant));
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
        await settle(page);
        return page.evaluate(() => {
          const rail = document.querySelector("nav.acpmux-minimap__rail")!.getBoundingClientRect();
          return {
            rail: { x: rail.x, top: rail.top, height: rail.height },
            dockTop: document.querySelector(".acpmux-dock")!.getBoundingClientRect().top,
          };
        });
      };
      const open = await read("open-chat");
      const grown = await read("composer-grows");
      if (out) await page.screenshot({ path: path.join(out, "rail-foot-shift-composer-grows.png") });
      expect(grown.dockTop).toBeLessThan(open.dockTop);
      expect(grown.rail).toEqual(open.rail);
      expect({ x: grown.rail.x, top: grown.rail.top }).toEqual({ x: open.rail.x, top: open.rail.top });
    } finally {
      await page.close();
    }
  });

  for (const [name, variant] of [
    ["a pane with a tab row band", "resting"],
    ["a one-tab pane", "solo-tab-hovered"],
  ] as const) {
    test(`${name}: the rail ends above the stack and each card centers on its tick, at rest and over a tall draft`, async () => {
      const page = await open(variant);
      try {
        const rest = await measure(page);
        if (out) await page.screenshot({ path: path.join(out, `rail-foot-${variant}-rest.png`) });
        // The fixed rail keeps its rest box; a growing stack may lay over its foot.
        expect(rest.rail.bottom - rest.rail.top).toBeGreaterThanOrEqual(480 - 1);
        const drawn = rest.ticks.map((tick) => tick.index);
        expect(drawn.length).toBeGreaterThan(8);
        const last = Math.max(...drawn);
        const middle = drawn[Math.floor(drawn.length / 2)]!;
        for (const index of [last, last - 2, middle]) {
          const seen = await hoverCard(page, index);
          if (out && index === last)
            await page.screenshot({ path: path.join(out, `rail-foot-${variant}-card-last.png`) });
          expect({ index, off: Math.round(seen.center - seen.expected) }).toEqual({ index, off: 0 });
        }
        await page.mouse.move(WIDTH / 2, HEIGHT / 3);

        await growDraft(page);
        const tall = await measure(page);
        if (out) await page.screenshot({ path: path.join(out, `rail-foot-${variant}-draft.png`) });
        // The draft grew the stack over the view.
        expect(tall.dockTop).toBeLessThan(rest.dockTop - 60);
        // The rail keeps its full rest box while the grown stack lays over its foot.
        expect(tall.rail).toEqual(rest.rail);
        const lastTall = Math.max(...tall.ticks.map((tick) => tick.index));
        const seen = await hoverCard(page, lastTall);
        if (out) await page.screenshot({ path: path.join(out, `rail-foot-${variant}-draft-card.png`) });
        expect(Math.round(seen.center - seen.expected)).toBe(0);
      } finally {
        await page.close();
      }
    });
  }
});
