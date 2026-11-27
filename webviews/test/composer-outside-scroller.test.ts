// cmuxterm-hq docs/design/agent-transcript-clean-slate.md: "The composer is outside the scroller. Its
// growth shrinks the viewport. When pinned, the bottom edge holds. When not pinned, the top anchor
// holds." composerPlace.experiment.ts's `outside` arm puts the bottom stack under the transcript's
// scroller. This types a draft from one line to five and back, at a narrow and a wide pane, and on
// every animation frame reads the scroller's height, the last row's distance from the viewport's
// bottom edge and the reader's top row:
// - the viewport loses what the composer gains (the composer is outside the scroller);
// - pinned at the latest, the last row stays on the viewport's bottom edge on every frame;
// - scrolled up, the reader's row keeps its top on every frame.
// The `over` arm (today's default: the stack over the transcript's foot) runs the same script and
// prints its numbers, as the before.
//
// Real WebKit from Playwright (the app is WKWebView); COMPOSER_PLACE_ENGINE=chromium runs Chromium.
// CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

type Frame = {
  view: number;
  box: number;
  edge: number;
  fromEnd: number;
  reader: number | null;
};
type Run = { frames: Frame[]; scrollTop: number };

await requireBrowserLane("composer-outside-scroller.test.ts", async () => {
  const ENGINE_NAME = process.env.COMPOSER_PLACE_ENGINE === "chromium" ? "chromium" : "webkit";
  const ENGINE = ENGINE_NAME === "chromium" ? chromium : webkit;
  const ENTRY = "agent-pane.composer-outside-scroller";
  const FIELD = `${COMPOSER_MD_FIELD} .ProseMirror`;
  // Waits for `count` painted frames.
  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);
  // Waits until the scroller's offset held still for `still` painted frames in a row.
  const scrollSettled = (page: Page, still = 10) =>
    page.evaluate(async (need) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let last = scroller.scrollTop;
      for (let held = 0; held < need;) {
        await window.cmuxPaintFrame();
        held = scroller.scrollTop === last ? held + 1 : 0;
        last = scroller.scrollTop;
      }
    }, still);
  if (!(await probeEngineOrSkip("composer-outside-scroller", ENGINE_NAME, ENGINE))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await ENGINE.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "outside-bottom-one-line" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (place: "outside" | "over", width: number, scrolledUp: boolean) => {
    const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 1 });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: `${place}-bottom-one-line` })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    await page.waitForSelector(".acpmux-scroll .acpmux-row");
    const floats = await page.evaluate(() => document.querySelector(".acpmux-main")?.getAttribute("data-dock"));
    expect(floats ?? null).toBe(place === "over" ? "float" : "flow");
    await page.locator(FIELD).click();
    await page.keyboard.press("Control+End");
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      for (let i = 0; i < 10; i++) await window.cmuxPaintFrame();
      scroller.scrollTop = scroller.scrollHeight;
    });
    await scrollSettled(page);
    if (scrolledUp) {
      // A reader's own scroll (the wheel) unpins the chat; then their place is the row a third down.
      await page.mouse.move(width / 2, 200);
      await page.mouse.wheel(0, -500);
      await page.waitForFunction(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop > 100;
      });
      await scrollSettled(page);
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const mid = scroller.getBoundingClientRect().top + scroller.clientHeight / 3;
        const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find(
          (el) => el.getBoundingClientRect().bottom > mid,
        )!;
        row.dataset.reader = "1";
      });
    }
    await frames(page, 20);
    return page;
  };

  // Samples every painted frame while the draft grows from one line to five and shrinks back.
  const growAndShrink = async (page: Page): Promise<Run> => {
    const scrollTop = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
    await page.evaluate(() => {
      const own = window as unknown as { __frames: Frame[]; __stop: () => void };
      own.__frames = [];
      own.__stop = window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = scroller.getBoundingClientRect();
        const rows = scroller.querySelectorAll<HTMLElement>(".acpmux-row");
        const last = rows[rows.length - 1]!.getBoundingClientRect();
        const reader = document.querySelector<HTMLElement>("[data-reader]");
        const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!.getBoundingClientRect();
        const round = (value: number) => Math.round(value * 10) / 10;
        own.__frames.push({
          view: round(scroller.clientHeight),
          box: round(box.height),
          // The last row's bottom against the composer's top: the gap the eye reads.
          edge: round(box.top - last.bottom),
          fromEnd: round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
          reader: reader ? round(reader.getBoundingClientRect().top - view.top) : null,
        });
      });
    });
    await page.locator(FIELD).click();
    await page.keyboard.press("Control+End");
    for (let line = 2; line <= 5; line++) {
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type(`line ${line} of the draft`);
      await frames(page, 3);
    }
    await frames(page, 30);
    for (let line = 5; line >= 2; line--) {
      await page.keyboard.press("Shift+Home");
      await page.keyboard.press("Backspace");
      await page.keyboard.press("Backspace");
      await frames(page, 3);
    }
    const sampled = await page.evaluate(async () => {
      const own = window as unknown as { __frames: Frame[]; __stop: () => void };
      for (let i = 0; i < 40; i++) await window.cmuxPaintFrame();
      own.__stop();
      return own.__frames;
    });
    return { frames: sampled, scrollTop };
  };

  const drift = (values: number[]) => Math.max(...values.map((value) => Math.abs(value - values[0]!)));
  const span = (values: number[]) => Math.max(...values) - Math.min(...values);

  for (const width of [420, 900]) {
    test(`${width}px: outside the scroller, pinned, the viewport gives the composer its growth and the bottom edge holds`, async () => {
      const page = await open("outside", width, false);
      try {
        const { frames: run } = await growAndShrink(page);
        const grew = span(run.map((frame) => frame.box));
        const shrank = span(run.map((frame) => frame.view));
        const edge = drift(run.map((frame) => frame.edge));
        const fromEnd = Math.max(...run.map((frame) => frame.fromEnd));
        console.log(
          `COMPOSER-PLACE outside pinned ${ENGINE_NAME} ${width}px frames=${run.length} composerGrew=${grew} viewportShrank=${shrank} bottomEdgeDrift=${edge} maxFromEnd=${fromEnd}`,
        );
        expect(run.length).toBeGreaterThan(20);
        expect(grew).toBeGreaterThan(40);
        // Its growth shrinks the viewport, line for line.
        expect(Math.abs(shrank - grew)).toBeLessThanOrEqual(2);
        // When pinned, the bottom edge holds: on every frame, not only at rest.
        expect(edge).toBeLessThanOrEqual(1);
        expect(fromEnd).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });

    test(`${width}px: outside the scroller, scrolled up, the reader's top row holds as the composer grows`, async () => {
      const page = await open("outside", width, true);
      try {
        const { frames: run, scrollTop } = await growAndShrink(page);
        const grew = span(run.map((frame) => frame.box));
        const shrank = span(run.map((frame) => frame.view));
        const reader = drift(run.map((frame) => frame.reader!));
        const fromEnd = Math.min(...run.map((frame) => frame.fromEnd));
        console.log(
          `COMPOSER-PLACE outside scrolled-up ${ENGINE_NAME} ${width}px frames=${run.length} composerGrew=${grew} viewportShrank=${shrank} topAnchorDrift=${reader} scrollTop=${scrollTop} minFromEnd=${fromEnd}`,
        );
        expect(run.length).toBeGreaterThan(20);
        expect(grew).toBeGreaterThan(40);
        expect(Math.abs(shrank - grew)).toBeLessThanOrEqual(2);
        // Still scrolled up (the growth did not pin it), and the reader's row never moved.
        expect(fromEnd).toBeGreaterThan(100);
        expect(reader).toBeLessThanOrEqual(1);
      } finally {
        await page.close();
      }
    });
  }

  // The before: today's stack over the transcript's foot, the same script. Its viewport never
  // changes (the composer lies over it); printed for the comparison, and held to its own bottom edge.
  test("900px: over the foot (today's default), the same script, for the comparison", async () => {
    const page = await open("over", 900, false);
    try {
      const { frames: run } = await growAndShrink(page);
      const grew = span(run.map((frame) => frame.box));
      const shrank = span(run.map((frame) => frame.view));
      const edge = drift(run.map((frame) => frame.edge));
      console.log(
        `COMPOSER-PLACE over pinned ${ENGINE_NAME} 900px frames=${run.length} composerGrew=${grew} viewportShrank=${shrank} bottomEdgeDrift=${edge}`,
      );
      expect(grew).toBeGreaterThan(40);
      expect(shrank).toBeLessThanOrEqual(1);
    } finally {
      await page.close();
    }
  });
});
