// l10n-allow-file: the gallery fixture supplies the long tool-call transcript.
// RED TEST, never to merge. A wheel that a boxed run's own scroller takes must not move the
// transcript. agent-pane-tool-group-scroll.test.ts sends that wheel after the run's fold ended and
// reads the transcript's offset at once. This file sends it INSIDE the fold and at rest, then
// watches the transcript for 2.5 s (the input-quiet time of a deferred follow is 1 s), and prints
// one REPORT line for each case with the offsets and the frames in which they changed.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

type Sample = { at: number; top: number; room: number; row: number; playing: boolean; box: number };
type Recorded = { start: number; wheel: (Sample & { inBox: boolean }) | null; frames: Sample[] };
type Plan = {
  /** The name in the REPORT line. */
  name: string;
  /** Px taken from the transcript's height before the run opens (0 = the fixture as it is). */
  shorten: number;
  /** Wait for the end of the run's fold before the wheel. */
  rest: boolean;
  /** Send a wheel of 40 px over the box. */
  wheel: boolean;
  /** Px taken from the transcript's height after the wheel: a layout pass that is no reader input. */
  shrinkAfter: number;
};
type Outcome = {
  before: number;
  after: number;
  boxTop: number;
  moved: boolean;
  seen: Recorded;
};

await requireBrowserLane("agent-pane-tool-group-wheel-in-fold.test.ts", async () => {
  setDefaultTimeout(120_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("agent-pane-tool-group-wheel-in-fold: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.transcript", {
      browser,
      params: { variant: "tool-run-scrolled-fade" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Resolves when the row of `selector` plays no animation and its height and the transcript's offset and scroll height hold for 6 frames. */
  async function held(page: Page, selector: string, key: string, what: string): Promise<void> {
    await page
      .waitForFunction(
        ([rowOf, name]) => {
          const row = document.querySelector<HTMLElement>(rowOf)?.closest<HTMLElement>(".acpmux-row");
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!row || !scroller) return false;
          const holder = globalThis as unknown as Record<
            string,
            { height: number; top: number; full: number; held: number } | undefined
          >;
          const seen = (holder[name] ??= { height: -1, top: -1, full: -1, held: 0 });
          const height = row.getBoundingClientRect().height;
          const top = scroller.scrollTop;
          const full = scroller.scrollHeight;
          const playing = row.getAnimations({ subtree: true }).some((each) => each.playState === "running");
          const same = Math.abs(height - seen.height) < 0.01 && Math.abs(top - seen.top) < 0.01 && full === seen.full;
          seen.held = same && !playing ? seen.held + 1 : 0;
          seen.height = height;
          seen.top = top;
          seen.full = full;
          return seen.held >= 6;
        },
        [selector, key] as const,
        { polling: "raf", timeout: 5_000 },
      )
      .catch((error: unknown) => {
        throw new Error(`${what} did not hold for 6 frames in 5 s (${String(error).split("\n")[0]})`);
      });
  }

  /** Takes `by` px from the transcript's own height: a layout change that is no scroll input. */
  async function shorten(page: Page, by: number): Promise<void> {
    await page.locator(".acpmux-scroll").evaluate((node, px) => {
      const now = Number.parseFloat(getComputedStyle(node).height);
      node.style.flex = "none";
      node.style.height = `${now - px}px`;
    }, by);
  }

  async function drive(plan: Plan): Promise<Outcome> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.addInitScript(() => localStorage.clear());
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript", { variant: "tool-run-scrolled-fade" })}`,
    );
    const worked = page.locator(".cv-worked").first();
    if ((await worked.getAttribute("aria-expanded")) !== "true") await worked.click();
    const run = page.locator(".cv-tools > .cv-tool.is-toggle").first();
    await run.waitFor();
    const transcript = page.locator(".acpmux-scroll");
    if (plan.shorten > 0) {
      // A layout precondition, as in the inline case of agent-pane-tool-group-scroll.test.ts: the
      // chat still fits before the run opens, and the open run makes it overflow by more px.
      await held(page, ".cv-tools > .cv-tool.is-toggle", "__beforeShorten", "the chat before it gets shorter");
      await shorten(page, plan.shorten);
      await held(page, ".cv-tools > .cv-tool.is-toggle", "__afterShorten", "the shorter chat");
      expect(await transcript.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeLessThanOrEqual(0);
    }
    // The record of this page: the first wheel event as the page saw it, and each painted frame in
    // which the transcript's offset, its scroll room, the box's offset or the fold's play state changed.
    await installPaintedFrames(page);
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const state: Recorded = { start: performance.now(), wheel: null, frames: [] };
      (globalThis as unknown as { __wheelFold?: Recorded }).__wheelFold = state;
      const sample = () => {
        const box = document.querySelector<HTMLElement>(".cv-run-scroll");
        const row = (box ?? document.querySelector<HTMLElement>(".cv-tools"))?.closest<HTMLElement>(".acpmux-row");
        return {
          at: Math.round(performance.now() - state.start),
          top: scroller.scrollTop,
          room: scroller.scrollHeight - scroller.clientHeight,
          row: row ? Math.round(row.getBoundingClientRect().height * 10) / 10 : -1,
          playing: row ? row.getAnimations({ subtree: true }).some((each) => each.playState === "running") : false,
          box: box ? Math.round(box.scrollTop) : -1,
        };
      };
      window.addEventListener(
        "wheel",
        (event) => {
          if (state.wheel) return;
          const target = event.target;
          state.wheel = {
            ...sample(),
            inBox: target instanceof Element && target.closest(".cv-run-scroll") !== null,
          };
        },
        { capture: true, passive: true },
      );
      let last = "";
      window.cmuxAfterPaint(() => {
        const now = sample();
        const key = `${now.top}|${now.room}|${now.playing}|${now.box}`;
        if (key !== last && state.frames.length < 80) state.frames.push(now);
        last = key;
        return now.at < 15_000;
      });
    });
    if ((await run.getAttribute("aria-expanded")) !== "true") await run.click();
    const box = page.locator(".cv-run-scroll").first();
    await box.waitFor();
    if (plan.rest) await held(page, ".cv-run-scroll", "__runFoldSeen", "the run's fold: its row and the transcript");
    await box.scrollIntoViewIfNeeded();
    await box.evaluate((node) => {
      node.scrollTop = 0;
    });
    expect(await box.evaluate((node) => node.scrollHeight - node.clientHeight)).toBeGreaterThan(40);
    const before = await transcript.evaluate((node) => node.scrollTop);
    if (plan.wheel) {
      const bounds = (await box.boundingBox())!;
      await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
      await page.mouse.wheel(0, 40);
      await page
        .waitForFunction(() => (document.querySelector<HTMLElement>(".cv-run-scroll")?.scrollTop ?? 0) > 2, undefined, {
          timeout: 5_000,
        })
        .catch(() => undefined);
    }
    if (plan.shrinkAfter > 0) await shorten(page, plan.shrinkAfter);
    // A bounded watch, no fixed wait: it ends at the first frame in which the transcript is more
    // than 1 px from where it was, or after 2.5 s with no such frame.
    const moved = await page
      .waitForFunction(
        (from) => Math.abs((document.querySelector<HTMLElement>(".acpmux-scroll")?.scrollTop ?? 0) - from) > 1,
        before,
        { polling: "raf", timeout: 2_500 },
      )
      .then(
        () => true,
        () => false,
      );
    if (moved) await held(page, ".cv-run-scroll", "__afterMove", "the transcript after its move");
    const after = await transcript.evaluate((node) => node.scrollTop);
    const boxTop = await box.evaluate((node) => node.scrollTop);
    const seen = await page.evaluate(() => (globalThis as unknown as { __wheelFold: Recorded }).__wheelFold);
    console.log(
      `REPORT wheel-in-fold ${JSON.stringify({ case: plan.name, before, after, boxTop, moved, wheel: seen.wheel, frames: seen.frames })}`,
    );
    await page.close();
    return { before, after, boxTop, moved, seen };
  }

  const fixture = { shorten: 0, shrinkAfter: 0 };

  test("boxed run, a wheel INSIDE the fold that the box takes: the transcript does not move", async () => {
    const result = await drive({ ...fixture, name: "1 in the fold", rest: false, wheel: true });
    expect(result.seen.wheel?.inBox).toBe(true);
    expect(result.boxTop).toBeGreaterThan(2);
    expect(Math.abs(result.after - result.before)).toBeLessThanOrEqual(1);
  });

  test("boxed run, a wheel AT REST that the box takes: the transcript does not move in 2.5 s", async () => {
    const result = await drive({ ...fixture, name: "2 at rest", rest: true, wheel: true });
    expect(result.seen.wheel?.inBox).toBe(true);
    expect(result.boxTop).toBeGreaterThan(2);
    expect(Math.abs(result.after - result.before)).toBeLessThanOrEqual(1);
  });

  test("boxed run in a chat 17 px shorter, a wheel INSIDE the fold: the transcript does not move", async () => {
    const result = await drive({
      ...fixture,
      name: "1b in the fold, 17 px shorter",
      shorten: 17,
      rest: false,
      wheel: true,
    });
    expect(result.seen.wheel?.inBox).toBe(true);
    expect(result.boxTop).toBeGreaterThan(2);
    expect(Math.abs(result.after - result.before)).toBeLessThanOrEqual(1);
  });

  test("boxed run in a chat 17 px shorter, a wheel AT REST: the transcript does not move in 2.5 s", async () => {
    const result = await drive({ ...fixture, name: "2b at rest, 17 px shorter", shorten: 17, rest: true, wheel: true });
    expect(result.seen.wheel?.inBox).toBe(true);
    expect(result.boxTop).toBeGreaterThan(2);
    expect(Math.abs(result.after - result.before)).toBeLessThanOrEqual(1);
  });

  // The MEASURE cases assert no offset; they print what the transcript does with no wheel in the
  // box, so that a move in the cases above is the wheel's and not the fold's own.
  test("MEASURE boxed run, the fold with NO wheel", async () => {
    const result = await drive({ ...fixture, name: "0 control: the fold, no wheel", rest: false, wheel: false });
    expect(result.seen.wheel).toBeNull();
  });

  test("MEASURE boxed run in a chat 17 px shorter, the fold with NO wheel", async () => {
    const result = await drive({
      ...fixture,
      name: "0b control: the fold, no wheel, 17 px shorter",
      shorten: 17,
      rest: false,
      wheel: false,
    });
    expect(result.seen.wheel).toBeNull();
  });

  // The next 2 MEASURE cases: whether a reader who is 3 px from the end is "at the end"
  // is a question of the design (the follow deadband). They print what a layout pass with no scroll
  // input does to the offset, with and without a wheel in the box before it.
  test("MEASURE boxed run at rest, then the chat gets 20 px shorter (no wheel)", async () => {
    const result = await drive({
      ...fixture,
      name: "3 control: at rest, no wheel, 20 px shorter",
      shrinkAfter: 20,
      rest: true,
      wheel: false,
    });
    expect(result.seen.wheel).toBeNull();
  });

  test("MEASURE boxed run at rest, a wheel in the box, then the chat gets 20 px shorter", async () => {
    const result = await drive({
      ...fixture,
      name: "3 at rest, wheel, 20 px shorter",
      shrinkAfter: 20,
      rest: true,
      wheel: true,
    });
    expect(result.seen.wheel?.inBox).toBe(true);
    expect(result.boxTop).toBeGreaterThan(2);
  });
});
