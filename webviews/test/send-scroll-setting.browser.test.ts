// cmux-web-test-timeout: 240
// Real Chromium exercise of VirtualTranscript's send path. Set CMUX_SEND_SCROLL_CAPTURE_DIR on
// the hosted run to retain before/after images from this same harness.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("send-scroll-setting.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-scroll-setting: skipping (run `bunx playwright install chromium`)");
    describe.skip("send scroll setting", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const captureDir = process.env.CMUX_SEND_SCROLL_CAPTURE_DIR;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/send-scroll-setting.html");
    browser = await chromium.launch({ headless: true });
    if (captureDir) await mkdir(captureDir, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string): Row => ({ id, kind, text, version: 1, at: 1 });
  const paragraph = (index: number) =>
    `History ${index}: the keeper climbed to the gallery and wiped the salt from the lantern glass, ` +
    "then watched the light sweep the water before going back down.";
  const history = () =>
    Array.from({ length: 26 }, (_, index) => [
      row(`turn-${index}-user`, "user", `Prompt ${index}`),
      row(`turn-${index}-answer`, "assistant", paragraph(index)),
    ]).flat();
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((next) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(next), rows);
  const send = (page: Page) => page.evaluate(() => (window as unknown as { __send(): void }).__send());
  const frames = (page: Page, count = 3) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);
  /// `arm`: the follow-motion arm (followMotion.experiment.ts); the product's `send` by default.
  const open = async (arm?: "send" | "blocks") => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 900, height: 560 } });
    if (arm)
      await page.addInitScript((arm) => Object.assign(window, { cmuxExperiments: { "follow-motion": arm } }), arm);
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/send-scroll-setting.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };
  const capture = async (page: Page, name: string) => {
    if (!captureDir) return;
    const file = path.join(captureDir, `${name}.png`);
    await page.screenshot({ path: file });
    console.log(`SEND_SCROLL_CAPTURE=${file}`);
  };
  const scrollMetrics = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return { top: node.scrollTop, fromEnd: node.scrollHeight - node.clientHeight - node.scrollTop };
    });
  const scrollUp = async (page: Page) => {
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.scrollTop = Math.max(0, node.scrollHeight / 2);
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await frames(page, 4);
    await page.waitForFunction(
      () => (window as unknown as { __sendState(): { following: boolean } }).__sendState().following === false,
    );
  };
  const addReply = (rows: Row[], streaming = false) => [
    ...rows,
    row("sent-prompt", "user", "Keep this visible while I read above."),
    { ...row("sent-reply", "assistant", "The reply arrived below your reading position."), streaming },
  ];

  test("off preserves an up-scroll anchor while the prompt and reply arrive below", async () => {
    const page = await open();
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(false),
    );
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    const before = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>('[data-row-id="turn-13-answer"]')!;
      (node as HTMLElement & { sendScrollMarker?: object }).sendScrollMarker = {};
      return {
        top: node.getBoundingClientRect().top,
        scroll: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop,
      };
    });
    await capture(page, "off-before");
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 5);
    await show(page, addReply(rows));
    await frames(page, 6);
    const after = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>('[data-row-id="turn-13-answer"]')! as HTMLElement & {
        sendScrollMarker?: object;
      };
      return {
        top: node.getBoundingClientRect().top,
        marker: Boolean(node.sendScrollMarker),
        jump: document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)")?.hasAttribute("data-shown") ?? false,
        state: (window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState(),
      };
    });
    await capture(page, "off-after");
    expect(Math.abs(after.top - before.top)).toBeLessThanOrEqual(1);
    expect(after.marker).toBe(true);
    expect(after.state).toEqual({ following: false, sends: 0 });
    expect(after.jump).toBe(true);
    await page.close();
  });

  test("on moves an up-scrolled reader to the new reply", async () => {
    const page = await open();
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    await capture(page, "on-before");
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(true),
    );
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 8);
    await show(page, addReply(rows));
    await frames(page, 14);
    // The view glides there on Jump to latest's ride (at most 400 ms), not in one frame.
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
    const metrics = await scrollMetrics(page);
    const state = await page.evaluate(() =>
      (window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState(),
    );
    await capture(page, "on-after");
    expect(metrics.fromEnd).toBeLessThanOrEqual(2);
    expect(state).toEqual({ following: true, sends: 1 });
    await page.close();
  });

  test("off still follows a reply when the reader is already at the bottom", async () => {
    const page = await open();
    const rows = history();
    await page.evaluate(() =>
      (window as unknown as { __setScrollToBottomOnSend(enabled: boolean): void }).__setScrollToBottomOnSend(false),
    );
    await show(page, rows);
    await frames(page, 6);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await send(page);
    await show(page, addReply(rows, true));
    await frames(page, 8);
    await show(page, addReply(rows));
    await frames(page, 14);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await page.locator('[data-row-id="sent-reply"]').waitFor({ state: "visible" });
    await page.close();
  });

  // Leo, 2026-11-04: "when we SEND prompts in at various states (from empty, from partially empty,
  // from full, from full at the bottom) we have SMOOTH non-jolty ... state transitions".
  const sendWith = (page: Page, rows: Row[]) =>
    page.evaluate((next) => (window as unknown as { __sendWith(rows: unknown): void }).__sendWith(next), rows);
  /// One sample per painted frame for `count` frames, from the frame after the call: the sent
  /// prompt's top on screen (`prompt`) or the scroller's offset (`offset`).
  const sampleFrames = (page: Page, count: number, read: "prompt" | "offset") =>
    page.evaluate(
      async ([n, what]) => {
        const values: number[] = [];
        const probe = () => {
          if (what === "offset") return document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop;
          const row = document.querySelector('[data-row-id="sent-prompt"]');
          return row ? row.getBoundingClientRect().top : Number.NaN;
        };
        while (values.length < n) {
          await window.cmuxPaintFrame();
          values.push(probe());
        }
        return values;
      },
      [count, read] as const,
    );

  // The slim arm (the product's): the sent prompt is in place in the frame after the send and nothing
  // settles after it (Leo, 2026-11-09: "the scroll up is extremely sluggish, and it doesn't look great
  // when it's so slow and it lags so much. The whole point is to have, like, fast stuff, like so it
  // feels responsive, right?").
  test("a send from the latest row puts the prompt in place at once, and nothing moves after", async () => {
    const page = await open();
    const rows = history();
    await show(page, rows);
    await frames(page, 6);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await sendWith(page, addReply(rows, true));
    const tops = await sampleFrames(page, 24, "prompt");
    const drawn = tops.filter((top) => Number.isFinite(top));
    const rest = drawn.at(-1)!;
    // Drawn where it rests within two painted frames of the send, and still there in every frame after.
    expect(tops.slice(0, 2).some((top) => Number.isFinite(top) && Math.abs(top - rest) <= 1)).toBe(true);
    const placed = tops.findIndex((top) => Number.isFinite(top) && Math.abs(top - rest) <= 1);
    for (const top of tops.slice(placed)) expect(Math.abs(top - rest)).toBeLessThanOrEqual(1);
    await frames(page, 4);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await page.close();
  });

  test("a send from the latest row lifts the thread on one glide (blocks arm): the prompt rises into place", async () => {
    const page = await open("blocks");
    const rows = history();
    await show(page, rows);
    await frames(page, 6);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await sendWith(page, addReply(rows, true));
    const tops = await sampleFrames(page, 24, "prompt");
    const drawn = tops.filter((top) => Number.isFinite(top));
    const rest = drawn.at(-1)!;
    // The prompt starts below where it rests (behind the composer it left) and only ever moves up.
    expect(drawn[0]! - rest).toBeGreaterThan(8);
    for (let index = 1; index < drawn.length; index += 1)
      expect(drawn[index]!).toBeLessThanOrEqual(drawn[index - 1]! + 0.5);
    // In between: some frame shows it part of the way, never one cut from start to rest.
    expect(drawn.some((top) => top < drawn[0]! - 1 && top > rest + 1)).toBe(true);
    await frames(page, 4);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    const state = await page.evaluate(() =>
      (window as unknown as { __sendState(): { following: boolean; sends: number } }).__sendState(),
    );
    expect(state.following).toBe(true);
    await page.close();
  });

  test("a send that makes a short chat overflow lifts the thread on one glide (blocks arm)", async () => {
    // The longest tail that still fits the view, found on a page of its own: once a tail overflows,
    // the chat has opened, and the send below must come into one that has not.
    let rows = history().slice(0, 2);
    const probe = await open();
    for (let turns = 1; turns <= 26; turns += 1) {
      const next = history().slice(0, turns * 2);
      await show(probe, next);
      await frames(probe, 2);
      const metrics = await probe.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return { height: node.scrollHeight, view: node.clientHeight };
      });
      if (metrics.height > metrics.view) break;
      rows = next;
    }
    await probe.close();
    const page = await open("blocks");
    await show(page, rows);
    await frames(page, 4);
    expect((await scrollMetrics(page)).top).toBe(0);
    // The prompt and a long reply: more than the room left, so the send makes the chat overflow.
    const long = [1, 2, 3, 4].map(paragraph).join(" ");
    await sendWith(page, [
      ...rows,
      row("sent-prompt", "user", "Keep this visible while I read above."),
      { ...row("sent-reply", "assistant", long), streaming: true },
    ]);
    const tops = await sampleFrames(page, 24, "prompt");
    const drawn = tops.filter((top) => Number.isFinite(top));
    const rest = drawn.at(-1)!;
    // The prompt starts below where it rests and only moves up, with frames in between.
    expect(drawn[0]! - rest).toBeGreaterThan(8);
    for (let index = 1; index < drawn.length; index += 1)
      expect(drawn[index]!).toBeLessThanOrEqual(drawn[index - 1]! + 0.5);
    expect(drawn.some((top) => top < drawn[0]! - 1 && top > rest + 1)).toBe(true);
    await frames(page, 4);
    expect((await scrollMetrics(page)).fromEnd).toBeLessThanOrEqual(2);
    await page.close();
  });

  // The slim arm (the product's): the ride to the latest message is the capped send step, 120 ms at
  // most, and still never backs up (Leo, 2026-11-09: "the scroll up is extremely sluggish ... if I
  // send in a prompt like this and it just lags, it's not a good look").
  test("a send while scrolled up rides down to the latest message within 150 ms, never backing up", async () => {
    const page = await open();
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    const start = (await scrollMetrics(page)).top;
    const sent = await page.evaluate(() => performance.now());
    await sendWith(page, addReply(rows, true));
    // Each painted frame's offset and time, until the view is at the latest message (60 frames at most).
    const ride = await page.evaluate(async () => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const out: { at: number; top: number; end: boolean }[] = [];
      while (out.length < 60) {
        await window.cmuxPaintFrame();
        const end = node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
        out.push({ at: performance.now(), top: node.scrollTop, end });
        if (end) break;
      }
      return out;
    });
    for (let index = 1; index < ride.length; index += 1)
      expect(ride[index]!.top).toBeGreaterThanOrEqual(ride[index - 1]!.top - 0.5);
    expect(ride.at(-1)!.end).toBe(true);
    expect(ride.at(-1)!.top).toBeGreaterThan(start);
    // At the latest message on the send's clock: 150 ms, and two frames of a busy runner.
    expect(ride.at(-1)!.at - sent).toBeLessThan(150 + 2 * 50);
    await page.locator('[data-row-id="sent-reply"]').waitFor({ state: "visible" });
    await page.close();
  });

  test("a send while scrolled up glides down to the latest message instead of cutting there (blocks arm)", async () => {
    const page = await open("blocks");
    const rows = history();
    await show(page, rows);
    await frames(page, 5);
    await scrollUp(page);
    const start = (await scrollMetrics(page)).top;
    await sendWith(page, addReply(rows, true));
    const offsets = await sampleFrames(page, 40, "offset");
    const end = offsets.at(-1)!;
    expect(end).toBeGreaterThan(start);
    // Never back up, and several frames between where the reader was and the latest message.
    for (let index = 1; index < offsets.length; index += 1)
      expect(offsets[index]!).toBeGreaterThanOrEqual(offsets[index - 1]! - 0.5);
    expect(offsets.filter((top) => top > start + 1 && top < end - 1).length).toBeGreaterThanOrEqual(3);
    await page.waitForFunction(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
    await page.locator('[data-row-id="sent-reply"]').waitFor({ state: "visible" });
    await page.close();
  });
});
