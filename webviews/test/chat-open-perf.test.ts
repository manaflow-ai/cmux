// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// cmux-web-test-timeout: 300
//
// Leo, 2026-10-20: "do chats load fast yet? even with a high number of chats and high load? does it
// still flash or flicker? It should have no layout shift, then a fast fade-in, and be instant if
// cached." This measures opening chats in the agent pane against a stand-in acpmux that answers
// like a busy daemon (every call takes a while, an attach longer), with 120 chats in the list, and
// holds the pane to what Leo asked for:
//
//   - a chat opened again (its tail is in the page) draws in CACHED_PAINT_MS;
//   - a chat opened for the first time draws in COLD_PAINT_MS;
//   - from the frame a chat draws on, no row it drew moves (no layout shift) and no frame leaves
//     part of the transcript's view empty.
//
// The frame sampler reads each row's place in the view every frame after the chat draws, so a row
// placed by an estimate and then by its drawn height (the flicker Leo saw) counts as a shift.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-open-perf.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-open-perf: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat open perf", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 20, 9, 0, 0);
  /// Chats in the list, as a person with a long history has (Leo: "a high number of chats").
  const CHAT_COUNT = 120;
  /// The chats one run opens; each is opened cold, then again from the page's cache.
  const VISITS = 6;
  /// A busy daemon's round trip, and what an attach of a chat with a tail costs on top.
  const CALL_MS = 20;
  const ATTACH_MS = 150;
  /// What the brief asks of the shipped pane: a chat the page already read draws inside 100 ms, a
  /// chat read for the first time inside 400 ms (the attach's round trip and the rows' layout).
  const CACHED_PAINT_MS = 100;
  const COLD_PAINT_MS = 400;
  /// The pane here is the Vite dev server's (an unminified React, the React Compiler's dev output),
  /// where the one frame that renders a chat costs 70-110 ms by itself — the log's `frames to the
  /// draw` shows a cached open is that single frame. So the budgets asserted are the brief's plus
  /// that frame, and what pins the round trips is the frame count: a cached open draws on the first
  /// frame after the select.
  const DEV_RENDER_MS = 200;
  /// How long after a chat draws the sampler watches it for shifts and blank frames.
  const SETTLE_MS = 700;
  /// `CMUX_CHAT_OPEN_PERF_VIDEO=<dir>` records the run, for a before/after on a pull request.
  const videoDir = process.env.CMUX_CHAT_OPEN_PERF_VIDEO;

  const modes = (current: string) => ({
    currentModeId: current,
    availableModes: [
      { id: "default", name: "Normal", description: "Ask before edits and commands" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "bypassPermissions", name: "Full access", description: "Never ask" },
    ],
  });

  /// One chat's listed summary and attach page: a tail of prompts, replies and a tool run, the
  /// shape a real chat has, ending in a line only this chat carries (`marker`).
  const chat = (index: number) => {
    const sessionId = `0190a000-0000-7000-8000-${String(index).padStart(12, "0")}`;
    const marker = `Chat ${index} tail reached.`;
    const listed = {
      sessionId,
      cwd: `/home/dev/project-${index % 7}`,
      title: `Chat ${index}: uploader retry path`,
      harness: "claude",
      family: "claude",
      model: "claude-sonnet",
      status: "idle",
      turnCount: 4,
      updatedAt: START - index * 60_000,
      currentModeId: index % 3 === 0 ? "bypassPermissions" : "default",
    };
    const steps: [string, string, Record<string, unknown>][] = [];
    const say = (text: string) =>
      steps.push([
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId,
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
          },
        },
      ]);
    for (let turn = 0; turn < 4; turn += 1) {
      steps.push(["mux", "user_message", { text: `Turn ${turn}: look at the retry path in uploader.ts` }]);
      steps.push(["mux", "turn_started", {}]);
      say(
        `Reading \`uploader.ts\` for turn ${turn}.\n\n` +
          "The retry loop gives up after the first failure, so a flaky upload never gets a second\n" +
          "chance. The fix keeps the backoff the config already names.\n\n" +
          "- read the config\n- wrap the send\n- cover it with a test\n",
      );
      say(
        "```ts\n" +
          `const retries = config.retries ?? ${turn + 2};\n` +
          "for (let attempt = 0; attempt < retries; attempt += 1) {\n" +
          "  const sent = await send(part);\n" +
          "  if (sent.ok) return sent;\n" +
          "}\n```\n",
      );
      if (turn === 3) say(marker);
      steps.push(["mux", "turn_result", { status: "completed" }]);
    }
    const events = steps.map(([dir, kind, msg], at) => ({
      sessionId,
      seq: at + 1,
      at: START + at * 1000,
      dir,
      kind,
      msg,
    }));
    return { sessionId, marker, listed, attached: { ...listed, modes: modes(listed.currentModeId) }, events };
  };
  const chats = [...Array(CHAT_COUNT).keys()].map(chat);
  const byId = new Map(chats.map((entry) => [entry.sessionId, entry]));

  let attaches = 0;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: chats.map((entry) => entry.listed) };
      case "_acpmux/attach": {
        attaches += 1;
        const entry = byId.get(String(params.sessionId))!;
        return { session: entry.attached, lastSeq: entry.events.length, events: entry.events };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: byId.get(String(params.sessionId))?.events.length ?? 0 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open() {},
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          // Every call costs a round trip, an attach the chat's read on top: the daemon is busy.
          setTimeout(
            () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result })),
            message.method === "_acpmux/attach" ? ATTACH_MS : CALL_MS,
          );
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(chats[0].sessionId));
        await warm.getByText(chats[0].marker).waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    void daemon?.stop(true);
  });

  type Opened = {
    /// Milliseconds from the select to the first frame that draws this chat; null when it never did.
    drawn: number | null;
    /// Frames after that one where a row that was already drawn moved in the view.
    shifted: number;
    /// The largest move of a drawn row, in pixels.
    moved: number;
    /// Frames after that one where the mounted rows left part of the transcript's view empty.
    blank: number;
    frames: number;
    /// The first frame that shifted or went blank, for the failure's message.
    first: unknown;
    /// When each frame before the chat drew ran.
    cadence: number[];
  };

  /// Selects `sessionId` from the page and samples every frame until the chat has been drawn for
  /// `settleMs`: when it first drew, whether a row it drew moved after that, and whether any frame
  /// left part of the view empty. Runs in the page (serialized), so it sees every frame.
  const openChat = async ({
    sessionId,
    marker,
    settleMs,
    limitMs,
  }: {
    sessionId: string;
    marker: string;
    settleMs: number;
    limitMs: number;
  }) => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    /// Each mounted row's top in the view, by its id.
    const rowTops = () => {
      const tops = new Map<string, number>();
      for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-row")) {
        const id = row.dataset.rowId;
        if (id) tops.set(id, row.getBoundingClientRect().top);
      }
      return tops;
    };
    /// What the mounted rows cover of the transcript's view. Rows mount in runs of consecutive
    /// positions (a run per place the reader has been), so the view is blank when it holds no row,
    /// when two runs leave a hole in it, or when a run stops short of an edge the chat continues
    /// past. The bands the transcript keeps empty on purpose — its top padding at the first row and
    /// the space the composer floats over under the last — are at an end the chat does not
    /// continue past, so they are not holes.
    const coverage = () => {
      const view = scroller.getBoundingClientRect();
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((row) => ({ index: Number(row.getAttribute("aria-posinset")), rect: row.getBoundingClientRect() }))
        .sort((a, b) => a.index - b.index);
      const runs: { top: number; bottom: number }[] = [];
      rows.forEach((row, at) => {
        if (at > 0 && row.index === rows[at - 1].index + 1) runs.at(-1)!.bottom = row.rect.bottom;
        else runs.push({ top: row.rect.top, bottom: row.rect.bottom });
      });
      const seen = runs
        .map((run) => ({ top: Math.max(run.top, view.top), bottom: Math.min(run.bottom, view.bottom) }))
        .filter((run) => run.bottom - run.top > 0.5);
      const above = scroller.scrollTop > 0.5;
      const below = scroller.scrollTop < scroller.scrollHeight - scroller.clientHeight - 0.5;
      const hole =
        seen.length === 0 ||
        seen.some((run, at) => at > 0 && run.top - seen[at - 1].bottom > 1) ||
        (above && seen[0].top > view.top + 1) ||
        (below && seen.at(-1)!.bottom < view.bottom - 1);
      return { covered: !hole, rows: rows.length, seen, view: { top: view.top, bottom: view.bottom }, above, below };
    };
    const start = performance.now();
    let drawn: number | null = null;
    let shifted = 0;
    let moved = 0;
    let blank = 0;
    let frames = 0;
    let first: unknown = null;
    let before: Map<string, number> | undefined;
    let scrollTop = scroller.scrollTop;
    /// When each frame before the chat drew ran: a wait on acpmux is many short frames, the
    /// chat's own first render one long one.
    const cadence: number[] = [];
    const result = new Promise<{
      drawn: number | null;
      shifted: number;
      moved: number;
      blank: number;
      frames: number;
      first: unknown;
      cadence: number[];
    }>((resolve) => {
      const sample = () => {
        const at = performance.now() - start;
        const shows = scroller.innerText.includes(marker);
        if (drawn === null) {
          cadence.push(Math.round(at));
          if (shows) {
            drawn = at;
            before = rowTops();
            scrollTop = scroller.scrollTop;
          }
        } else {
          frames += 1;
          const covers = coverage();
          if (!covers.covered) {
            blank += 1;
            first ??= { at, ...covers };
          }
          const tops = rowTops();
          // A scroll of its own (the reader dragging, a follow to the bottom) moves every row:
          // only a frame that scrolled nowhere can show a layout shift.
          if (scroller.scrollTop === scrollTop) {
            let worst = 0;
            for (const [id, top] of tops) {
              const was = before!.get(id);
              if (was !== undefined) worst = Math.max(worst, Math.abs(was - top));
            }
            if (worst > 1) {
              shifted += 1;
              moved = Math.max(moved, worst);
              first ??= { at, moved: worst };
            }
          }
          before = tops;
          scrollTop = scroller.scrollTop;
        }
        if (at < limitMs && (drawn === null || at < drawn + settleMs)) requestAnimationFrame(sample);
        else resolve({ drawn, shifted, moved, blank, frames, first, cadence });
      };
      requestAnimationFrame(sample);
    });
    const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
      .cmuxAcpmuxActions;
    await actions?.["chat.select"]?.({ sessionId });
    return result;
  };

  const report = (name: string, opened: Opened[]) => {
    const drawn = opened.map((entry) => entry.drawn ?? Number.POSITIVE_INFINITY);
    const worst = Math.max(...drawn);
    console.log(
      `chat-open-perf ${name}: draws ${drawn.map((ms) => (Number.isFinite(ms) ? ms.toFixed(0) : "never")).join("/")} ms ` +
        `(worst ${Number.isFinite(worst) ? worst.toFixed(0) : "never"}), ` +
        `shifted frames ${opened.map((entry) => entry.shifted).join("/")} (worst move ${Math.max(...opened.map((entry) => entry.moved)).toFixed(1)} px), ` +
        `blank frames ${opened.map((entry) => entry.blank).join("/")}, ` +
        `frames ${opened.map((entry) => entry.frames).join("/")}, ` +
        `frames to the draw ${opened.map((entry) => entry.cadence.join(",")).join(" | ")}` +
        (opened.some((entry) => entry.first)
          ? `, first bad frame ${JSON.stringify(opened.find((entry) => entry.first)!.first)}`
          : ""),
    );
    return worst;
  };

  test(`opening chats with ${CHAT_COUNT} in the list draws fast, with no shift and no blank frame`, async () => {
    const page = await browser!.newPage({
      viewport: { width: 1000, height: 760 },
      ...(videoDir ? { recordVideo: { dir: videoDir, size: { width: 1000, height: 760 } } } : {}),
    });
    await page.goto(url(chats[0].sessionId));
    await page.getByText(chats[0].marker).waitFor();
    const open = (entry: (typeof chats)[number]) =>
      page.evaluate(
        `(${openChat.toString()})(${JSON.stringify({
          sessionId: entry.sessionId,
          marker: entry.marker,
          settleMs: SETTLE_MS,
          limitMs: 8_000,
        })})`,
      ) as Promise<Opened>;
    // Chats far apart in a 120-chat list, as a person picks them out of the sidebar.
    const picked = [...Array(VISITS).keys()].map((at) => chats[7 + at * 17]);
    const cold: Opened[] = [];
    for (const entry of picked) cold.push(await open(entry));
    // Each of them again: the page read every one of these chats already.
    const cached: Opened[] = [];
    for (const entry of picked) cached.push(await open(entry));
    await page.close();

    const worstCold = report("cold", cold);
    const worstCached = report("cached", cached);
    console.log(`chat-open-perf: ${attaches} attaches for ${picked.length} cold and ${picked.length} cached opens`);
    for (const opened of [...cold, ...cached]) {
      expect(opened.drawn).not.toBeNull();
      // Leo: "It should have no layout shift"; a row placed by an estimate then by its drawn
      // height moves, which is the flicker.
      expect(opened.shifted).toBe(0);
      // Leo: "no blank-then-pop"; every frame from the first draws the transcript.
      expect(opened.blank).toBe(0);
      expect(opened.frames).toBeGreaterThan(5);
    }
    // Leo: "instant if cached". This is what tells a cached open from a cold one here, and what a
    // regression would break: the chat draws in the first frames after the select, with no wait on
    // acpmux in between. A cold open takes ten-plus frames (the log's `frames to the draw`), so the
    // few frames allowed leave room for a loaded runner without letting a round trip through. The
    // budgets below are the brief's plus the dev bundle's render frame, so they are a ceiling, not
    // the line between the two.
    for (const opened of cached) expect(opened.cadence.length).toBeLessThanOrEqual(3);
    expect(worstCached).toBeLessThan(CACHED_PAINT_MS + DEV_RENDER_MS);
    expect(worstCold).toBeLessThan(COLD_PAINT_MS + DEV_RENDER_MS);
  });
});
