// Leo 2026-11-22: "this still goes to the top instead of staying at the bottom when composer grows."
// In the agent pane a long chat sits at its bottom with the last message right above the composer.
// Typing a draft from one line to five (and deleting back) must leave that message where it is
// on every frame, with no jump to the top; a reader scrolled up keeps their place. Sampled on every
// animation frame (rAF) while the draft grows, at a narrow and a wide pane.
//
// Real WebKit from Playwright (the app is WKWebView); ANCHOR_ENGINE=chromium runs Chromium instead.
// CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

type Frame = { box: number; t: number; scrollTop: number; fromEnd: number; gap: number };

await requireBrowserLane("transcript-composer-grow-anchor.test.ts", async () => {
  const ENGINE_NAME = process.env.ANCHOR_ENGINE === "chromium" ? "chromium" : "webkit";
  // Where a frame is read: "late" after the frame's ResizeObservers (what paints), "raf" in rAF (before them).
  const SAMPLE_LATE = process.env.ANCHOR_SAMPLE !== "raf";
  const ENGINE = ENGINE_NAME === "chromium" ? chromium : webkit;
  if (!(await probeEngineOrSkip("transcript-composer-grow-anchor", ENGINE_NAME, ENGINE))) return;
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.transcript-composer-grow";
  const shots = process.env.ANCHOR_SHOTS;
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "bottom-one-line" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (width: number, scrolledUp: boolean, variant = "bottom-one-line") => {
    const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 1 });
    const port = (vite.httpServer!.address() as { port: number }).port;
    if (process.env.ANCHOR_EXP)
      await page.addInitScript((value) => localStorage.setItem("cmux.experiments", value), process.env.ANCHOR_EXP);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.evaluate(() => document.fonts.ready);
    await page.waitForSelector(".acpmux-scroll .acpmux-row");
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).click();
    await page.keyboard.press("Control+End");
    await page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
      // raf-read: setup only, pinning the view to its end again after the rows settled; nothing is measured here.
      for (let i = 0; i < 10; i++) await new Promise((r) => requestAnimationFrame(r));
      scroller.scrollTop = scroller.scrollHeight;
    });
    if (scrolledUp)
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop = Math.max(0, scroller.scrollTop - 500);
      });
    await page.evaluate(async () => {
      for (let i = 0; i < 20; i++) await new Promise((r) => requestAnimationFrame(r));
    });
    return page;
  };

  const startSampling = (page: Page) =>
    page.evaluate((late) => {
      const frames: Frame[] = [];
      const own = window as unknown as { __frames: Frame[]; __stop: boolean };
      own.__frames = frames;
      own.__stop = false;
      const t0 = performance.now();
      const tick = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows = scroller.querySelectorAll<HTMLElement>(".acpmux-row");
        const last = rows[rows.length - 1]!;
        const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
        frames.push({
          box: Math.round(box.getBoundingClientRect().height * 10) / 10,
          t: Math.round(performance.now() - t0),
          scrollTop: Math.round(scroller.scrollTop * 10) / 10,
          fromEnd: Math.round((scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop) * 10) / 10,
          gap: Math.round((box.getBoundingClientRect().top - last.getBoundingClientRect().bottom) * 10) / 10,
        });
        // raf-read: ANCHOR_SAMPLE=raf only, the pre-observer read kept to compare against the late one.
        if (!own.__stop && !late) requestAnimationFrame(tick);
      };
      if (late) {
        // Read after the frame's ResizeObservers (the field's growth starts in one since #48134), as
        // near the paint as script gets: a sentinel resized in each rAF reports to an observer made
        // after the app's, so it is told last, after their microtasks (the transcript's room).
        const sentinel = document.body.appendChild(document.createElement("div"));
        sentinel.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none";
        const observer = new ResizeObserver(() => {
          if (own.__stop) return observer.disconnect();
          tick();
        });
        observer.observe(sentinel);
        const flip = () => {
          sentinel.style.width = sentinel.style.width === "1px" ? "2px" : "1px";
          // raf-read: flip only resizes the sentinel; the read is in its observer, after the app's.
          if (!own.__stop) requestAnimationFrame(flip);
        };
        requestAnimationFrame(flip);
        return;
      }
      requestAnimationFrame(tick);
    }, SAMPLE_LATE);
  const stopSampling = (page: Page) =>
    page.evaluate(async () => {
      const own = window as unknown as { __frames: Frame[]; __stop: boolean };
      for (let i = 0; i < 40; i++) await new Promise((r) => requestAnimationFrame(r));
      own.__stop = true;
      await new Promise((r) => requestAnimationFrame(r));
      return own.__frames;
    });
  const shot = async (page: Page, name: string) => {
    if (!shots) return;
    mkdirSync(shots, { recursive: true });
    await page.screenshot({ path: path.join(shots, `${name}.png`) });
  };

  const grow = async (page: Page) => {
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).click();
    await page.keyboard.press("Control+End");
    for (let line = 2; line <= 5; line++) {
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.type(`line ${line} of the draft`);
      await page.evaluate(async () => {
        for (let i = 0; i < 3; i++) await new Promise((r) => requestAnimationFrame(r));
      });
    }
  };
  const shrink = async (page: Page) => {
    for (let line = 5; line >= 2; line--) {
      await page.keyboard.press("Shift+Home");
      await page.keyboard.press("Backspace");
      await page.keyboard.press("Backspace");
      await page.evaluate(async () => {
        for (let i = 0; i < 3; i++) await new Promise((r) => requestAnimationFrame(r));
      });
    }
  };

  for (const width of [420, 900])
    test(`${width}px: at the bottom, growing the composer 1 to 5 lines and back keeps the last message on it`, async () => {
      const page = await open(width, false);
      try {
        const base = await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          return { scrollTop: scroller.scrollTop, max: scroller.scrollHeight - scroller.clientHeight };
        });
        expect(base.scrollTop).toBeGreaterThan(500);
        await shot(page, `after-${width}-bottom-1line`);
        await startSampling(page);
        await grow(page);
        await shot(page, `after-${width}-bottom-5line`);
        await shrink(page);
        const frames = await stopSampling(page);
        const first = frames[0]!;
        const gaps = frames.map((frame) => Math.abs(frame.gap - first.gap));
        const worst = Math.max(...gaps);
        const lowest = Math.min(...frames.map((frame) => frame.scrollTop));
        console.log(
          `ANCHOR ${width} frames=${frames.length} startGap=${first.gap} worstGapDrift=${worst} minScrollTop=${lowest} maxFromEnd=${Math.max(...frames.map((f) => f.fromEnd))}`,
        );
        if (shots) writeFileSync(path.join(shots, `frames-${width}-bottom.json`), JSON.stringify(frames));
        expect(frames.length).toBeGreaterThan(20);
        // The last message keeps its place against the composer's top on every frame.
        expect(worst).toBeLessThanOrEqual(1);
        // And the view never goes toward the top.
        expect(lowest).toBeGreaterThan(base.scrollTop * 0.9);
      } finally {
        await page.close();
      }
    });

  for (const width of [420, 900])
    test(`${width}px: scrolled up, the composer growing and shrinking leaves the reader's place`, async () => {
      const page = await open(width, true);
      try {
        // The row at the middle of the view is the reader's place: its top must not move.
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const mid = scroller.getBoundingClientRect().top + scroller.clientHeight / 3;
          const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find(
            (el) => el.getBoundingClientRect().bottom > mid,
          )!;
          row.dataset.reader = "1";
        });
        const topOf = (frame: Page) =>
          frame.evaluate(() => document.querySelector<HTMLElement>("[data-reader]")!.getBoundingClientRect().top);
        const before = await topOf(page);
        const scrollBefore = await page.evaluate(
          () => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
        );
        await startSampling(page);
        await grow(page);
        await shot(page, `after-${width}-scrolledup-5line`);
        await shrink(page);
        const frames = await stopSampling(page);
        const after = await topOf(page);
        const lowest = Math.min(...frames.map((frame) => frame.scrollTop));
        const highest = Math.max(...frames.map((frame) => frame.scrollTop));
        console.log(
          `ANCHOR-UP ${width} before=${before} after=${after} scrollTop ${scrollBefore} min=${lowest} max=${highest}`,
        );
        expect(Math.abs(after - before)).toBeLessThanOrEqual(1);
        expect(lowest).toBeGreaterThan(scrollBefore - 2);
        expect(highest).toBeLessThan(scrollBefore + 2);
      } finally {
        await page.close();
      }
    });
});
