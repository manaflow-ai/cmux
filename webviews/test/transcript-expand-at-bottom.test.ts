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
    /// How long after its frame the read ran (ms).
    lag: number;
    /// The frame's time less the click's (ms), NaN before a click.
    since: number;
    /// The height folds playing in the opened row at this read.
    folds: Fold[];
    /// Whether a height fold has played in the opened row, in a frame or at a read, up to this read.
    animated: boolean;
  };
  /// One height animation of the opened row (fold.ts `useFold`), read from the animation itself:
  /// the box it sizes (`id`, one number for each box), the heights it goes between, its length and
  /// its curve, where its own clock stood in the last frame drawn before the read (`time`, ms), and
  /// the height its box is drawn at.
  type Fold = { id: number; from: number; to: number; time: number; span: number; ease: string; drawn: number };
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
  /// An animation's curve at `x` of its time (0 to 1): `linear` or a `cubic-bezier(...)`, which is
  /// what the fold plays on (the settle). The bezier's own parameter is found by halving.
  const eased = (ease: string, x: number) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    if (ease === "linear") return x;
    const bezier = /^cubic-bezier\(([^)]+)\)$/.exec(ease);
    const [x1, y1, x2, y2] = (bezier?.[1] ?? "").split(",").map(Number);
    if (x1 === undefined || y1 === undefined || x2 === undefined || y2 === undefined || Number.isNaN(x1 + y1 + x2 + y2))
      throw new Error(`a fold's curve this test cannot read: ${ease}`);
    const along = (a: number, b: number, t: number) =>
      3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
    let low = 0;
    let high = 1;
    for (let round = 0; round < 40; round++) {
      const middle = (low + high) / 2;
      if (along(x1, x2, middle) < x) low = middle;
      else high = middle;
    }
    return along(y1, y2, (low + high) / 2);
  };
  /// The most a read's place may be off the fold's curve (px): a pixel of the scroll offset's
  /// rounding and the half pixel `curve` allows between a box and its own curve.
  const CURVE_PX = 2;
  /// What the reads of one fold say about its motion, with no clock of the test's: each read's
  /// place is set against the fold's own curve at the fold's own time. The page's animation says
  /// where its clock stood in the last frame drawn and which heights it goes between, so the height
  /// the fold has at that time is known, and the text moves by exactly what the fold's boxes have
  /// grown or shrunk by (`sign` 1: the place goes down as they grow; -1: as they shrink). A read
  /// that ran late, or a frame the runner dropped, only reads the curve at a later time, so neither
  /// can make a fold that glides look like a jump, and no step size is judged: the settle covers
  /// about half the way in its first frame and 70% in two, which read as one step was a red with
  /// nothing wrong (#42351, #42525).
  /// `judged` counts the reads set against the curve: those with every fold of the row in flight
  /// (its clock strictly inside its length) and each box drawn within half a pixel of its own curve,
  /// which says the read is of the frame the clock is of. `apart` counts the reads in flight that
  /// are not (they are not judged). `worst` is the furthest a judged place was off the curve.
  /// `jumped` is a read whose place has left `from` with no height fold seen in the row up to it:
  /// a move with no fold, the whole of it at once.
  const curve = (frames: Frame[], key: "line" | "under", from: number, sign: 1 | -1) => {
    const starts = new Map<number, number>();
    let judged = 0;
    let apart = 0;
    let worst = 0;
    let jumped = false;
    const seen: string[] = [];
    for (const frame of frames) {
      if (!frame.animated && Math.abs(frame[key] - from) > 1) jumped = true;
      for (const fold of frame.folds) if (!starts.has(fold.id)) starts.set(fold.id, fold.from);
      const flying = frame.folds.filter((fold) => fold.time > 0 && fold.time < fold.span);
      if (flying.length === 0 || flying.length < starts.size) continue;
      let moved = 0;
      let inStep = true;
      for (const fold of flying) {
        const height = fold.from + (fold.to - fold.from) * eased(fold.ease, fold.time / fold.span);
        if (Math.abs(fold.drawn - height) > 0.5) inStep = false;
        moved += height - starts.get(fold.id)!;
      }
      if (!inStep) {
        apart += 1;
        continue;
      }
      const off = Math.abs(frame[key] - from - sign * moved);
      judged += 1;
      worst = Math.max(worst, off);
      seen.push(`${frame[key].toFixed(1)}@${flying[0]!.time.toFixed(0)}ms/${off.toFixed(1)}`);
    }
    return { judged, apart, worst, jumped, seen: seen.join(" ") };
  };
  const watchOpen = async (page: Page, query: string, frameCount = 45, click = true) => {
    const watching = page.evaluate(
      ({ selector, frameCount }) =>
        new Promise<Frame[]>((resolve) => {
          const frames: Frame[] = [];
          // Observe a fixed number of painted frames, not a wall-clock window: a loaded runner paints
          // fewer frames in the same time and can stop between a layout and the paint that settles it.
          let seen = 0;
          let clicked = Number.NaN;
          addEventListener("click", () => (clicked = performance.now()), { capture: true, once: true });
          // The height animations playing in `row`, the fold's (fold.ts): each with its own clock.
          const playing = (row: HTMLElement) =>
            row.getAnimations({ subtree: true }).flatMap((animation) => {
              const effect = animation.effect;
              if (!(effect instanceof KeyframeEffect) || !effect.target) return [];
              const heights = effect.getKeyframes().map((keyframe) => Number.parseFloat(String(keyframe.height)));
              const [from, to] = [heights[0], heights.at(-1)];
              if (from === undefined || to === undefined || Number.isNaN(from + to)) return [];
              return [{ animation, effect, target: effect.target, from, to }];
            });
          const ids = new Map<Element, number>();
          // The document timeline's time in the last frame drawn: what that frame's animations ran at.
          let drawnAt = Number.NaN;
          let animated = false;
          const rowOf = () => document.querySelector<HTMLElement>(selector)!.closest<HTMLElement>(".acpmux-row")!;
          const inFrame = () => {
            const now = document.timeline.currentTime;
            drawnAt = typeof now === "number" ? now : Number.NaN;
            if (playing(rowOf()).length > 0) animated = true;
          };
          window.cmuxAfterPaint((painted) => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const line = document.querySelector<HTMLElement>(selector)!;
            const row = line.closest<HTMLElement>(".acpmux-row")!;
            const folds = playing(row).map(({ animation, effect, target, from, to }) => {
              if (!ids.has(target)) ids.set(target, ids.size);
              // The animation's time in the last frame drawn, from its own start on the timeline: a
              // read runs after its frame, and the page may have set the fold's clock in that frame.
              const started = animation.startTime;
              const time =
                typeof started === "number" && !Number.isNaN(drawnAt)
                  ? (drawnAt - started) * animation.playbackRate
                  : Number(animation.currentTime ?? 0);
              return {
                id: ids.get(target)!,
                from,
                to,
                time,
                span: Number(effect.getComputedTiming().duration),
                ease: effect.getTiming().easing ?? "linear",
                drawn: target.getBoundingClientRect().height,
              };
            });
            if (folds.length > 0) animated = true;
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
              lag: performance.now() - painted,
              since: painted - clicked,
              folds,
              animated,
            });
            seen += 1;
            if (seen < frameCount) return;
            resolve(frames);
            return false;
          }, inFrame);
        }),
      { selector: query, frameCount },
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
  /// frames, each of them on the fold's own curve.
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
        // The text moves on the fold's own curve: every read in flight is where the fold's clock
        // says, and a move with no fold in the row is a jump. A fold with no read judged is no
        // measure of this: it says so.
        const {
          judged,
          apart,
          worst,
          jumped,
          seen: curved,
        } = curve(frames, moving, before[moving], direction === "open" ? 1 : -1);
        if (judged === 0)
          console.log(
            `no verdict: curve (${engineName} ${direction}: no read in flight was set against the fold's curve, ${apart} not of the frame their clock is of)`,
          );
        expect({ direction, jumped }).toEqual({ direction, jumped: false });
        expect({ direction, worst, curved, onCurve: worst <= CURVE_PX }).toEqual({
          direction,
          worst,
          curved,
          onCurve: true,
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
