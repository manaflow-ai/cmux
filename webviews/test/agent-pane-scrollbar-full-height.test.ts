// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript runs the pane's full height and scrolls under the composer, as the Claude and
// Codex apps do (Leo 2026-10-19): its scrollbar's track reaches the pane's bottom corner instead of
// stopping above the composer. Scrolled to the end, the last row still sits fully above the
// composer's card, and a composer that grows or shrinks (a prompt of several lines) keeps a
// followed view at its end on every painted frame, with nothing under the card. Scrolled up, a
// composer that grows or shrinks leaves the view as it was: its offset, its height and so its
// scrollbar, and the rows being read (Leo 2026-10-20: a newline in the composer made the
// transcript's scrollbar jump).
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
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 60_000 });
    // Rows place by their drawn heights a frame after they mount.
    await page.waitForTimeout(500);
    return page;
  }

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
      // Read after each frame paints (a task queued from its animation frame).
      const tick = () => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return;
        setTimeout(sample, 0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await page.waitForTimeout(60);
    }
    await page.waitForTimeout(300);
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
    await page.waitForTimeout(500);
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
      // Read after each frame paints (a task queued from its animation frame).
      const tick = () => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return;
        setTimeout(sample, 0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    // Lines from Shift-Return, then a line that wraps.
    for (let line = 1; line <= 4; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await page.waitForTimeout(60);
    }
    await page.keyboard.type("and a last line long enough to wrap in the composer's card ".repeat(3));
    await page.waitForTimeout(300);
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
    await page.waitForTimeout(600);
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
    await page.waitForTimeout(500);
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
      const tick = () => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return;
        setTimeout(sample, 0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, start.row);
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await page.waitForTimeout(60);
    }
    // And back: the lines removed one at a time, then the rest of the draft at once.
    for (let line = 1; line <= 3; line++) {
      await page.keyboard.press("Backspace");
      await page.keyboard.down("Shift");
      await page.keyboard.press("Home");
      await page.keyboard.up("Shift");
      await page.keyboard.press("Backspace");
      await page.waitForTimeout(60);
    }
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(300);
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
      const tick = () => {
        if ((window as unknown as { __frames?: unknown }).__frames !== frames) return;
        setTimeout(sample, 0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
    for (let line = 1; line <= 5; line++) {
      await page.keyboard.type(`Line ${line} of a longer prompt`);
      await page.keyboard.press("Shift+Enter");
      await page.waitForTimeout(60);
    }
    for (let line = 1; line <= 3; line++) {
      await page.keyboard.press("Backspace");
      await page.keyboard.down("Shift");
      await page.keyboard.press("Home");
      await page.keyboard.up("Shift");
      await page.keyboard.press("Backspace");
      await page.waitForTimeout(60);
    }
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(300);
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
});
