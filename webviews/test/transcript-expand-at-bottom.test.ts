// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// Opening a line with the transcript at its very bottom grows down, as Codex opens a call at the end
// of a chat (Lucas, 2026-11-06, Codex parity; it replaces the bottom pin on open, Leo 2026-11-02): the
// line and the text above it stay on their pixels, what opens goes under the composer, and the view
// stops following. Anywhere else the line stays put and its body grows down too (#28780). Closing at
// the very bottom still pins it: the text above comes down and no blank room is left (Leo, 2026-11-03).
//
// Real Chromium from Playwright on the agent pane's gallery scene (ExpandAtBottom.gallery.ts).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { installPaintedFrames } from "./support/paintedFrames";
import { pinArms } from "./support/pinArms";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-expand-at-bottom.test.ts", async () => {
  const ENTRY = "agent-pane.expand-at-bottom";
  const VARIANT = "shipped";
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("transcript-expand-at-bottom: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true, ...launchOptions });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "prompt" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The last turn's "Ran 2 commands" line.
  const GROUP = '[data-row-id="expand-at-bottom-run"] button.cv-tool.is-toggle[aria-expanded]';
  /// Every finite animation over, then the scroller's offset and height the same over 16 painted frames.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      for (let tries = 0; tries < 20; tries++) {
        const running = document
          .getAnimations()
          .filter((each) => each.effect?.getComputedTiming().endTime !== Infinity && each.playState === "running");
        if (running.length === 0) break;
        await Promise.all(running.map((each) => each.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
      }
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      let last = "";
      let still = 0;
      for (let frames = 0; frames < 240 && still < 16; frames++) {
        await window.cmuxPaintFrame();
        const now = `${scroller?.scrollTop}:${scroller?.scrollHeight}`;
        still = now === last ? still + 1 : 0;
        last = now;
      }
    });
  /// Where things are drawn: the group's line, the last row's foot, and the scroller.
  const measure = (page: Page) =>
    page.evaluate((query) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      return {
        line: document.querySelector<HTMLElement>(query)!.getBoundingClientRect().top,
        lastFoot: rows.at(-1)!.getBoundingClientRect().bottom,
        scrollTop: scroller.scrollTop,
        scrollHeight: scroller.scrollHeight,
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        open: document.querySelector<HTMLElement>(query)!.getAttribute("aria-expanded"),
      };
    }, GROUP);

  /// Clicks the middle of `query`'s line with the mouse (a locator's click scrolls a line the
  /// composer covers into view first), after checking the point is the line's own.
  const clickLine = async (page: Page, query: string) => {
    const point = await page.evaluate((selector) => {
      const line = document.querySelector<HTMLElement>(selector)!;
      const box = line.getBoundingClientRect();
      const x = box.left + Math.min(40, box.width / 2);
      const y = box.top + box.height / 2;
      return { x, y, own: line.contains(document.elementFromPoint(x, y)) };
    }, query);
    expect(point.own).toBe(true);
    await page.mouse.click(point.x, point.y);
  };

  async function open(
    variant = VARIANT,
    ready = GROUP,
    engine: Browser = browser!,
    arms: Readonly<Record<string, string>> = {},
  ): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await engine.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => localStorage.clear());
    await pinArms(page, arms);
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
    await page.locator(ready).waitFor();
    await settled(page);
    return page;
  }

  test("at the very bottom, opening a line keeps it on its pixel and grows its body down", async () => {
    const page = await open();
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    const before = await measure(page);
    expect(before.open).toBe("false");
    expect(before.fromEnd).toBeLessThanOrEqual(2);
    await clickLine(page, GROUP);
    await settled(page);
    const after = await measure(page);
    expect(after.open).toBe("true");
    // The line and the view stayed; what opened grew the chat down, past the view's end.
    expect(Math.abs(after.line - before.line)).toBeLessThanOrEqual(1);
    expect(Math.abs(after.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(after.fromEnd).toBeGreaterThan(40);
    await page.close();
  });

  // A long prompt's Show more at the very bottom opens as an open does anywhere in the chat (Codex
  // parity): the prompt's row and the view stay where they were, the text it shows grows down and
  // the reply under it moves down under the composer.
  test("at the very bottom, a long prompt's Show more opens it downward", async () => {
    const MORE = '.cv-user__more[aria-expanded="false"]';
    const page = await open("prompt", MORE);
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.scrollTop = node.scrollHeight;
    });
    await settled(page);
    const where = () =>
      page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const bubbles = [...scroller.querySelectorAll<HTMLElement>(".cv-user__text")];
        return {
          prompt: bubbles.at(-1)!.closest(".acpmux-row")!.getBoundingClientRect().top,
          lastFoot: rows.at(-1)!.getBoundingClientRect().bottom,
          scrollHeight: scroller.scrollHeight,
          fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        };
      });
    const before = await where();
    expect(before.fromEnd).toBeLessThanOrEqual(2);
    await clickLine(page, MORE);
    await page.locator('.cv-user__more[aria-expanded="true"]').waitFor();
    await settled(page);
    const after = await where();
    console.log(`prompt Show more: ${JSON.stringify(before)} -> ${JSON.stringify(after)}`);
    expect(Math.abs(after.prompt - before.prompt)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 40);
    expect(after.lastFoot - before.lastFoot).toBeGreaterThan(40);
    expect(after.fromEnd).toBeGreaterThan(40);
    await page.close();
  });

  /// Clicks `query` (unless `click` is false) and reads every painted frame for `ms`: `query`'s own
  /// top (`control`), the opened row's top (a Show more under its text stays at the row's foot, the text above it rises), the first row
  /// under it and the last row's foot, how far the view is from its end, and how far below the row
  /// under it the opened row is drawn (its foot less its clip).
  type Frame = {
    line: number;
    control: number;
    under: number;
    last: number;
    fromEnd: number;
    over: number;
    /// The frame's time (ms).
    at: number;
    /// How long after its frame the read ran (ms).
    lag: number;
    /// The frame's time less the click's (ms), NaN before a click.
    since: number;
  };
  /// One frame at 60 Hz. A read that ran this long after its frame's time says that the page fell
  /// behind: on the CI runners every frame that got no read had a late read after it. Its place is
  /// mostly right for its frame, but a fold with late reads has fewer reads than frames drawn.
  const FRAME_MS = 1000 / 60;
  /// What the reads of one fold say about its glide. `places` counts the in-time reads that drew a
  /// new place strictly between `from` and `to`: more than 1px from both, and more than half a pixel
  /// from the read before. A frame that draws the same place again is no new place: a close that
  /// stopped 4px short of its end for four frames and then jumped (#42247) got four of them for that
  /// stop alone. `late` counts the late reads up to the first read at `to`; with any of them a low
  /// count is no measure of the fold. `seen` is every read's place up to there, a late one marked L.
  const glide = (frames: Frame[], key: "line" | "under", from: number, to: number) => {
    let places = 0;
    let late = 0;
    let last = from;
    let landed = false;
    const seen: string[] = [];
    for (const frame of frames) {
      const top = frame[key];
      const ranLate = frame.lag > FRAME_MS;
      if (!landed) seen.push(`${top.toFixed(1)}${ranLate ? "L" : ""}`);
      if (ranLate) {
        if (!landed) late += 1;
      } else {
        if (Math.abs(top - last) > 0.5 && Math.abs(top - from) > 1 && Math.abs(top - to) > 1) places += 1;
        last = top;
      }
      if (Math.abs(top - to) <= 1) landed = true;
    }
    return { places, late, seen: seen.join(" ") };
  };
  /// What the reads of one fold say about its largest step. A step is one frame's move only when
  /// both of its reads ran in time and their frames are next to each other (less than a frame and a
  /// half apart); the first read follows the place before the click. A late read, or a frame that
  /// got no read, joins the moves of two or three frames into one step, which says nothing about
  /// one frame: an open of 48px whose frames moved 22.3px and 12.4px was read as one step of 34.8px
  /// (#42351). `largest` is the largest one-frame step, `judged` how many of them there were and
  /// `joined` how many moves were not one frame's. The first read of a watch that has none before
  /// the click is judged only when its frame is two frames or less after the click. A read ran
  /// `since + lag` after the click. `jumped` needs no read in time, and has two forms.
  /// Early: a read that ran within JUMP_MS of the click and holds the end place is all of
  /// the move at once, because a fold is not at its end a third of its time in (the settle of
  /// 180 ms is 4.7px of 48px short of it at 60 ms, and within 1px only from about 98 ms). A late
  /// read only makes that time longer, so it cannot turn a fold that glides into a jump. `first`
  /// is when the first read after the click ran: later than JUMP_MS, this form says nothing.
  /// Start then end: a read at `from` and the next read at `to`, run within three frames of the
  /// first one's frame, which also catches a jump that applies later than JUMP_MS. That form
  /// alone let 7 of 24 folds with the fold look "jump" pass every assert in one CI run: their
  /// first read after the click held the end place already, and it ran late.
  /// JUMP_MS is a third of the settle: with a settle under about 110 ms a fold that glides is
  /// within 1px of its end at 60 ms, and the bound must go down with it. The fold's own landing
  /// at once on a page that fell behind (fold.ts FOLD_DROP_MS: the second gap of 50 ms or more in
  /// a row) comes 100 ms or more after its first frame, so the early form does not see it.
  const JUMP_MS = 60;
  const steps = (frames: Frame[], key: "line" | "under", from: number, to: number) => {
    let largest = 0;
    let judged = 0;
    let joined = 0;
    const ran = (frame: Frame) => frame.since + frame.lag;
    const after = frames.find((frame) => Number.isFinite(frame.since));
    const first = after ? ran(after) : undefined;
    let jumped = frames.some((frame) => ran(frame) <= JUMP_MS && Math.abs(frame[key] - to) <= 1);
    let last: { top: number; at?: number; late: boolean } = { top: from, late: false };
    for (const frame of frames) {
      const top = frame[key];
      const late = frame.lag > FRAME_MS;
      const step = Math.abs(top - last.top);
      const next = last.at === undefined ? !(frame.since > FRAME_MS * 2) : frame.at - last.at < FRAME_MS * 1.5;
      if (!late && !last.late && next) {
        judged += 1;
        largest = Math.max(largest, step);
      } else if (step > 0.5) joined += 1;
      if (
        last.at !== undefined &&
        Math.abs(last.top - from) <= 1 &&
        Math.abs(top - to) <= 1 &&
        frame.at + frame.lag - last.at <= FRAME_MS * 3
      )
        jumped = true;
      last = { top, at: frame.at, late };
    }
    return { largest, judged, joined, jumped, first };
  };
  const watchOpen = async (page: Page, query: string, ms = 700, click = true) => {
    const watching = page.evaluate(
      ({ selector, duration }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          const start = performance.now();
          let clicked = Number.NaN;
          addEventListener("click", () => (clicked = performance.now()), { capture: true, once: true });
          window.cmuxAfterPaint((painted) => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const line = document.querySelector<HTMLElement>(selector)!;
            const row = line.closest<HTMLElement>(".acpmux-row")!;
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
            const box = row.getBoundingClientRect();
            const next = rows
              .filter((each) => each !== row && each.getBoundingClientRect().top >= box.top + 1)
              .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0]!;
            const cut = /inset\(\S+ \S+ ([\d.]+)px/.exec(getComputedStyle(row).clipPath);
            frames.push({
              line: box.top,
              control: line.getBoundingClientRect().top,
              under: next.getBoundingClientRect().top,
              last: rows.at(-1)!.getBoundingClientRect().bottom,
              fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
              over: box.bottom - (cut ? Number(cut[1]) : 0) - next.getBoundingClientRect().top,
              at: painted,
              lag: performance.now() - painted,
              since: painted - clicked,
            });
            if (performance.now() - start < duration) return;
            resolve(frames);
            return false;
          });
        }),
      { selector: query, duration: ms },
    );
    if (click) await clickLine(page, query);
    return watching;
  };

  /// Not only where it settles: on every frame of the fold the opened line keeps its pixel, the rows
  /// under it only move down, and nothing of what opened draws over the row under it (Codex parity).
  for (const [variant, query] of [
    [VARIANT, GROUP],
    ["prompt", '.cv-user__more[aria-expanded="false"]'],
  ] as const) {
    test(`at the very bottom (${variant}), every frame keeps the line still and grows down`, async () => {
      const page = await open(variant, query);
      await page.locator(".acpmux-scroll").evaluate((node, selector) => {
        node.querySelector<HTMLElement>(selector)!.dataset.openProbe = "true";
        node.scrollTop = node.scrollHeight;
      }, query);
      await settled(page);
      const PROBE = "[data-open-probe]";
      const before = (await watchOpen(page, PROBE, 0, false))[0]!;
      const frames = await watchOpen(page, PROBE);
      expect(frames.length).toBeGreaterThan(5);
      let under = before.under;
      for (const [index, frame] of frames.entries()) {
        const at = { index, ...frame };
        expect({ at, still: Math.abs(frame.line - before.line) <= 1 }).toEqual({ at, still: true });
        expect({ at, covered: frame.over <= 1 }).toEqual({ at, covered: true });
        expect({ at, down: frame.under >= under - 0.5 }).toEqual({ at, down: true });
        under = frame.under;
      }
      expect(frames.at(-1)!.under - before.under).toBeGreaterThan(40);
      await page.close();
    });
  }

  /// Leo, 2026-11-04: "how come there aren't animatiosn for expanding/collapsing tool calls
  /// anymore???". Opening "Ran 2 commands" at the very bottom glides the rows under it down while the
  /// line stays; back at the very end, closing it glides the text above down (the bottom pin), while
  /// the view stays at its end and the last row keeps its pixels. Each moves over several painted
  /// frames, never most of the way in one.
  // In Chromium and in WebKit, the app's own engine (where the thread slide this replaced jumped).
  for (const engineName of ["chromium", "webkit"] as const)
    test(`inline run at the very bottom (${engineName}), opening and closing a group glide the text above over several frames`, async () => {
      let engine = browser!;
      if (engineName === "webkit") {
        try {
          engine = await webkit.launch({ headless: true });
        } catch (error) {
          if (process.env.GITHUB_ACTIONS === "true") throw error;
          console.warn("transcript-expand-at-bottom: WebKit glide skipped (run `bunx playwright install webkit`)");
          return;
        }
        await warmGalleryFrame(vite!, ENTRY, { browser: engine, params: { variant: VARIANT } });
      }
      // This oracle measures the transcript's full inline expansion; boxed runs own their scroll.
      const page = await open(VARIANT, GROUP, engine, { "run-scroll": "inline" });
      await page.locator(".acpmux-scroll").evaluate((node, selector) => {
        node.querySelector<HTMLElement>(selector)!.dataset.glideProbe = "true";
        node.scrollTop = node.scrollHeight;
      }, GROUP);
      await settled(page);
      const PROBE = "[data-glide-probe]";
      for (const direction of ["open", "close"] as const) {
        // An open at the end leaves the view short of it: the close starts at the very end again.
        if (direction === "close") {
          await page.locator(".acpmux-scroll").evaluate((node) => {
            node.scrollTop = node.scrollHeight;
          });
          await settled(page);
        }
        const before = (await watchOpen(page, PROBE, 0, false))[0]!;
        const frames = await watchOpen(page, PROBE);
        await settled(page);
        const after = (await watchOpen(page, PROBE, 0, false))[0]!;
        // Opening moves the rows under the line down; closing brings the line down by what closed.
        const moving = direction === "open" ? "under" : "line";
        const total = after[moving] - before[moving];
        expect({ direction, moved: total > 40 }).toEqual({ direction, moved: true });
        if (direction === "open")
          for (const [index, frame] of frames.entries()) {
            const at = { direction, index, ...frame };
            expect({ at, still: Math.abs(frame.line - before.line) <= 1 }).toEqual({ at, still: true });
          }
        // A step judged is one frame's: the settle curve (cubic-bezier(0.16, 1, 0.3, 1), 180 ms)
        // covers about half the way in its first 17 ms and 70% by 30 ms, so a first frame drawn two
        // frames after the click on a busy runner, or a frame the runner dropped, spans more than
        // one frame of the curve and says nothing of the glide: `steps` leaves such a step out.
        // The watch saw the click: it has reads from the click on.
        expect(frames.filter((frame) => Number.isFinite(frame.since)).length).toBeGreaterThan(0);
        // Three new places or more strictly between where it was and where it settles: the glide,
        // not a jump. Fewer with reads that ran late is no measure: it says so and judges nothing.
        const { places, late, seen } = glide(frames, moving, before[moving], after[moving]);
        if (places < 3 && late > 0)
          console.log(
            `no verdict: late frames (${engineName} ${direction}: ${places} new places between in time, ${late} late reads; from ${before[moving].toFixed(1)} to ${after[moving].toFixed(1)}, places read, L = late: ${seen})`,
          );
        else expect({ direction, places, between: places >= 3 }).toEqual({ direction, places, between: true });
        // No frame moves most of the way: the largest one-frame step. A move read over a late read
        // or over a frame with no read is two or three frames' moves: it says so and is not judged,
        // but a read at the end place within JUMP_MS of the click, or all of the move between two
        // reads next to each other, is a jump however the reads ran.
        const { largest, judged, joined, jumped, first } = steps(frames, moving, before[moving], after[moving]);
        if (!jumped && (first === undefined || first > JUMP_MS))
          console.log(
            `no verdict: jump (${engineName} ${direction}: the first read after the click ran ${first?.toFixed(0) ?? "never"}ms after it, later than ${JUMP_MS}ms)`,
          );
        if (joined > 0)
          console.log(
            `no verdict: joined steps (${engineName} ${direction}: ${joined} moves read over a late read or a frame with no read, ${judged} one-frame steps judged, the largest ${largest.toFixed(1)} of ${Math.abs(total).toFixed(1)})`,
          );
        expect({ direction, jumped }).toEqual({ direction, jumped: false });
        expect({ direction, largest, smooth: largest <= Math.abs(total) * 0.7 }).toEqual({
          direction,
          largest,
          smooth: true,
        });
        if (direction === "close")
          for (const [index, frame] of frames.entries()) {
            const at = { direction, index, ...frame };
            expect({ at, end: frame.fromEnd <= 2 }).toEqual({ at, end: true });
            expect({ at, last: Math.abs(frame.last - before.last) <= 1 }).toEqual({ at, last: true });
          }
      }
      await page.close();
      if (engine !== browser) await engine.close();
    });

  /// The scene's own plays (ExpandAtBottom.gallery.ts) check where the bottom and the clicked line
  /// end up; each throws, and the stage reports it, when they are off. Leo, 2026-11-03: "it's weird
  /// to collapse and get all that empty space at the bottom".
  for (const variant of ["expand-at-bottom", "collapse-at-bottom", "collapse-tall-group", "expand-away"]) {
    test(`gallery play ${variant}`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
      await page.addInitScript(() => localStorage.clear());
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant })}`);
      await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
        timeout: 60_000,
      });
      const report = await page.evaluate(() =>
        JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
      );
      await page.close();
      expect(playFailures(report)).toEqual([]);
    });
  }

  test("away from the bottom, opening a line keeps it put and grows its body down", async () => {
    const page = await open();
    // The earlier turn's "Worked for" line, 160px under the view's top, the rest of the chat under it.
    const MID = "[data-mid-probe]";
    await page.locator(".acpmux-scroll").evaluate((node) => {
      const line = [...node.querySelectorAll<HTMLElement>(".cv-worked")].at(-2)!;
      line.dataset.midProbe = "true";
      node.scrollTop += line.getBoundingClientRect().top - node.getBoundingClientRect().top - 160;
    });
    await settled(page);
    const where = (query: string) =>
      page.evaluate((selector) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const line = document.querySelector<HTMLElement>(selector)!;
        return {
          line: line.getBoundingClientRect().top,
          open: line.getAttribute("aria-expanded"),
          scrollTop: scroller.scrollTop,
          scrollHeight: scroller.scrollHeight,
          fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        };
      }, query);
    const before = await where(MID);
    expect(before.open).toBe("false");
    expect(before.fromEnd).toBeGreaterThan(40);
    await clickLine(page, MID);
    await settled(page);
    const after = await where(MID);
    expect(after.open).toBe("true");
    // The line stays on its pixel and the view where it was; what opened grew the chat downward.
    expect(Math.abs(after.line - before.line)).toBeLessThanOrEqual(1);
    expect(Math.abs(after.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);
    expect(after.scrollHeight).toBeGreaterThan(before.scrollHeight + 20);
    await page.close();
  });
});
