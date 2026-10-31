// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
// cmux-web-test-timeout: 300
//
// Leo, 2026-10-21, after restarting into a nightly with a chat of about 690 turns: "I LOAD IN AND
// IT'S A BLACK SCREEN, AND THEN THE ADJUSTMENT IS BROKEN. I THINK YOU DIDN'T PAGINATE." This opens
// a 700-turn chat cold, as the pane does when the app starts (the page loads with the chat named
// in its URL), against a stand-in acpmux that answers like a busy daemon and pages an attach the
// way acpmux does (the newest `limit` records, `hasMore`), and holds the pane to:
//
//   - the page tells its host it shows the chat (pane.painted, which drops the app's loading state)
//     only once the rows are in view, never on an empty transcript;
//   - the rows show with the attach's page, not after the reads that follow it, and within
//     COLD_PAINT_MS (plus the dev bundle's render frame) of the pane connecting on a quiet daemon,
//     already at the latest message;
//   - from that frame on, the latest row never moves in the view (no "adjustment"), and no frame
//     leaves part of the view blank;
//   - no scroller is scrolled sideways and the transcript's column sits inside the view (no text
//     cut off at the left);
//   - the page never paints an opaque background (glass, never black).
//
// `first content` is printed for every run, so the before and after numbers come from this file.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { loadTurn, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-open-long.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-open-long: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat open long", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  /// Leo's chat had about 690 turns.
  const TURNS = 700;
  /// A busy daemon's round trip, and what an attach of a long chat costs on top. The loaded run is
  /// Leo's Mac at load 89 the morning he saw it: every round trip slow, longer than the pane's own
  /// open timers (direct.ts OPEN_HOLD_MS, App.tsx CHAT_DRAW_HOLD_MS).
  const QUIET = { call: 20, attach: 150 };
  const LOADED = { call: 400, attach: 1200 };
  let latency = QUIET;
  /// When the pane's socket opened and when the daemon sent the attach's answer (Date.now, the
  /// page's clock too). Time to first content counts from the socket: before it, the dev server is
  /// serving the page's hundreds of modules, which the app's bundled page does not.
  let connected = 0;
  let attachAnswered = 0;
  /// chat-open-perf.test.ts's cold budget, and the dev bundle's render of this chat's first page
  /// on top of it: 266 rows from 400 records, 450-520 ms in the unminified dev React on a Linux
  /// fleet host (huge-blue, 2026-10-21), where chat-open-perf's four-turn chats take one 200 ms frame.
  const COLD_PAINT_MS = 400;
  const DEV_RENDER_MS = 600;
  /// How long after the first content the sampler watches for a shift, a blank frame or a scroll.
  const SETTLE_MS = 1500;

  const sessionId = "0190a000-0000-7000-8000-000000000700";
  const marker = `turn ${TURNS - 1}`;
  const events: Record<string, unknown>[] = [];
  const record = (step: LoadStep, at: number) => {
    const seq = events.length + 1;
    events.push(
      "update" in step
        ? {
            sessionId,
            seq,
            at,
            dir: "in",
            kind: String(step.update.sessionUpdate),
            msg: { method: "session/update", params: { sessionId, update: step.update } },
          }
        : { sessionId, seq, at, dir: "mux", kind: step.mux, msg: step.msg ?? {} },
    );
  };
  for (let turn = 0; turn < TURNS; turn += 1) for (const step of loadTurn(turn)) record(step, START + turn * 60_000);
  const listed = {
    sessionId,
    cwd: "/home/dev/cmux",
    title: `A ${TURNS}-turn chat`,
    harness: "claude",
    family: "claude",
    model: "claude-sonnet",
    status: "idle",
    turnCount: TURNS,
    updatedAt: START + TURNS * 60_000,
    currentModeId: "default",
  };
  /// acpmux's page (hub/paging.rs): the newest `limit` records before `beforeSeq`, oldest first.
  const page = (params: Record<string, any>) => {
    const before = typeof params.beforeSeq === "number" ? params.beforeSeq : Number.POSITIVE_INFINITY;
    const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds : undefined;
    const held = events.filter(
      (event) =>
        (event.seq as number) < before &&
        (!kinds || kinds.includes("transcript") || kinds.includes(String(event.kind))),
    );
    const limit = typeof params.limit === "number" ? params.limit : held.length;
    const taken = held.slice(Math.max(0, held.length - limit));
    return { events: taken, hasMore: taken.length < held.length, lastSeq: events.length };
  };
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [listed] };
      case "_acpmux/attach":
        return { session: listed, ...page(params) };
      case "_acpmux/events":
        return page(params);
      // A folder the person trusted long ago, as a chat this long is in: no Trust card.
      case "acp.trust.get":
        return { cwd: listed.cwd, level: "trusted" };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${sessionId}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open() {
          connected = Date.now();
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          const attach = message.method === "_acpmux/attach";
          setTimeout(
            () => {
              if (attach) attachAnswered = Date.now();
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
            },
            attach ? latency.attach : latency.call,
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
    // One load to warm Vite's transforms, so the measured load times the pane, not the dev server.
    const warm = await browser.newPage();
    await warm.goto(url());
    await warm.getByText(marker, { exact: false }).first().waitFor({ timeout: 60_000 });
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Sampled = {
    /// Milliseconds from the page's start to the first painted frame with transcript text in view.
    firstContent: number | null;
    /// When the page's scripts had run (DOMContentLoaded follows the module scripts): what is left of
    /// `firstContent` after it is the pane's own work and its round trips, not the dev server's.
    scripted: number;
    /// That frame was at the latest message.
    atLatest: boolean;
    /// Frames after it where the latest row moved in the view, and the largest move in pixels.
    shifted: number;
    moved: number;
    /// Frames after it where no row covered part of the view.
    blank: number;
    /// The largest sideways scroll any element had, and the furthest the column reached past the
    /// view's left edge.
    scrollLeft: number;
    clippedLeft: number;
    /// Painted frames whose page background was opaque, from the first frame.
    opaque: number;
    /// Date.now() at the first content, against the daemon's attach answer.
    firstContentClock: number | null;
    /// When the page told its host it shows what it is (pane.painted, which drops the app's loading
    /// state), and whether transcript text was in view by then.
    paintedAt: number | null;
    paintedWithContent: boolean;
    frames: number;
    first: unknown;
    /// What the first content frame showed, beside `first` in a failure's message.
    firstFrame: unknown;
  };

  /// Runs in the page from its first script: samples every painted frame until the chat has shown
  /// for `settleMs`.
  const sampler = ({ settleMs, limitMs }: { settleMs: number; limitMs: number }) => {
    const alpha = (color: string) => {
      const match = color.match(/rgba?\(([^)]+)\)/);
      if (!match) return color === "transparent" ? 0 : 1;
      const parts = match[1]!.split(/[ ,/]+/).filter(Boolean);
      return parts.length > 3 ? Number(parts[3]) : 1;
    };
    const state: Sampled = {
      firstContent: null,
      scripted: performance.now(),
      atLatest: false,
      shifted: 0,
      moved: 0,
      blank: 0,
      scrollLeft: 0,
      clippedLeft: 0,
      opaque: 0,
      firstContentClock: null,
      paintedAt: null,
      paintedWithContent: false,
      frames: 0,
      first: null,
      firstFrame: null,
    };
    let latestBottom: number | undefined;
    const done = new Promise<Sampled>((resolve) => {
      const tick = () => {
        const at = performance.now();
        // The page's own backdrop: whatever paints first, the shell or the body.
        const shell = document.querySelector<HTMLElement>(".acpmux-shell");
        const painted = [document.documentElement, document.body, shell].filter((node): node is HTMLElement => !!node);
        if (painted.some((node) => alpha(getComputedStyle(node).backgroundColor) >= 0.999)) state.opaque += 1;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (scroller) {
          for (const node of [
            scroller,
            shell,
            document.querySelector<HTMLElement>(".acpmux-main"),
            document.scrollingElement as HTMLElement | null,
          ])
            if (node) state.scrollLeft = Math.max(state.scrollLeft, node.scrollLeft);
          const view = scroller.getBoundingClientRect();
          const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")]
            .map((row) => ({ row, rect: row.getBoundingClientRect() }))
            .filter(({ rect }) => rect.width > 0 && rect.bottom > view.top && rect.top < view.bottom);
          const texty = rows.filter(({ row }) => (row.textContent ?? "").trim() !== "");
          const shows = texty.length > 0 && Number(getComputedStyle(scroller).opacity) > 0;
          for (const { rect } of rows) state.clippedLeft = Math.max(state.clippedLeft, view.left - rect.left);
          const latest = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].reduce<HTMLElement | undefined>(
            (low, row) => (!low || row.getBoundingClientRect().bottom > low.getBoundingClientRect().bottom ? row : low),
            undefined,
          );
          const atLatest = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop <= 2;
          const painted = (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt;
          if (painted !== undefined && state.paintedAt === null) {
            state.paintedAt = painted;
            state.paintedWithContent = shows;
          }
          if (shows && state.firstContent === null) {
            state.firstContent = at;
            state.firstContentClock = Date.now();
            state.atLatest = atLatest;
            latestBottom = latest?.getBoundingClientRect().bottom;
            const dock = document.querySelector<HTMLElement>(".acpmux-dock")?.getBoundingClientRect();
            state.firstFrame = {
              row: latest?.dataset.rowId,
              rowHeight: latest?.getBoundingClientRect().height,
              view: scroller.clientHeight,
              top: scroller.scrollTop,
              content: scroller.scrollHeight,
              dock: dock ? Math.round(dock.top) : null,
            };
          } else if (state.firstContent !== null) {
            state.frames += 1;
            if (!shows) {
              state.blank += 1;
              state.first ??= { at, blank: true };
            }
            const bottom = latest?.getBoundingClientRect().bottom;
            if (bottom !== undefined && latestBottom !== undefined && Math.abs(bottom - latestBottom) > 1) {
              state.shifted += 1;
              state.moved = Math.max(state.moved, Math.abs(bottom - latestBottom));
              const dock = document.querySelector<HTMLElement>(".acpmux-dock")?.getBoundingClientRect();
              state.first ??= {
                at,
                from: latestBottom,
                to: bottom,
                atLatest,
                row: latest?.dataset.rowId,
                rowHeight: latest?.getBoundingClientRect().height,
                view: scroller.clientHeight,
                top: scroller.scrollTop,
                content: scroller.scrollHeight,
                dock: dock ? Math.round(dock.top) : null,
              };
            }
            latestBottom = bottom;
          }
        }
        if (at < limitMs && (state.firstContent === null || at < state.firstContent + settleMs)) return;
        resolve(state);
        return false;
      };
      window.cmuxAfterPaint(tick);
    });
    (window as { __chatOpenLong?: Promise<Sampled> }).__chatOpenLong = done;
  };

  const openCold = async () => {
    const tab = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    try {
      await installPaintedFrames(tab);
      await tab.addInitScript(
        `window.addEventListener("DOMContentLoaded", () => (${sampler.toString()})(${JSON.stringify({ settleMs: SETTLE_MS, limitMs: 20_000 })}))`,
      );
      await tab.goto(url());
      return (await tab.evaluate(
        () => (window as unknown as { __chatOpenLong: Promise<unknown> }).__chatOpenLong,
      )) as Sampled;
    } finally {
      await tab.close();
    }
  };

  /// Opens the chat cold three times under `under` and holds every open to the brief.
  const holdsToTheBrief = async (name: string, under: typeof QUIET, budgetMs: number) => {
    latency = under;
    const runs: (Sampled & { afterAttach: number; afterConnect: number })[] = [];
    try {
      for (let run = 0; run < 3; run += 1) {
        const sampled = await openCold();
        runs.push({
          ...sampled,
          afterAttach:
            sampled.firstContentClock === null ? Number.POSITIVE_INFINITY : sampled.firstContentClock - attachAnswered,
          afterConnect:
            sampled.firstContentClock === null ? Number.POSITIVE_INFINITY : sampled.firstContentClock - connected,
        });
      }
    } finally {
      latency = QUIET;
    }
    const first = runs.map((run) => run.afterConnect);
    const fmt = (values: number[]) => values.map((ms) => (Number.isFinite(ms) ? ms.toFixed(0) : "never")).join("/");
    console.log(
      `::notice title=chat-open-long (${name})::${TURNS} turns, ${under.call} ms a call and ${under.attach} ms an attach: ` +
        `first content ${fmt(first)} ms after the pane connected ` +
        `(${fmt(runs.map((run) => run.firstContent ?? Number.POSITIVE_INFINITY))} ms from navigation, ` +
        `${fmt(runs.map((run) => run.afterAttach))} ms after the attach answered; budget ${budgetMs} ms), ` +
        `painted ${runs.map((run) => (run.paintedAt === null ? "never" : `${(run.paintedAt - run.scripted).toFixed(0)} ms ${run.paintedWithContent ? "with" : "WITHOUT"} rows`)).join("/")}, ` +
        `at latest ${runs.map((run) => run.atLatest).join("/")}, ` +
        `shifted frames ${runs.map((run) => run.shifted).join("/")} (worst ${Math.max(...runs.map((run) => run.moved)).toFixed(0)} px), ` +
        `blank ${runs.map((run) => run.blank).join("/")}, opaque frames ${runs.map((run) => run.opaque).join("/")}, ` +
        `scrollLeft ${Math.max(...runs.map((run) => run.scrollLeft))}, clipped left ${Math.max(...runs.map((run) => run.clippedLeft)).toFixed(0)} px` +
        (runs.some((run) => run.first)
          ? `, first bad frame ${JSON.stringify(runs.find((run) => run.first)!.first)} after ${JSON.stringify(runs.find((run) => run.first)!.firstFrame)}`
          : ""),
    );
    for (const run of runs) {
      expect(run.firstContent).not.toBeNull();
      // The host drops its loading state (the relaunch's saved frame of the chat) on pane.painted:
      // a report before the rows is the empty page Leo saw.
      expect(run.paintedWithContent).toBe(true);
      expect(run.atLatest).toBe(true);
      expect(run.shifted).toBe(0);
      expect(run.blank).toBe(0);
      expect(run.scrollLeft).toBe(0);
      expect(run.clippedLeft).toBeLessThanOrEqual(0);
      expect(run.opaque).toBe(0);
      // The rows come with the attach's page, not after the reads that follow it (the turn's
      // opener, asks, handoff), each another round trip on a busy daemon.
      expect(run.afterAttach).toBeLessThan(under.call + DEV_RENDER_MS);
    }
    expect(Math.max(...first)).toBeLessThan(budgetMs);
  };

  test(`a ${TURNS}-turn chat opened cold shows its last screenful at once, at the latest message, and holds still`, async () => {
    await holdsToTheBrief("quiet", QUIET, COLD_PAINT_MS + DEV_RENDER_MS);
  });

  test(`a ${TURNS}-turn chat opened cold on a busy daemon shows its rows with the attach, never an empty page`, async () => {
    // The handshake, status, the list and the attach are five round trips here before any row can
    // exist; what is held is that nothing else is waited on, and that nothing is shown before.
    await holdsToTheBrief("loaded", LOADED, 4 * LOADED.call + LOADED.attach + DEV_RENDER_MS);
  });
});
