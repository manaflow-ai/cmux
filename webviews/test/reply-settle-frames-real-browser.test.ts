// cmux-web-test-timeout: 300
// l10n-allow-file: probe.
// The turn-end fold's arriving reply, read from painted frames in real Chromium: real Web Animations,
// real layout, `getComputedStyle(reply).opacity` and `getBoundingClientRect()` sampled on every
// requestAnimationFrame (reply-settle-place-browser.test.ts mocks `animate` in JSDOM instead).
// - cmux#48689 F1: a relayout during the fold (the reply's row placed again, as when a row above it
//   measured shorter) makes a kept row cross the reply's box; the reply's hold is read again, so it
//   shows no ink on any frame a kept row overlaps it.
// - cmux#48689 F2: with a hold near the move's length, the fold's backstop waits for the held fade:
//   the reply's ink never jumps faster than a linear fade, and the fold stays marked until it is full.
// - cmux#48689 F3: a reply that plays its own entrance (`acpmux-row--message-enter`) and that no kept
//   row crosses gets no fade of the fold's.
// Rows are absolutely placed divs in a `position: relative` thread; no CSS is loaded, so the fold
// runs on the settle fallback (180 ms) and nothing else animates.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

type Box = { top: number; bottom: number };
type Frame = {
  t: number;
  reply: Box & { opacity: number };
  kept: Box;
  keptBelow?: Box;
  folding: boolean;
  animations: number;
};
type Run = { frames: Frame[]; relayoutAt: number; ms: number; holds: number[] };
type Stage = {
  /** Where the kept row was drawn when the turn ended, and its place after the swap. */
  keptWas: number;
  keptTop: number;
  replyTop: number;
  replyClass?: string;
  /** Optional retained row below the arriving reply, to exercise an entrance between kept rows. */
  keptBelowWas?: number;
  keptBelowTop?: number;
  /** The frame on which the reply's row is placed again at `relayoutTop` (none: -1). */
  relayoutFrame: number;
  relayoutTop?: number;
};

