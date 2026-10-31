// l10n-allow-file: test fixture prompts, not shipped UI.
// Scrolling up a long chat brings older turns in with no flicker and no jump (Leo 2026-10-31: "I
// HATE THE FUCKING FLICKER LOAD IN WHEN I SCROLL UP TO CHATS"; 2026-10-26: "im getting flickers and
// jumps when i scroll up and it's loading new parts of chats that havent been loaded"). The reader
// wheels up through several older pages, each read from acpmux with a delay, and every painted frame
// is read: a row in view drawn below full ink is a flicker frame, a row in view that moves between
// two frames with no wheel input between them is a jump frame, and a view with a band of no row in
// it is a blank frame. A page that lands while the reader is still below it draws at once, in full
// ink, with no fade (Leo 2026-10-31: "WE DON'T NEED A FADE IN ANIMATION UNLESS IT'S THE WORST CASE"
// / "JUST BE MORE FUCKING OPTIMISTIC").
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-scroll-up-no-flicker.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-scroll-up-no-flicker: skipping (run `bunx playwright install chromium`)");
    describe.skip("scroll up with no flicker", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000f1c4";
  const START = Date.UTC(2026, 9, 1, 9, 0, 0);
  const TURNS = 240;
  /// How long acpmux takes to answer a read: a page of older history arrives this late.
  const READ_MS = 120;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>) => {
    events.push({ sessionId: CHAT, seq: events.length + 1, at: START + events.length * 1000, dir, kind, msg });
  };
  for (let n = 1; n <= TURNS; n++) {
    record("mux", "user_message", { text: `Question ${n}` });
    record("mux", "turn_started", {});
    // Answers of different lengths, so an estimated height is wrong for most rows.
    const lines = 1 + (n % 5) * 2;
    record(
      "in",
      "agent_message_chunk",
      chunk(Array.from({ length: lines }, (_, line) => `Answer ${n}, line ${line + 1}: the checks are green.`).join("\n\n")),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  const lastSeq = events.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq,
  };
  /// acpmux's paging: the newest `limit` records before `beforeSeq`, or the first `limit` after `afterSeq`.
  function page(params: Record<string, any>) {
    const limit = Math.min(Number(params.limit ?? 2000), 120);
    if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
      const after = events.filter((event) => event.seq > params.afterSeq);
      return { events: after.slice(0, limit), hasMore: after.length > limit, lastSeq };
    }
    const before = events.filter((event) => event.seq < (params.beforeSeq ?? Infinity));
    return { events: before.slice(Math.max(0, before.length - limit)), hasMore: before.length > limit, lastSeq };
  }
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, ...page(params) };
      case "_acpmux/events":
        return page(params);
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          setTimeout(() => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result })), READ_MS);
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
    // A wheel step scrolls in the frame it lands in, so a row that moves in a frame with no wheel
    // before it moved on its own.
    browser = await chromium.launch({ headless: true, args: ["--disable-smooth-scrolling"] });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Frames = {
    frames: number;
    flicker: number;
    jump: number;
    blank: number;
    maxJumpPx: number;
    oldestTurn: number;
    samples: unknown[];
  };
  /// Wheels up `steps` times, a few painted frames apart, and reads every painted frame meanwhile.
  async function scrollUpReading(page: Page, steps: number): Promise<Frames> {
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let wheels = 0;
      addEventListener("wheel", () => (wheels += 1), { capture: true, passive: true });
      const stats = { frames: 0, flicker: 0, jump: 0, blank: 0, maxJumpPx: 0, oldestTurn: Infinity, samples: [] as unknown[] };
      let sinceWheel = 0;
      let last: { wheels: number; tops: Map<string, number>; scrollTop: number } | undefined;
      const stop = window.cmuxAfterPaint(() => {
        const view = scroller.getBoundingClientRect();
        const tops = new Map<string, number>();
        let faded = false;
        const covered: [number, number][] = [];
        for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
          const box = row.getBoundingClientRect();
          if (box.bottom <= view.top || box.top >= view.bottom || box.height === 0) continue;
          tops.set(row.dataset.rowId!, box.top);
          covered.push([Math.max(box.top, view.top), Math.min(box.bottom, view.bottom)]);
          if (Number(getComputedStyle(row).opacity) < 0.99) faded = true;
        }
        covered.sort((a, b) => a[0] - b[0]);
        // The widest band of the view no row covers (the gap between two rows' boxes is a few px).
        let gap = 0;
        let reach = view.top;
        for (const [top, bottom] of covered) {
          gap = Math.max(gap, top - reach);
          reach = Math.max(reach, bottom);
        }
        gap = Math.max(gap, view.bottom - reach);
        for (const bubble of scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")) {
          const turn = Number(/Question (\d+)/.exec(bubble.textContent ?? "")?.[1]);
          if (turn) stats.oldestTurn = Math.min(stats.oldestTurn, turn);
        }
        stats.frames += 1;
        if (faded) stats.flicker += 1;
        if (scroller.scrollTop > 0 && gap > 64) stats.blank += 1;
        // Two frames with no wheel between them (and none in the frame before, whose scroll may
        // paint a frame late): every row in view in both must sit still.
        if (last && last.wheels === wheels) {
          let moved = 0;
          for (const [id, top] of tops) {
            const before = last.tops.get(id);
            if (before !== undefined) moved = Math.max(moved, Math.abs(top - before));
          }
          if (moved > 1) {
            stats.jump += 1;
            if (stats.samples.length < 16)
              stats.samples.push({
                sinceWheel,
                moved: Math.round(moved),
                scrollDelta: Math.round(scroller.scrollTop - last.scrollTop),
                scrollTop: Math.round(scroller.scrollTop),
              });
            stats.maxJumpPx = Math.max(stats.maxJumpPx, Math.round(moved));
          }
        }
        sinceWheel = last && last.wheels === wheels ? sinceWheel + 1 : 0;
        last = { wheels, tops, scrollTop: scroller.scrollTop };
      });
      (window as unknown as { __scrollUp: unknown }).__scrollUp = { stats, stop };
    });
    // Real wheel input, a few painted frames apart.
    for (let step = 0; step < steps; step++) {
      await page.mouse.wheel(0, -240);
      await page.evaluate(async () => {
        for (let frame = 0; frame < 4; frame++) await window.cmuxPaintFrame();
      });
    }
    // The last page lands and settles.
    return page.evaluate(async () => {
      for (let frame = 0; frame < 60; frame++) await window.cmuxPaintFrame();
      const { stats, stop } = (window as unknown as { __scrollUp: { stats: Frames; stop: () => void } }).__scrollUp;
      stop();
      return stats;
    });
  }

  test("older pages land with no flicker, jump or blank while the reader scrolls up", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 }, reducedMotion: "no-preference" });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const stats = await scrollUpReading(page, 160);
    console.log(`transcript-scroll-up-no-flicker ${JSON.stringify(stats)}`);
    // The scroll reached turns from several older pages (the chat opens on its last 30), so the
    // frames read cover pages landing.
    expect(stats.oldestTurn).toBeLessThan(TURNS - 90);
    expect({ flicker: stats.flicker, jump: stats.jump, blank: stats.blank }).toEqual({ flicker: 0, jump: 0, blank: 0 });
    expect(errors).toEqual([]);
    await page.close();
  });
});
