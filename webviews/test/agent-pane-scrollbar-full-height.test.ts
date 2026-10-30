// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript runs the pane's full height and scrolls under the composer, as the Claude and
// Codex apps do (Leo 2026-10-19): its scrollbar's track reaches the pane's bottom corner instead of
// stopping above the composer. Scrolled to the end, the last row still sits fully above the
// composer's card, and a composer that grows or shrinks (a prompt of several lines) keeps a
// followed view at its end on every painted frame, with nothing under the card and the scrollbar
// as it was (the rows follow the card, the scroll offset and heights stay). Scrolled up, a
// composer that grows or shrinks leaves the view as it was: its offset, its height and so its
// scrollbar, and the rows being read (Leo 2026-10-20: a newline in the composer made the
// transcript's scrollbar jump). Back at the end after it grew, by the wheel or by Jump to latest
// (which scrolls there smoothly), the last row is above the card on every frame.
//
// Before: the transcript ended at the top of the bottom stack, so its track ended about a
// composer's height (111px here, 211px with a five-line prompt) above the pane's bottom.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { installPaintedFrames } from "./support/paintedFrames";
import { papercutPane } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-scrollbar-full-height.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-scrollbar-full-height: skipping (run `bunx playwright install chromium`)");
    describe.skip("scrollbar full height", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000f011";
  const START = Date.UTC(2026, 9, 19, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const steps: [string, string, Record<string, unknown>][] = [];
  for (let n = 1; n <= 40; n++)
    steps.push(
      ["mux", "user_message", { text: `Question ${n}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        update({
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: `Answer ${n}: the checks on the merged head are green.` },
        }),
      ],
      ["mux", "turn_result", { status: "completed" }],
    );
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Scrollbar",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 40,
    updatedAt: START,
    lastSeq: events.length,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 60_000 });
    // Rows place by their drawn heights a frame after they mount, and rise in (cv-enter): wait out
    // the finite animations, then for the offset and the card to hold.
    await page.evaluate(async () => {
      for (;;) {
        const moving = document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
        if (moving.length === 0) break;
        await Promise.allSettled(moving.map((animation) => animation.finished));
      }
    });
    await untilStill(page);
    return page;
  }

  /// Resolves after `count` painted frames.
  const painted = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let left = count; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  /// Resolves once the scroller's offset has held for 12 painted frames (a wheel's scroll can run
  /// over several frames).
  const restingScroll = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          let last = scroller.scrollTop;
          let still = 0;
          window.cmuxAfterPaint(() => {
            still = scroller.scrollTop === last ? still + 1 : 0;
            last = scroller.scrollTop;
            if (still < 12) return true;
            done();
            return false;
          });
        }),
    );
  /// The pane, the scroller (whose height is its scrollbar's track) and the composer's card, and
  /// how far the last row's bottom sits above the card's top (negative: under the card).
  const measure = (page: Page) =>
    page.evaluate(() => {
      const main = document.querySelector(".acpmux-main")!.getBoundingClientRect();
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const answer = rows.find((row) => row.textContent?.includes("Answer 40:"));
      return {
        trackGap: Math.round(main.bottom - view.bottom),
        rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
        answerAboveCard: answer ? Math.round(card.top - answer.getBoundingClientRect().bottom) : null,
        // The chat has no older pages, so the transcript's last row is the last of the set.
        lastIsLatest: last.getAttribute("aria-posinset") === last.getAttribute("aria-setsize"),
        fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
        cardHeight: Math.round(card.height),
        bar: Math.round(view.right - (view.left + scroller.clientWidth)),
        right: view.right,
        bottom: Math.min(view.bottom, main.bottom),
      };
    });

  test("the transcript's scrollbar runs to the pane's bottom, and its end sits above the composer", async () => {
    const page = await open();
    const drawn = await measure(page);
    console.log(`scrollbar track bottom to pane bottom: ${drawn.trackGap}px`);
    // The scroller, and so its scrollbar's track, reaches the pane's bottom edge.
    expect(Math.abs(drawn.trackGap)).toBeLessThanOrEqual(2);
    // Opened at its latest message: the view is at the end, the last row whole above the card.
    expect({ fromEnd: drawn.fromEnd, lastIsLatest: drawn.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    expect(drawn.rowAboveCard).toBeGreaterThanOrEqual(-1);
    expect(drawn.answerAboveCard).toBeGreaterThanOrEqual(0);

    // The scrollbar paints under the composer too: at the end its thumb rests at the track's foot,
    // so the pixel there differs from the page beside it (a mask over that band would hide both).
    if (drawn.bar > 0) {
      const shot = await page.screenshot({
        clip: { x: drawn.right - drawn.bar - 12, y: drawn.bottom - 12, width: drawn.bar + 12, height: 8 },
      });
      const png = PNG.sync.read(shot);
      const pixel = (x: number) => {
        const at = (4 * png.width + x) * 4;
        return [png.data[at], png.data[at + 1], png.data[at + 2]].join(",");
      };
      expect({ thumbDrawn: pixel(png.width - Math.ceil(drawn.bar / 2)) !== pixel(2) }).toEqual({ thumbDrawn: true });
    }
    await page.close();
  });

  test("a composer that grows keeps the followed end above it on every frame", async () => {
    const page = await open();
    const before = await measure(page);
    await page.locator(".acpmux-md").click();
    await page.evaluate(() => {
      const frames: { rowAboveCard: number; fromEnd: number }[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = rows.reduce((a, b) =>
          Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
        );
        frames.push({
          rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
        });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    });
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    await untilStill(page);
    const frames = await page.evaluate(() => {
      const holder = window as unknown as { __frames?: { rowAboveCard: number; fromEnd: number }[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    const after = await measure(page);
    // The card grew by the lines typed.
    expect(after.cardHeight - before.cardHeight).toBeGreaterThan(60);
    // No painted frame put the last row under the card or left the view off its end.
    expect(frames.length).toBeGreaterThan(5);
    expect(frames.filter((frame) => frame.rowAboveCard < -1 || frame.fromEnd > 1)).toEqual([]);
    // It rests where it did, just above the grown card.
    expect(Math.abs(after.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
    expect(Math.abs(after.trackGap)).toBeLessThanOrEqual(2);
    await page.close();
  });

  test("a composer that grows leaves a reader scrolled up where they were, scrollbar and all, on every frame", async () => {
    const page = await open();
    const before = await measure(page);
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + 120);
    await page.mouse.wheel(0, -900);
    await untilStill(page);
    await page.locator(".acpmux-md").click();
    const scroller = () =>
      page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return { top: node.scrollTop, height: node.scrollHeight, view: node.clientHeight };
      });
    const start = await scroller();
    expect(start.top).toBeGreaterThan(0);
    expect(start.height - start.top - start.view).toBeGreaterThan(400);
    await page.evaluate(() => {
      const frames: { top: number; height: number; view: number }[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        frames.push({ top: node.scrollTop, height: node.scrollHeight, view: node.clientHeight });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    });
    // Lines from Shift-Return, then a line that wraps.
    for (let line = 1; line <= 4; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    await page.keyboard.type("and a last line long enough to wrap in the composer's card ".repeat(3));
    await untilStill(page);
    const frames = await page.evaluate(() => {
      const holder = window as unknown as { __frames?: { top: number; height: number; view: number }[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    const grown = await measure(page);
    expect(grown.cardHeight - before.cardHeight).toBeGreaterThan(80);
    // No painted frame moved the offset, or changed the scroller's height or its content's, which
    // move and resize the scrollbar's thumb.
    expect(frames.length).toBeGreaterThan(5);
    const moved = (a: number, b: number) => Math.abs(a - b) > 0.5;
    expect(
      frames.filter(
        (frame) => moved(frame.top, start.top) || moved(frame.height, start.height) || moved(frame.view, start.view),
      ),
    ).toEqual([]);
    // Back at the end, the latest row sits above the grown card.
    await page.mouse.move(view.x + view.width / 2, view.y + 120);
    for (let step = 0; step < 4; step++) await page.mouse.wheel(0, 2000);
    await untilStill(page);
    const end = await measure(page);
    expect({ fromEnd: end.fromEnd, lastIsLatest: end.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    expect(end.rowAboveCard).toBeGreaterThanOrEqual(-1);
    expect(Math.abs(end.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
    await page.close();
  });

  // Read up the chat, growing the composer by lines and shrinking it back moves neither the
  // reader's offset nor the rows they read, on any painted frame.
  test("a composer that grows and shrinks leaves the rows a reader reads where they were on every frame", async () => {
    const page = await open();
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + view.height / 2);
    await page.mouse.wheel(0, -900);
    await untilStill(page);
    await page.locator(".acpmux-md").click();
    // Well up from the end, so the view is a reader's, not a follower's.
    expect((await measure(page)).fromEnd).toBeGreaterThan(100);
    // The row in the middle of the view, and the offset.
    const start = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const middle = (view.top + view.bottom) / 2;
      const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => {
        const box = row.getBoundingClientRect();
        return box.top <= middle && box.bottom >= middle;
      })!;
      return { row: row.getAttribute("aria-posinset")!, top: scroller.scrollTop };
    });
    await page.evaluate((posinset) => {
      const frames: { top: number; rowTop: number; cardHeight: number }[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const row = scroller.querySelector(`.acpmux-row[aria-posinset="${posinset}"]`)!;
        frames.push({
          top: scroller.scrollTop,
          rowTop: row.getBoundingClientRect().top,
          cardHeight: document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
        });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    }, start.row);
    const restHeight = await page.evaluate(
      () => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
    );
    // The first frame is sampled at rest, before the first key.
    await page.waitForFunction(() => ((window as unknown as { __frames?: unknown[] }).__frames?.length ?? 0) > 0);
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    // And back: the lines removed one at a time, then the rest of the draft at once.
    for (let line = 1; line <= 3; line++) {
      await page.keyboard.press("Backspace");
      await page.keyboard.down("Shift");
      await page.keyboard.press("Home");
      await page.keyboard.up("Shift");
      await page.keyboard.press("Backspace");
      await painted(page, 3);
    }
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    // Sampled until the card is back to its height before typing (a slow runner can paint the
    // last shrink late), then a few frames more.
    await page.waitForFunction(
      (rest) => Math.abs(document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height - rest) <= 1,
      restHeight,
    );
    await painted(page, 10);
    const frames = await page.evaluate(() => {
      const holder = window as unknown as { __frames?: { top: number; rowTop: number; cardHeight: number }[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    expect(frames.length).toBeGreaterThan(5);
    // The card grew by the lines typed and shrank back.
    const heights = frames.map((frame) => frame.cardHeight);
    expect(Math.max(...heights) - heights[0]!).toBeGreaterThan(60);
    expect(Math.abs(heights.at(-1)! - heights[0]!)).toBeLessThanOrEqual(1);
    // Neither the offset nor the row being read moved on any frame.
    const { top, rowTop } = frames[0]!;
    expect(Math.abs(top - start.top)).toBeLessThanOrEqual(0.5);
    expect(frames.filter((frame) => Math.abs(frame.top - top) > 0.5 || Math.abs(frame.rowTop - rowTop) > 0.5)).toEqual(
      [],
    );
    await page.close();
  });

  // The same for a reader at the latest row: growing the composer line by line and shrinking it
  // back, every painted frame keeps the view at its end with the last row above the card.
  test("a composer that grows and shrinks keeps a followed view at its end on every frame", async () => {
    const page = await open();
    await page.locator(".acpmux-md").click();
    await page.evaluate(() => {
      const frames: { rowAboveCard: number; fromEnd: number; cardHeight: number }[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = rows.reduce((a, b) =>
          Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
        );
        frames.push({
          rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
          cardHeight: Math.round(card.height),
        });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    });
    const restHeight = await page.evaluate(
      () => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
    );
    // The first frame is sampled at rest, before the first key.
    await page.waitForFunction(() => ((window as unknown as { __frames?: unknown[] }).__frames?.length ?? 0) > 0);
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    for (let line = 1; line <= 3; line++) {
      await page.keyboard.press("Backspace");
      await page.keyboard.down("Shift");
      await page.keyboard.press("Home");
      await page.keyboard.up("Shift");
      await page.keyboard.press("Backspace");
      await painted(page, 3);
    }
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    // Sampled until the card is back to its height before typing (a slow runner can paint the
    // last shrink late), then a few frames more.
    await page.waitForFunction(
      (rest) => Math.abs(document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height - rest) <= 1,
      restHeight,
    );
    await painted(page, 10);
    const frames = await page.evaluate(() => {
      const holder = window as unknown as {
        __frames?: { rowAboveCard: number; fromEnd: number; cardHeight: number }[];
      };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    expect(frames.length).toBeGreaterThan(5);
    // The card grew by the lines typed and shrank back.
    const heights = frames.map((frame) => frame.cardHeight);
    expect(Math.max(...heights) - heights[0]!).toBeGreaterThan(60);
    expect(Math.abs(heights.at(-1)! - heights[0]!)).toBeLessThanOrEqual(1);
    // No frame lands late (the last row under the card, or the view off its end) ...
    expect(frames.filter((frame) => frame.rowAboveCard < -1 || frame.fromEnd > 1)).toEqual([]);
    // ... or overshoots: the last row sits where it rests above the card on every frame, so the
    // view moves by exactly the card's growth in the frame the card grows.
    const rest = frames.at(-1)!.rowAboveCard;
    expect(frames.filter((frame) => Math.abs(frame.rowAboveCard - rest) > 2)).toEqual([]);
    await page.close();
  });

  type Frame = { t: number; top: number; fromEnd: number; rowAboveCard: number };
  /// Samples the offset, the distance from the end and the last row's place over the card after
  /// every painted frame (a task queued from its animation frame), until `stopFrames`.
  const startFrames = (page: Page) =>
    page.evaluate(() => {
      const frames: { t: number; top: number; fromEnd: number; rowAboveCard: number }[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = (t: number) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = rows.reduce((a, b) =>
          Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
        );
        frames.push({
          t,
          top: scroller.scrollTop,
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
          rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
        });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint((t) => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample(t);
      });
    });
  const stopFrames = (page: Page): Promise<Frame[]> =>
    page.evaluate(() => {
      const holder = window as unknown as { __frames?: Frame[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });

  /// Resolves once the offset and the card's height have held for 200ms of painted frames, so a
  /// read never lands mid-glide or before the last line's growth is painted.
  const untilStill = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const card = document.querySelector(".acpmux-composer-box")!;
          const read = () => `${scroller.scrollTop}:${card.getBoundingClientRect().height}`;
          let last = read();
          let since = performance.now();
          window.cmuxAfterPaint((now) => {
            const seen = read();
            if (seen !== last) [last, since] = [seen, now];
            if (now - since < 200) return true;
            resolve();
            return false;
          });
        }),
    );

  /// Scrolls well up from the end, then grows the composer by five lines while there.
  async function growWhileScrolledUp(page: Page) {
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + 120);
    await page.mouse.wheel(0, -900);
    await untilStill(page);
    await page.locator(".acpmux-md").click();
    expect((await measure(page)).fromEnd).toBeGreaterThan(400);
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
    }
    await untilStill(page);
    return view;
  }

  // Review of #23097: the room under the last row stays as it was while the reader is scrolled up,
  // so the scroller ended short of the grown card. Scrolling back to the end must never show the
  // last row under the card, not for one frame.
  test("scrolled back to the end after the composer grew, the last row is never under the card", async () => {
    const page = await open();
    const before = await measure(page);
    const view = await growWhileScrolledUp(page);
    await page.mouse.move(view.x + view.width / 2, view.y + 120);
    await startFrames(page);
    for (let step = 0; step < 12; step++) {
      await page.mouse.wheel(0, 150);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await untilStill(page);
    const frames = await stopFrames(page);
    const end = await measure(page);
    expect({ fromEnd: end.fromEnd, lastIsLatest: end.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    expect(end.cardHeight - before.cardHeight).toBeGreaterThan(60);
    // At the end on every frame it reached it, the last row sits above the card.
    expect(frames.filter((frame) => frame.fromEnd <= 1).length).toBeGreaterThan(0);
    expect(frames.filter((frame) => frame.fromEnd <= 1 && frame.rowAboveCard < -1)).toEqual([]);
    expect(Math.abs(end.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
    await page.close();
  });

  // Review of #23097: Jump to latest after the composer grew while scrolled up snapped to the end
  // (following again gave the room back, and a followed view's room moves its offset at once).
  // It glides there, never backs up or overshoots, and lands with the last row above the card.
  test("Jump to latest after the composer grew glides to the end above the card", async () => {
    const page = await open();
    // The jump glides unless the person asked for reduced motion.
    await page.emulateMedia({ reducedMotion: "no-preference" });
    const before = await measure(page);
    await growWhileScrolledUp(page);
    const start = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
    await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
    await startFrames(page);
    await page.locator(".acpmux-jump-latest").click();
    await page.waitForFunction(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 1;
    });
    await untilStill(page);
    const frames = await stopFrames(page);
    const end = await measure(page);
    expect({ fromEnd: end.fromEnd, lastIsLatest: end.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    expect(Math.abs(end.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
    // A glide, judged on the frames' own times so a runner that paints every 100ms reads the same
    // glide as one at 60Hz: it takes time and shows on the way, no frame covers more than half the
    // distance unless it was itself a large part of the glide's time, and it never backs up. A snap
    // arrives in one frame with nothing on the way; a jump mid-glide covers in one short frame what
    // the glide takes several to.
    const landed = frames.at(-1)!.top;
    const distance = landed - start;
    expect(distance).toBeGreaterThan(400);
    // From the last frame still at the start to the first at the end.
    const left = frames.filter((frame) => frame.top - start <= 0.5).at(-1) ?? frames[0]!;
    const arrived = frames.find((frame) => landed - frame.top <= 0.5)!;
    const took = arrived.t - left.t;
    const onTheWay = frames.filter(
      (frame) => frame.top - start > distance * 0.01 && landed - frame.top > distance * 0.01,
    ).length;
    // Chromium runs the glide on the compositor and the page reads it in uneven chunks, so a frame
    // may cover up to four times its share of the glide's time (3.3 at most over 21 glides on a
    // runner painting every 17-133ms; a snap mid-glide in a short frame is still many times more).
    const fast = frames.slice(1).flatMap((frame, index) => {
      const before = frames[index]!;
      const step = frame.top - before.top;
      return step > distance * Math.max(0.5, (4 * (frame.t - before.t)) / took)
        ? [`${Math.round(before.t)}-${Math.round(frame.t)}ms: ${Math.round(step)}px`]
        : [];
    });
    const back = frames.slice(1).filter((frame, index) => frame.top - frames[index]!.top < -1).length;
    expect({ took: took >= 200, onTheWay: onTheWay >= 2, fast, back }).toEqual({
      took: true,
      onTheWay: true,
      fast: [],
      back: 0,
    });
    expect(frames.filter((frame) => frame.fromEnd <= 1 && frame.rowAboveCard < -1)).toEqual([]);
    await page.close();
  });

  // At the latest row, too, a composer that grows and shrinks a line at a time leaves the scroller's
  // offset, its content's height and its own height, and so its scrollbar, as they were on every
  // painted frame; the rows follow the card instead (Leo 2026-10-20: "the new line situations in
  // the composer make the scrollbar jump"). Before: each line grew the room under the last row, so
  // the offset was written to the new end and the overlay thumb showed and shrank on every line.
  test("a composer that grows and shrinks at the latest row keeps the scrollbar still on every frame", async () => {
    const page = await open();
    await page.locator(".acpmux-md").click();
    const before = await measure(page);
    expect({ fromEnd: before.fromEnd, lastIsLatest: before.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    type Frame = {
      top: number;
      height: number;
      view: number;
      rowAboveCard: number;
      fromEnd: number;
      cardHeight: number;
    };
    await page.evaluate(() => {
      const frames: Frame[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = rows.reduce((a, b) =>
          Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
        );
        frames.push({
          top: scroller.scrollTop,
          height: scroller.scrollHeight,
          view: scroller.clientHeight,
          rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
          cardHeight: Math.round(card.height),
        });
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    });
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    // And back: the lines removed one at a time, then the rest of the draft at once.
    for (let line = 1; line <= 3; line++) {
      await page.keyboard.press("Backspace");
      await page.keyboard.down("Shift");
      await page.keyboard.press("Home");
      await page.keyboard.up("Shift");
      await page.keyboard.press("Backspace");
      await painted(page, 3);
    }
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    // The card is back at the height it had before the first line.
    await page.waitForFunction(
      (height) =>
        Math.abs(document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height - height) <= 1,
      before.cardHeight,
    );
    // A few more painted frames at the card's resting height.
    await page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
    const frames = await page.evaluate(() => {
      const holder = window as unknown as { __frames?: Frame[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    expect(frames.length).toBeGreaterThan(5);
    // The card grew by the lines typed and shrank back.
    const heights = frames.map((frame) => frame.cardHeight);
    expect(Math.max(...heights) - before.cardHeight).toBeGreaterThan(60);
    expect(Math.abs(heights.at(-1)! - before.cardHeight)).toBeLessThanOrEqual(1);
    // No painted frame moved the offset or changed the content's height or the scroller's, which
    // show, move and resize the scrollbar's thumb.
    // The first frame and the card before typing are in the report, to read a failure by.
    const first = frames[0]!;
    const moved = (a: number, b: number) => Math.abs(a - b) > 0.5;
    const shape = ({ top, height, view, cardHeight }: Frame) => ({ top, height, view, cardHeight });
    expect({
      before: before.cardHeight,
      first: shape(first),
      moved: frames
        .filter(
          (frame) => moved(frame.top, first.top) || moved(frame.height, first.height) || moved(frame.view, first.view),
        )
        .map(shape),
    }).toEqual({ before: before.cardHeight, first: shape(first), moved: [] });
    // The last row never went under the card, the view stayed at its end, and the row held the spot
    // above the card it rested at before the first line.
    expect(frames.filter((frame) => frame.rowAboveCard < -1 || frame.fromEnd > 1)).toEqual([]);
    expect(frames.filter((frame) => Math.abs(frame.rowAboveCard - before.rowAboveCard) > 2)).toEqual([]);
    await page.close();
  });

  // A reader who scrolls up from the latest row while the composer has grown: the rows the
  // composer's growth drew up become room and offset in the same frame, so a row in view moves only
  // by the wheel's distance, in its direction, on every painted frame. Without that, the rows dropped
  // by the growth (five lines, about 100px) in the frame the view stopped following.
  test("a reader who scrolls up from a grown composer sees the rows move only by the wheel", async () => {
    const page = await open();
    await page.locator(".acpmux-md").click();
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await painted(page, 3);
    }
    await painted(page, 12);
    const grown = await measure(page);
    expect({ fromEnd: grown.fromEnd, lastIsLatest: grown.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
    // A row in the lower half of the view, which stays mounted through the wheel's distance.
    const posinset = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((row) => {
        const box = row.getBoundingClientRect();
        return box.top >= view.top + view.height / 2 && box.bottom <= view.bottom - 120;
      })!;
      return row.getAttribute("aria-posinset")!;
    });
    await page.evaluate((posinset) => {
      const frames: number[] = [];
      (window as unknown as { __frames: typeof frames }).__frames = frames;
      const sample = () => {
        const row = document.querySelector(`.acpmux-scroll .acpmux-row[aria-posinset="${posinset}"]`);
        if (row) frames.push(row.getBoundingClientRect().top);
      };
      // Read after each frame paints, until the frames are taken.
      window.cmuxAfterPaint(() => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return false;
        sample();
      });
    }, posinset);
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + 120);
    await painted(page, 2);
    await page.mouse.wheel(0, -300);
    await restingScroll(page);
    const frames = await page.evaluate(() => {
      const holder = window as unknown as { __frames?: number[] };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      return frames;
    });
    expect(frames.length).toBeGreaterThan(5);
    // The view left the latest row and the row came down the wheel's distance in all ...
    expect((await measure(page)).fromEnd).toBeGreaterThan(100);
    const moved = frames.at(-1)! - frames[0]!;
    expect(Math.round(moved)).toBeGreaterThan(200);
    expect(moved).toBeLessThanOrEqual(301);
    // ... and never up, or down by more than that, on any frame.
    expect(
      frames.flatMap((top, index) =>
        index > 0 && (top < frames[index - 1]! - 0.5 || top - frames[0]! > 301)
          ? [{ index, top, first: frames[0] }]
          : [],
      ),
    ).toEqual([]);
    await page.close();
  });

  // A transcript just taller than its view (Leo's report, its other case): growing the composer at
  // the latest row draws the rows up by no more than the offset holds above the follow deadband, so
  // the reader can still scroll up to the first row while the draft stays.
  test("a transcript about a screen tall keeps its first row in reach while the composer grows", async () => {
    const short = await papercutPane(() => browser!, { turns: 3, running: false });
    try {
      const page = await short.open();
      await installPaintedFrames(page);
      // Size the view so the transcript is 2-3px taller than it: the chat opens at its latest row.
      const fit = await page.evaluate(() => ({
        total: parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height),
        view: document.querySelector<HTMLElement>(".acpmux-scroll")!.clientHeight,
      }));
      await page.setViewportSize({ width: 900, height: 700 - (fit.view - (Math.floor(fit.total) - 2)) });
      await page.waitForFunction(
        (view) => document.querySelector<HTMLElement>(".acpmux-scroll")!.clientHeight < view,
        fit.view,
      );
      await painted(page, 12);
      const opened = await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        return { top: scroller.scrollTop, end: scroller.scrollHeight - scroller.clientHeight };
      });
      expect(opened.end).toBeGreaterThanOrEqual(1);
      expect(opened.end).toBeLessThanOrEqual(4);
      expect(Math.abs(opened.top - opened.end)).toBeLessThanOrEqual(1);
      await page.locator(".acpmux-md").click();
      for (let line = 1; line <= 5; line++) {
        await page.keyboard.type(`Line ${line} of a longer prompt`);
        await page.keyboard.press("Shift+Enter");
        await painted(page, 3);
      }
      await painted(page, 12);
      // The latest row is above the grown card.
      const grown = await measure(page);
      expect(grown.lastIsLatest).toBe(true);
      expect(grown.rowAboveCard).toBeGreaterThanOrEqual(-1);
      // The reader scrolls up: the first row comes into view.
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + 60);
      for (let step = 0; step < 3; step++) {
        await page.mouse.wheel(0, -600);
        await restingScroll(page);
      }
      const first = await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const row = scroller.querySelector<HTMLElement>('.acpmux-row[aria-posinset="1"]');
        return row
          ? {
              belowTop: Math.round(row.getBoundingClientRect().top - scroller.getBoundingClientRect().top),
              top: scroller.scrollTop,
              height: scroller.scrollHeight,
              view: scroller.clientHeight,
            }
          : null;
      });
      expect(first).not.toBeNull();
      expect({ ...first!, inView: first!.belowTop >= 0 }).toEqual({ ...first!, inView: true });
      await page.close();
    } finally {
      await short.close();
    }
  });
});