await requireBrowserLane("reply-settle-frames-real-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    // The page is blank; the modules the stage imports are what a cold server would make it wait for.
    const conversation = `${vite.config.base}src/agent-session/acpmux/conversation/`;
    await warmViteServer(vite, `${conversation}turnEndFold.ts`);
    await warmViteServer(vite, `${conversation}turns.ts`);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Stages one turn end on a blank same-origin page and samples every painted frame until it settles. */
  const run = async (stage: Stage): Promise<Run> => {
    const page = await browser.newPage({ viewport: { width: 800, height: 900 } });
    try {
      const origin = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
      // A blank page through Vite's HTML transform, so it carries the React refresh preamble the
      // fold's imports (chat metrics, icons) expect.
      const blank = await vite!.transformIndexHtml(
        "/blank.html",
        "<!doctype html><html><head></head><body></body></html>",
      );
      await page.route(`${origin}/blank.html`, (route) => route.fulfill({ contentType: "text/html", body: blank }));
      await page.goto(`${origin}/blank.html`);
      const base = `${vite!.config.base}src/agent-session/acpmux/conversation/`;
      return await page.evaluate(
        async ({ stage, fold: foldUrl, turns: turnsUrl }) => {
          const { captureTurnEnd, playTurnEnd, settleTurnEnd, TURN_END_ATTR } = await import(foldUrl);
          const { LIVE_THINKING } = await import(turnsUrl);
          document.body.style.margin = "0";
          const thread = document.createElement("main");
          // These pin the fold's slide mechanics, the `fade` look's (the shipped look, `wipe`, slides nothing).
          thread.setAttribute("data-turn-end-fold", "fade");
          thread.style.cssText = "position: relative; height: 2000px; margin: 0; padding: 0; border: 0";
          document.body.append(thread);
          const draw = (id: string, kind: string, top: number, height: number, extra = "") => {
            const node = document.createElement("div");
            node.className = `acpmux-row acpmux-${kind} ${extra}`.trim();
            node.dataset.rowId = id;
            node.setAttribute("aria-posinset", String(thread.children.length + 1));
            node.style.cssText = `position: absolute; left: 0; right: 0; top: ${top}px; height: ${height}px`;
            node.textContent = "Lorem ipsum dolor sit amet";
            thread.append(node);
            return node;
          };
          // Before the swap: the kept row where it was drawn, and the running turn's line (kept too, so
          // nothing leaves a copy and the fold has no exit lead: the move starts on its first frame).
          draw("worked-u", "worked", stage.keptWas, 34);
          draw(LIVE_THINKING, "thinking", stage.keptWas + 34, 22);
          if (stage.keptBelowWas !== undefined) draw("worked-d", "worked", stage.keptBelowWas, 34);
          const row = (id: string, kind: string) => ({ id, version: 1, at: 1, kind });
          const capture = captureTurnEnd(
            thread,
            thread,
            [
              row("worked-u", "worked"),
              row(LIVE_THINKING, "thinking"),
              ...(stage.keptBelowWas === undefined ? [] : [row("worked-d", "worked")]),
            ],
            "chat",
          );
          if (!capture) throw new Error("captureTurnEnd gave no capture");
          thread.replaceChildren();
          const kept = draw("worked-u", "worked", stage.keptTop, 34);
          const reply = draw("answer-new", "assistant", stage.replyTop, 120, stage.replyClass);
          const keptBelow =
            stage.keptBelowTop === undefined ? undefined : draw("worked-d", "worked", stage.keptBelowTop, 34);
          const ms = Number.parseFloat(getComputedStyle(thread).getPropertyValue("--cmux-motion-settle")) || 180;
          const fold = playTurnEnd(thread, capture, "chat", thread);
          if (!fold) throw new Error("playTurnEnd played nothing");
          const holds = () =>
            reply
              .getAnimations()
              .map((animation: Animation) => Number(animation.effect?.getTiming().delay ?? 0))
              .filter((delay: number) => Number.isFinite(delay));
          const seen: number[] = [...holds()];
          const frames: Frame[] = [];
          let relayoutAt = -1;
          await new Promise<void>((resolve, reject) => {
            let first: number | undefined;
            const step = (time: number) => {
              first ??= time;
              const box = (node: HTMLElement) => {
                const rect = node.getBoundingClientRect();
                return { top: rect.top, bottom: rect.bottom };
              };
              frames.push({
                t: time - first,
                reply: { ...box(reply), opacity: Number.parseFloat(getComputedStyle(reply).opacity) },
                kept: box(kept),
                ...(keptBelow && { keptBelow: box(keptBelow) }),
                folding: thread.hasAttribute(TURN_END_ATTR),
                animations: reply.getAnimations().length,
              });
              if (frames.length - 1 === stage.relayoutFrame && stage.relayoutTop !== undefined) {
                // The relayout: the reply's row placed again (its inline top), which the fold's
                // MutationObserver reads before this frame paints.
                reply.style.top = `${stage.relayoutTop}px`;
                relayoutAt = frames.length;
                queueMicrotask(() => queueMicrotask(() => seen.push(...holds())));
              }
              const last = frames.at(-1)!;
              const done = !last.folding && last.reply.opacity === 1 && document.getAnimations().length === 0;
              if (done && frames.length > relayoutAt + 3) return resolve();
              if (frames.length > 600) return reject(new Error("the fold never settled"));
              // raf-read: the fade is the behavior; each frame's ink is read as that frame is drawn.
              requestAnimationFrame(step);
            };
            // raf-read: every frame of the fade (above).
            requestAnimationFrame(step);
          });
          settleTurnEnd(thread, fold);
          return { frames, relayoutAt, ms, holds: seen };
        },
        { stage, fold: `${base}turnEndFold.ts`, turns: `${base}turns.ts` },
      );
    } finally {
      await page.close();
    }
  };

  const overlap = (a: Box, b: Box) => Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);

  test("F1: a relayout that makes a kept row cross the reply holds the reply's ink again", async () => {
    // At the first pass the kept row slides 520 -> 100 and the reply sits at 600: nothing crosses it,
    // so its fade starts at once. Two frames in, the reply is placed at 334, across that slide.
    const result = await run({ keptWas: 520, keptTop: 100, replyTop: 600, relayoutFrame: 2, relayoutTop: 334 });
    const after = result.frames.slice(result.relayoutAt);
    const crossed = after.filter((frame) => overlap(frame.kept, frame.reply) > 0.5);
    const inkWhileCrossed = Math.max(0, ...crossed.map((frame) => frame.reply.opacity));
    const final = result.frames.at(-1)!;
    const offTop = Math.max(...after.map((frame) => Math.abs(frame.reply.top - final.reply.top)));
    console.log(
      `reply-settle-frames F1 ${JSON.stringify({ frames: result.frames.length, crossedFrames: crossed.length, inkWhileCrossed, offTop, holds: result.holds, ms: result.ms })}`,
    );
    expect(crossed.length).toBeGreaterThan(0);
    expect(inkWhileCrossed).toBeLessThanOrEqual(0.05);
    expect(final.reply.opacity).toBe(1);
    expect(final.reply.top).toBe(334);
    expect(offTop).toBeLessThanOrEqual(1);
  });

  test("F2: a hold near the move's length fades in full, with no backstop snap", async () => {
    // The kept row slides 520 -> 300 through the reply's place (334..454) from the start: the reply
    // holds most of the move, then fades over the move's length past it.
    const result = await run({ keptWas: 520, keptTop: 300, replyTop: 334, relayoutFrame: -1 });
    let worstStep = -Infinity;
    let worstExcess = -Infinity;
    for (let index = 1; index < result.frames.length; index += 1) {
      const [was, now] = [result.frames[index - 1]!, result.frames[index]!];
      const rise = now.reply.opacity - was.reply.opacity;
      worstStep = Math.max(worstStep, rise);
      worstExcess = Math.max(worstExcess, rise - ((now.t - was.t) / result.ms + 0.15));
    }
    const unmarked = result.frames.filter((frame) => frame.reply.opacity < 1 && !frame.folding);
    const crossed = result.frames.filter((frame) => overlap(frame.kept, frame.reply) > 0.5);
    console.log(
      `reply-settle-frames F2 ${JSON.stringify({ frames: result.frames.length, worstStep, worstExcess, unmarked: unmarked.length, inkWhileCrossed: Math.max(0, ...crossed.map((frame) => frame.reply.opacity)), holds: result.holds, ms: result.ms })}`,
    );
    expect(worstExcess).toBeLessThanOrEqual(0);
    expect(result.frames.at(-1)!.reply.opacity).toBe(1);
    expect(unmarked.length).toBe(0);
  });

  test("F3: a reply with its own entrance that nothing crosses gets no fade from the fold", async () => {
    // The kept row slides 280 -> 300, above the reply (334..454) all the way.
    const result = await run({
      keptWas: 280,
      keptTop: 300,
      replyTop: 334,
      replyClass: "acpmux-row--message-enter",
      relayoutFrame: -1,
    });
    const animated = result.frames.filter((frame) => frame.animations > 0);
    const faint = result.frames.filter((frame) => frame.reply.opacity < 1);
    console.log(
      `reply-settle-frames F3 ${JSON.stringify({ frames: result.frames.length, animated: animated.length, faint: faint.length, holds: result.holds })}`,
    );
    expect(result.frames.some((frame) => frame.folding)).toBe(true);
    expect(animated.length).toBe(0);
    expect(faint.length).toBe(0);
  });

  for (const replyClass of ["acpmux-row--enter", "acpmux-row--message-enter"])
    test(`F4: ${replyClass} between retained rows stays clear while either row crosses`, async () => {
      // The arriving reply is between two rows retained by the turn-end swap. The upper retained row
      // moves 520 -> 300 through the reply's place while the lower retained row stays below it. The
      // reply's own entrance must hold at zero ink for every crossing frame, then remain fully visible.
      const result = await run({
        keptWas: 520,
        keptTop: 300,
        keptBelowWas: 600,
        keptBelowTop: 454,
        replyTop: 334,
        replyClass,
        relayoutFrame: -1,
      });
      const crossed = result.frames.filter((frame) => {
        const upper = overlap(frame.kept, frame.reply) > 0.5;
        const lower = frame.keptBelow !== undefined && overlap(frame.keptBelow, frame.reply) > 0.5;
        return upper || lower;
      });
      const inkWhileCrossed = Math.max(0, ...crossed.map((frame) => frame.reply.opacity));
      const final = result.frames.at(-1)!;
      console.log(
        `reply-settle-frames F4 ${JSON.stringify({ frames: result.frames.length, crossedFrames: crossed.length, inkWhileCrossed, finalOpacity: final.reply.opacity })}`,
      );
      expect(crossed.length).toBeGreaterThan(0);
      expect(inkWhileCrossed).toBeLessThanOrEqual(0.05);
      expect(final.reply.opacity).toBe(1);
    });
});
