// cmux-web-test-alone
// l10n-allow-file: the gallery fixture supplies the transcript's messages.
// The lift looks of a turn's final fold (turnEndFold.ts `lift-*`, rule 3 of hq RFD transcript-ordering,
// cmuxterm-hq#25873; Leo, 2026-11-25: "cuz the final ultra fold simply... takes it all away. we simply
// need to make sure it looks good while doing so. aka fast fades and comfy (maybe eased) and fast and
// snappy and satisfying transition animations"). In the steered turn of `agent-pane.turn-end-fold`, for
// each of the three timings: the folded rows' fade is done within the look's fade (at most 160 ms),
// every row that stays moves on one transform clock (one length, no stagger), no row is drawn twice
// (a fading copy never shows the text of a row drawn at the same time), and the steer and the answer
// are there through the fold and after it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

const ENTRY = "agent-pane.turn-end-fold";
const LIFTS = [
  { variant: "lift-snappy-steered", fadeMs: 120, moveMs: 180 },
  { variant: "lift-mid-steered", fadeMs: 140, moveMs: 200 },
  { variant: "lift-comfy-steered", fadeMs: 160, moveMs: 220 },
] as const;
const STEER = "also check the backoff cap";
const ANSWER = "Fixed: the jitter now stays inside the backoff";

type Played = { copy: boolean; props: string[]; duration: number; delay: number };
type Frame = { at: number; folding: boolean; doubled: string[]; inkedCopies: number; steer: boolean; answer: boolean };

await requireBrowserLane("turn-end-fold-lift-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const launchOptions = process.env.CMUX_BROWSER_EXECUTABLE
    ? { executablePath: process.env.CMUX_BROWSER_EXECUTABLE }
    : {};
  try {
    await (await chromium.launch({ headless: true, ...launchOptions })).close();
  } catch {
    console.warn("turn-end-fold-lift-browser: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: LIFTS[0].variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const lift of LIFTS)
    test(`${lift.variant}: fade in ${lift.fadeMs} ms, one ${lift.moveMs} ms move, nothing twice, steer and answer stay`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
      await installPaintedFrames(page);
      // Every animation the page starts, by what it plays and whether it is on a fold's copy (a row
      // with no row id: turnFold.ts ghostOf).
      await page.addInitScript(() => {
        const w = window as unknown as { __played: Played[] };
        w.__played = [];
        const animate = Element.prototype.animate;
        Element.prototype.animate = function (this: Element, keyframes, options) {
          const frames = Array.isArray(keyframes) ? keyframes : keyframes ? [keyframes] : [];
          const props = [...new Set(frames.flatMap((frame) => Object.keys(frame ?? {})))].filter(
            (key) => key !== "offset" && key !== "easing" && key !== "composite",
          );
          const timing = typeof options === "number" ? { duration: options } : (options ?? {});
          const element = this as HTMLElement;
          w.__played.push({
            copy: element.classList.contains("acpmux-row") && !element.hasAttribute("data-row-id"),
            props,
            duration: Number(timing.duration ?? 0),
            delay: Number(timing.delay ?? 0),
          });
          return animate.call(this, keyframes, options);
        };
      });
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: lift.variant })}`);
      await page.getByTestId("turn-end-start").waitFor();
      await page.evaluate(() => {
        (window as unknown as { __played: Played[] }).__played = [];
      });
      // Each painted frame from the click on: whether the fold plays, the copies still inked, any
      // copy whose text a drawn row also shows, and whether the steer and the answer are drawn.
      await page.evaluate(
        ({ steer, answer }) => {
          const w = window as unknown as { __frames: Frame[] };
          w.__frames = [];
          window.cmuxAfterPaint((at) => {
            const thread = document.querySelector<HTMLElement>(".acpmux-thread");
            if (!thread) return;
            const inked = (node: HTMLElement) => Number(getComputedStyle(node).opacity) > 0.02;
            const rows = [...thread.querySelectorAll<HTMLElement>(":scope > .acpmux-row")];
            const live = rows.filter((row) => row.hasAttribute("data-row-id"));
            const copies = rows.filter((row) => !row.hasAttribute("data-row-id") && inked(row));
            const drawn = new Set(live.filter(inked).map((row) => row.textContent?.trim() ?? ""));
            w.__frames.push({
              at,
              folding: thread.hasAttribute("data-turn-end-folding"),
              doubled: copies.map((copy) => copy.textContent?.trim() ?? "").filter((text) => text && drawn.has(text)),
              inkedCopies: copies.length,
              steer: live.some((row) => row.textContent?.includes(steer)),
              answer: live.some((row) => row.textContent?.includes(answer)),
            });
            return w.__frames.length < 900;
          });
        },
        { steer: STEER, answer: ANSWER },
      );
      await page.getByTestId("turn-end-start").click();
      await page.getByTestId("turn-end-state").filter({ hasText: "Turn folded" }).waitFor({ timeout: 10_000 });
      const { played, frames } = await page.evaluate(() => {
        const w = window as unknown as { __played: Played[]; __frames: Frame[] };
        return { played: w.__played, frames: w.__frames };
      });
      await page.close();

      const folding = frames.filter((frame) => frame.folding);
      expect(folding.length).toBeGreaterThan(0);
      const start = folding[0]!.at;
      // The fade: every fold copy's opacity runs at most the look's fade, from its first frame.
      const fades = played.filter((each) => each.copy && each.props.includes("opacity"));
      expect(fades.length).toBeGreaterThan(0);
      for (const fade of fades) {
        expect(fade.duration).toBeLessThanOrEqual(lift.fadeMs);
        expect(fade.delay).toBeLessThanOrEqual(0);
      }
      expect(lift.fadeMs).toBeLessThanOrEqual(160);
      // As painted: no copy keeps ink past the fade (a frame's slack at 60 Hz).
      const lastInked = folding.filter((frame) => frame.inkedCopies > 0).at(-1);
      if (lastInked) expect(lastInked.at - start).toBeLessThanOrEqual(lift.fadeMs + 17);
      // One transform: every row that moves plays the same length from the same start (no stagger).
      const moves = played.filter(
        (each) => !each.copy && (each.props.includes("translate") || each.props.includes("transform")),
      );
      expect(moves.length).toBeGreaterThan(0);
      expect([...new Set(moves.map((move) => move.duration))]).toEqual([lift.moveMs]);
      for (const move of moves) expect(move.delay).toBeLessThanOrEqual(0);
      // Nothing drawn twice, and the person's steer and the answer drawn through the fold and after.
      expect(frames.flatMap((frame) => frame.doubled)).toEqual([]);
      for (const frame of folding) {
        expect(frame.steer).toBe(true);
        expect(frame.answer).toBe(true);
      }
      expect(frames.at(-1)!.steer).toBe(true);
      expect(frames.at(-1)!.answer).toBe(true);
    });
});
