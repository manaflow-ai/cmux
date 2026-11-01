// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// cmux-web-test-timeout: 540
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
// Twice: once with the daemon quiet, once with BUSY_LANES chats working, each reporting a change
// of its own — the "high load" half of the ask, which a list of 120 idle chats does not measure.
// What that load reaches is not the same in both phases. A cold open holds the pane's last
// snapshot while its attach goes out, for up to SWITCH_HOLD_MS (1500 ms, direct.ts), and a change
// arriving under that hold is folded into the client's sessions and drawn nowhere — so a cold draw
// (244-330 ms here, inside the cap) is the one part of a run the load does not redraw. Everything
// else it does: a cached open releases the hold on the frame it draws, and both phases then watch
// SETTLE_MS unheld, which is where most of a cold window's changes land too. So the load is
// measured where the brief's hardest claim lives — "instant if cached" while forty chats report —
// and the no-shift, no-blank rules are held over frames the load really is redrawing.
// Under load the millisecond budgets get the dev bundle's render frame as slack; the frame counts
// and the no-shift, no-blank rules are held to the same numbers.
//
// The frame sampler reads each row's place in the view every frame after the chat draws, so a row
// placed by an estimate and then by its drawn height (the flicker Leo saw) counts as a shift.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
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
  /// Chats that keep working while the reader opens others: a person with many agents running
  /// (Leo: "high load"). Each reports a change of its own, which is what a busy daemon pushes at
  /// a pane. How many chats the changes rotate over, not how many arrive: raising this widens the
  /// churn in the list and changes no rate. ``BUSY_TICK_MS`` is the knob for how hard the load is.
  const BUSY_LANES = 40;
  /// One lane reports every tick, round robin, so the list changes twenty times a second. Each
  /// change is stamped newer than every chat in the list, so the busy lanes keep re-sorting to
  /// the top of it: the pane's hardest case, a list whose order moves under the reader.
  const BUSY_TICK_MS = 50;
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
  /// The frames a cached open may take to draw. This, not the millisecond budget, is what tells a
  /// cached open from a cold one here: a cold open takes ten-plus frames, so the few frames allowed
  /// leave room for a loaded runner without letting an acpmux round trip through.
  const CACHED_DRAW_FRAMES = 3;
  /// The longest fade a chat read cold may take to show (Leo, 2026-10-21: "a fast fade in"), and
  /// the frame the fade's end lands on: one frame late at most, the longest frame the fade spanned
  /// or FADE_FRAME_SLACK_MS, whichever is more (a dev-bundle frame of 130 ms during a 120 ms fade
  /// shows its end at 250 ms; the fade's own length is held exactly, from its animation).
  const FADE_MS = 150;
  const FADE_FRAME_SLACK_MS = 50;
  /// How long after a chat draws the sampler watches it for shifts and blank frames.
  const SETTLE_MS = 700;
  /// What the chat's permission groups and handoff reads cost in the side-reads run: longer than the
  /// attach, as on a daemon whose permission store is busy (HQ#5914, finding 3). Every other run
  /// answers them in CALL_MS, inside the attach's time.
  const SIDE_READ_MS = 400;
  /// `CMUX_CHAT_OPEN_PERF_VIDEO=<dir>` records the run, for a before/after on a pull request.
  const videoDir = process.env.CMUX_CHAT_OPEN_PERF_VIDEO;

  const modes = (current: string) => ({
    currentModeId: current,
    availableModes: [
      { id: "default", name: "Manual", description: "Always ask before making changes" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
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
    return {
      sessionId,
      marker,
      title: listed.title,
      listed,
      attached: { ...listed, modes: modes(listed.currentModeId) },
      events,
    };
  };
  const chats = [...Array(CHAT_COUNT).keys()].map(chat);
  const byId = new Map(chats.map((entry) => [entry.sessionId, entry]));

  let attaches = 0;
  /// The chats one run opens: far apart in the list, as a person picks them out of the sidebar, and
  /// below the recent chats the pane reads ahead (direct.ts READ_AHEAD_RECENT), so the first visit
  /// to each is the cold open this measures (chat-switch-prefetch.test.ts holds the read-ahead).
  const picked = [...Array(VISITS).keys()].map((at) => chats[20 + at * 17]!);
  /// The chats that keep working under load. None of them is one the run opens: a reader's own
  /// chat redrawing is its attach, not the load around it.
  const busyLanes = chats.filter((entry) => !picked.includes(entry)).slice(-BUSY_LANES);
  /// The load is on, which the second phase turns on; `pushed` is how many changes have gone out.
  let busy = false;
  let pushed = 0;
  /// The side-reads run is on: the permission and handoff reads take SIDE_READ_MS.
  let slowSideReads = false;
  const timers = new Map<unknown, ReturnType<typeof setInterval>>();
  const SIDE_OPERATIONS = [
    "_acpmux/permission_groups",
    "_acpmux/permission_group_respond",
    "_acpmux/permission_chat_revoke",
    "_acpmux/handoff_prepare",
    "_acpmux/handoff_get",
    "_acpmux/handoff_draft",
    "_acpmux/handoff_start",
    "_acpmux/handoff_discard",
  ];
  const sideRead = (method: string) => method === "_acpmux/permission_groups" || method === "_acpmux/handoff_get";
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        // The permission group and handoff operations, so every open reads them as the app's does.
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: SIDE_OPERATIONS } },
        };
      case "_acpmux/permission_groups":
        return {
          groups: [],
          chatAllowance: { active: false, expires: "session_stop_or_daemon_restart" },
          coverage: { label: "acp_requests_only", isolation: "unverified", detail: "ACP requests only" },
          batching: { windowMs: 50, maxItems: 8, maxPendingGroups: 4, maxReceipts: 8 },
        };
      case "_acpmux/handoff_get":
        return null;
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

  /// A chat whose attach outlasts the switch's hold (SWITCH_HOLD_MS, 1500 ms since 42200fa63cc5)
  /// and whose agent says LIVE_MARKER at SLOW_LIVE_MS, after the hold gave up and before the attach
  /// lands at SLOW_ATTACH_MS. None of the runs above opens it and it is not a busy lane.
  const slowChat = chats[3]!;
  const SLOW_LIVE_MS = 1_800;
  const SLOW_ATTACH_MS = 2_400;
  const LIVE_MARKER = "Live line before the read.";

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
        // The lanes report while the socket is open, when a run turned them on: one lane per tick,
        // each with the whole summary a change carries, as acpmux sends it.
        open(ws) {
          const timer = setInterval(() => {
            if (!busy) return;
            const entry = busyLanes[pushed % busyLanes.length]!;
            pushed += 1;
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                method: "_acpmux/session_changed",
                params: {
                  kind: "updated",
                  session: {
                    ...entry.listed,
                    status: "running",
                    turnCount: entry.listed.turnCount + pushed,
                    updatedAt: START + pushed * BUSY_TICK_MS,
                  },
                },
              }),
            );
          }, BUSY_TICK_MS);
          timers.set(ws, timer);
        },
        close(ws) {
          const timer = timers.get(ws);
          if (timer !== undefined) clearInterval(timer);
          timers.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          const slow = message.method === "_acpmux/attach" && message.params?.sessionId === slowChat.sessionId;
          // The slow chat's agent says something while its attach is still out, after the switch's
          // hold gave up: a live row the pane draws before it read the chat.
          if (slow)
            setTimeout(
              () =>
                ws.send(
                  JSON.stringify({
                    jsonrpc: "2.0",
                    method: "_acpmux/event",
                    params: {
                      sessionId: slowChat.sessionId,
                      seq: slowChat.events.length + 1,
                      at: START + 3_600_000,
                      dir: "in",
                      kind: "agent_message_chunk",
                      msg: {
                        method: "session/update",
                        params: {
                          sessionId: slowChat.sessionId,
                          update: {
                            sessionUpdate: "agent_message_chunk",
                            content: { type: "text", text: LIVE_MARKER },
                          },
                        },
                      },
                    },
                  }),
                ),
              SLOW_LIVE_MS,
            );
          // Every call costs a round trip, an attach the chat's read on top: the daemon is busy.
          setTimeout(
            () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result })),
            slow
              ? SLOW_ATTACH_MS
              : message.method === "_acpmux/attach"
                ? ATTACH_MS
                : slowSideReads && sideRead(message.method)
                  ? SIDE_READ_MS
                  : CALL_MS,
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
    // Awaited, so a lane's interval cannot outlive the run: an open socket's `close` handler is
    // what clears it, and an interval still ticking holds the loop until the file times out.
    await daemon?.stop(true);
  });

  /// What one measured open ran under: the changes the lanes pushed while it was being timed, and
  /// the attaches it cost. A cached open attaches too (the tail draws, then the attach lays what
  /// acpmux holds now over it), so this says what an open cost, not which kind it was.
  type Measured = { pushes: number; attaches: number };

  type Opened = {
    /// Milliseconds from the select to the first frame that draws this chat; null when it never did.
    drawn: number | null;
    /// Milliseconds from the select to the first frame whose header names this chat (its title);
    /// null when none did inside the window.
    header: number | null;
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
    /// The transcript's opacity on the frame the chat drew: 1 shows it whole at once, less starts a
    /// fade in.
    drawOpacity: number;
    /// Milliseconds from that frame to the first frame at full opacity (0 when it drew whole).
    fadeMs: number;
    /// The longest time between two painted frames while the fade ran.
    fadeFrameMs: number;
    /// Frames where the transcript's opacity went down, or the page's background changed: a flash.
    flashes: number;
    /// What the animations running on the transcript at the draw changed and for how long: a fade
    /// is opacity only, no slide or scale.
    animated: { properties: string[]; duration: number }[];
  };

  /// Selects `sessionId` from the page and samples every frame until the chat has been drawn for
  /// `settleMs`: when it first drew, whether a row it drew moved after that, and whether any frame
  /// left part of the view empty. Runs in the page (serialized), so it sees every frame.
  const openChat = async ({
    sessionId,
    marker,
    title,
    settleMs,
    limitMs,
  }: {
    sessionId: string;
    marker: string;
    title?: string;
    settleMs: number;
    limitMs: number;
  }) => {
    /// Whether the pane's header names the chat: its title, in the header or the tab row's tools.
    const headerNames = () =>
      title !== undefined &&
      [...document.querySelectorAll<HTMLElement>(".acpmux-header, .acpmux-handoff-header-tools")].some((node) =>
        (node.textContent ?? "").includes(title),
      );
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
    let header: number | null = null;
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
    /// The transcript's opacity as painted, and the page's backdrop (whatever paints first, the
    /// shell or the body): a fade only ever rises, and the backdrop never changes under a chat.
    const opacity = () => Number(getComputedStyle(scroller).opacity);
    const backdrop = () =>
      [document.body, document.querySelector<HTMLElement>(".acpmux-shell")]
        .map((node) => (node ? getComputedStyle(node).backgroundColor : ""))
        .join("|");
    let drawOpacity = 1;
    let fadeMs = 0;
    let fadeFrameMs = 0;
    let lastFrameAt = 0;
    let flashes = 0;
    let lastOpacity = 1;
    let lastBackdrop = backdrop();
    let animated: { properties: string[]; duration: number }[] = [];
    const result = new Promise<Opened>((resolve) => {
      window.cmuxAfterPaint(() => {
        const at = performance.now() - start;
        const shows = scroller.innerText.includes(marker);
        if (header === null && headerNames()) header = at;
        const seen = opacity();
        const behind = backdrop();
        if (behind !== lastBackdrop) {
          flashes += 1;
          first ??= { at, backdrop: { from: lastBackdrop, to: behind } };
        }
        lastBackdrop = behind;
        if (drawn === null) {
          cadence.push(Math.round(at));
          if (shows) {
            drawn = at;
            before = rowTops();
            scrollTop = scroller.scrollTop;
            drawOpacity = seen;
            lastOpacity = seen;
            animated = scroller.getAnimations().map((animation) => {
              const effect = animation.effect as KeyframeEffect | null;
              const timing = effect?.getComputedTiming();
              return {
                properties: [
                  ...new Set(
                    (effect?.getKeyframes() ?? []).flatMap((frame) =>
                      Object.keys(frame).filter(
                        (key) => !["offset", "computedOffset", "easing", "composite"].includes(key),
                      ),
                    ),
                  ),
                ],
                duration: Number(timing?.duration ?? 0),
              };
            });
          }
        } else {
          frames += 1;
          if (seen < lastOpacity - 0.001) {
            flashes += 1;
            first ??= { at, opacity: { from: lastOpacity, to: seen } };
          }
          if (lastOpacity < 0.999) fadeFrameMs = Math.max(fadeFrameMs, at - lastFrameAt);
          if (lastOpacity < 0.999 && seen >= 0.999) fadeMs = at - drawn;
          lastOpacity = seen;
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
        lastFrameAt = at;
        if (at < limitMs && (drawn === null || at < drawn + settleMs)) return;
        // A fade that never finished inside the window is as long as the window.
        if (drawn !== null && lastOpacity < 0.999) fadeMs = at - drawn;
        resolve({
          drawn,
          header,
          shifted,
          moved,
          blank,
          frames,
          first,
          cadence,
          drawOpacity,
          fadeMs,
          fadeFrameMs,
          flashes,
          animated,
        });
        return false;
      });
    });
    const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
      .cmuxAcpmuxActions;
    await actions?.["chat.select"]?.({ sessionId });
    return result;
  };

  /// `phase` says which budget the run is held to, named rather than read out of `name`: the names
  /// carry the load the run was under ("loaded cached"), and a notice that guessed the budget from
  /// the name printed the cold one for every cached phase the moment a name changed.
  const report = (name: string, phase: "cold" | "cached", opened: Opened[], during: Measured[] = []) => {
    const drawn = opened.map((entry) => entry.drawn ?? Number.POSITIVE_INFINITY);
    const worst = Math.max(...drawn);
    console.log(
      `chat-open-perf ${name}: draws ${drawn.map((ms) => (Number.isFinite(ms) ? ms.toFixed(0) : "never")).join("/")} ms ` +
        `(header ${opened.map((entry) => (entry.header === null ? "never" : entry.header.toFixed(0))).join("/")} ms) ` +
        `(worst ${Number.isFinite(worst) ? worst.toFixed(0) : "never"}), ` +
        `shifted frames ${opened.map((entry) => entry.shifted).join("/")} (worst move ${Math.max(...opened.map((entry) => entry.moved)).toFixed(1)} px), ` +
        `blank frames ${opened.map((entry) => entry.blank).join("/")}, ` +
        `frames ${opened.map((entry) => entry.frames).join("/")}, ` +
        `frames to the draw ${opened.map((entry) => entry.cadence.join(",")).join(" | ")}, ` +
        `opacity at the draw ${opened.map((entry) => entry.drawOpacity.toFixed(2)).join("/")}, ` +
        `fade ${opened.map((entry) => entry.fadeMs.toFixed(0)).join("/")} ms ` +
        `(longest frame in it ${opened.map((entry) => entry.fadeFrameMs.toFixed(0)).join("/")} ms), ` +
        `flashes ${opened.map((entry) => entry.flashes).join("/")}, ` +
        `animated ${JSON.stringify(opened.map((entry) => entry.animated))}` +
        (opened.some((entry) => entry.first)
          ? `, first bad frame ${JSON.stringify(opened.find((entry) => entry.first)!.first)}`
          : ""),
    );
    // What a passing run leaves behind. A file that passes has its log thrown away
    // (scripts/ci/run-webviews-tests.sh keeps only workflow annotations of one), so until this the
    // margins of the one gate on chat-open speed were readable on a red run only: nobody could see
    // a budget it was about to miss, on CI or on a fleet mini. A notice survives both.
    // The brief's budget is named apart from the ceiling asserted, which is that plus the dev
    // bundle's render frame: a cold open back at 520 ms is comfortably inside the ceiling and 120 ms
    // outside what Leo asked for, and this line is all a green run leaves to read it in.
    const asked = phase === "cached" ? CACHED_PAINT_MS : COLD_PAINT_MS;
    const cadence = opened.map((entry) => entry.cadence.length);
    console.log(
      `::notice title=chat-open-perf (${name})::worst draw ` +
        `${Number.isFinite(worst) ? worst.toFixed(0) : "never"} ms of ${asked} ms asked for ` +
        `(${asked + DEV_RENDER_MS} ms the ceiling here, the dev bundle's render frame on top), ` +
        `draw frame count ${cadence.join("/")}` +
        (phase === "cached" ? ` of ${CACHED_DRAW_FRAMES} allowed` : "") +
        `, shifted frames ${opened.reduce((all, entry) => all + entry.shifted, 0)}, ` +
        `fade ${opened.map((entry) => entry.fadeMs.toFixed(0)).join("/")} ms (opacity at the draw ${opened.map((entry) => entry.drawOpacity.toFixed(2)).join("/")}), ` +
        `flashes ${opened.reduce((all, entry) => all + entry.flashes, 0)}, ` +
        `blank frames ${opened.reduce((all, entry) => all + entry.blank, 0)}, ` +
        `${CHAT_COUNT} chats, ${CALL_MS} ms a call and ${ATTACH_MS} ms an attach` +
        // In the notice, not only the log: the load each window ran under is the one number that
        // says whether a loaded phase measured anything, and a passing run keeps nothing else.
        (during.some((window) => window.pushes > 0)
          ? `, changes pushed while measured ${during.map((window) => window.pushes).join("/")}`
          : "") +
        (during.length > 0 ? `, attaches ${during.map((window) => window.attaches).join("/")}` : ""),
    );
    return worst;
  };

  /// Opens `picked` cold, then each again from the page's cache, and reports both phases.
  const openEachTwice = async (name: string) => {
    const page = await browser!.newPage({
      viewport: { width: 1000, height: 760 },
      ...(videoDir ? { recordVideo: { dir: videoDir, size: { width: 1000, height: 760 } } } : {}),
    });
    await installPaintedFrames(page);
    await page.goto(url(chats[0].sessionId));
    await page.getByText(chats[0].marker).waitFor();
    /// How many changes went out while this one open was measured, and how many attaches it cost.
    /// Per window, because the totals cannot say when the load arrived: the lanes start reporting
    /// the moment the socket opens, which is during the page load above, so a run's total is over
    /// its budget before the first chat is opened and a test on the total would pass with the load
    /// finished before anything was timed.
    const during: Measured[] = [];
    const open = async (entry: (typeof chats)[number]) => {
      const pushesBefore = pushed;
      const attachesBefore = attaches;
      const opened = (await page.evaluate(
        `(${openChat.toString()})(${JSON.stringify({
          sessionId: entry.sessionId,
          marker: entry.marker,
          title: entry.title,
          settleMs: SETTLE_MS,
          limitMs: 8_000,
        })})`,
      )) as Opened;
      during.push({ pushes: pushed - pushesBefore, attaches: attaches - attachesBefore });
      return opened;
    };
    const cold: Opened[] = [];
    const cached: Opened[] = [];
    try {
      for (const entry of picked) cold.push(await open(entry));
      // Each of them again: the page read every one of these chats already.
      for (const entry of picked) cached.push(await open(entry));
    } finally {
      // Always, so a failed open does not leave a page open with its socket still reporting.
      await page.close();
    }

    const loadDuring = { cold: during.slice(0, picked.length), cached: during.slice(picked.length) };
    const worstCold = report(`${name} cold`, "cold", cold, loadDuring.cold);
    const worstCached = report(`${name} cached`, "cached", cached, loadDuring.cached);
    return { cold, cached, worstCold, worstCached, loadDuring };
  };

  /// Holds one run's two phases to what the brief asks. `slack` is what the load phase may take on
  /// top of the quiet one in milliseconds: the frame counts, which are what actually tell a cached
  /// open from a cold one, are held to the same number either way.
  const holdToTheBrief = (
    { cold, cached, worstCold, worstCached }: Awaited<ReturnType<typeof openEachTwice>>,
    slack = 0,
  ) => {
    for (const opened of [...cold, ...cached]) {
      expect(opened.drawn).not.toBeNull();
      // Leo: "It should have no layout shift"; a row placed by an estimate then by its drawn
      // height moves, which is the flicker.
      expect(opened.shifted).toBe(0);
      // Leo: "no blank-then-pop"; every frame from the first draws the transcript.
      expect(opened.blank).toBe(0);
      expect(opened.frames).toBeGreaterThan(5);
      // Leo, 2026-10-21: "does it still flash/flicker?" The transcript's opacity only ever rises
      // once the chat drew, and the page's backdrop never changes under it.
      expect(opened.flashes).toBe(0);
    }
    // Leo, 2026-10-21: "no layout shift then a fast fade in, instant if cached". A chat read for
    // the first time draws in its place (the rules above), then fades in once: opacity only, no
    // slide or scale, over at most FADE_MS. The fade's own length is held exactly; the frames that
    // show it get one dev-bundle frame of slack, since the last frame of the fade lands on a frame.
    for (const opened of cold) {
      expect(opened.drawOpacity).toBeLessThan(1);
      expect(opened.animated.length).toBeGreaterThan(0);
      for (const animation of opened.animated) {
        expect(animation.properties).toEqual(["opacity"]);
        expect(animation.duration).toBeLessThanOrEqual(FADE_MS);
      }
      expect(opened.fadeMs).toBeGreaterThan(0);
      expect(opened.fadeMs).toBeLessThanOrEqual(FADE_MS + Math.max(FADE_FRAME_SLACK_MS, opened.fadeFrameMs) + slack);
    }
    // A chat the page holds is whole on the frame it draws: no fade, nothing animating it.
    for (const opened of cached) {
      expect(opened.drawOpacity).toBe(1);
      expect(opened.fadeMs).toBe(0);
      expect(opened.animated).toEqual([]);
    }
    // Leo: "instant if cached". This is what tells a cached open from a cold one here, and what a
    // regression would break: the chat draws in the first frames after the select, with no wait on
    // acpmux in between. A cold open takes ten-plus frames (the log's `draw frame count`), so the
    // few frames allowed leave room for a loaded runner without letting a round trip through. The
    // budgets below are the brief's plus the dev bundle's render frame, so they are a ceiling, not
    // the line between the two.
    for (const opened of cached) expect(opened.cadence.length).toBeLessThanOrEqual(CACHED_DRAW_FRAMES);
    expect(worstCached).toBeLessThan(CACHED_PAINT_MS + DEV_RENDER_MS + slack);
    expect(worstCold).toBeLessThan(COLD_PAINT_MS + DEV_RENDER_MS + slack);
  };

  test(`opening chats with ${CHAT_COUNT} in the list draws fast, with no shift and no blank frame`, async () => {
    holdToTheBrief(await openEachTwice("quiet"));
  });

  /// The transcript stays mounted across a switch, so a fade belongs to the chat it started for
  /// (the Codex review of #24113): a chat the page holds, opened while a chat read cold is still
  /// fading in, shows whole on the frame it draws, never under the other chat's fade.
  test("a cached chat opened while a cold chat fades in shows whole at once", async () => {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    try {
      await installPaintedFrames(page);
      await page.goto(url(chats[0].sessionId));
      await page.getByText(chats[0].marker).waitFor();
      const [held, fresh] = [picked[0]!, picked[1]!];
      const opening = (entry: (typeof chats)[number], settleMs: number) =>
        `(${openChat.toString()})(${JSON.stringify({
          sessionId: entry.sessionId,
          marker: entry.marker,
          settleMs,
          limitMs: 8_000,
        })})`;
      // Read once, so the page holds it.
      await page.evaluate(opening(held, SETTLE_MS));
      // In one page task: the held chat is selected on the frame the cold one first drew, while
      // its fade still runs.
      const { cold, cached } = (await page.evaluate(
        `(async () => { const cold = await ${opening(fresh, 0)}; const cached = await ${opening(held, SETTLE_MS)}; return { cold, cached }; })()`,
      )) as { cold: Opened; cached: Opened };
      expect(cold.drawOpacity).toBeLessThan(1);
      expect(cached.drawn).not.toBeNull();
      expect(cached.drawOpacity).toBe(1);
      expect(cached.animated).toEqual([]);
      expect(cached.flashes).toBe(0);
    } finally {
      await page.close();
    }
  });

  /// A row on screen is never taken back to nothing (the Codex review of #24113): a chat read cold
  /// whose agent speaks while its attach is still out draws that live row whole, and the read that
  /// lands under it later does not fade the transcript either.
  test("a live row drawn before a slow chat is read shows whole, with no fade after", async () => {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    try {
      await installPaintedFrames(page);
      await page.goto(url(chats[0].sessionId));
      await page.getByText(chats[0].marker).waitFor();
      const opened = (await page.evaluate(
        `(${openChat.toString()})(${JSON.stringify({
          sessionId: slowChat.sessionId,
          marker: LIVE_MARKER,
          title: slowChat.title,
          settleMs: SLOW_ATTACH_MS,
          limitMs: 8_000,
        })})`,
      )) as Opened;
      console.log(
        `chat-open-perf slow attach: live row ${opened.drawn?.toFixed(0) ?? "never"} ms, ` +
          `header ${opened.header?.toFixed(0) ?? "never"} ms (attach ${SLOW_ATTACH_MS} ms, hold 1500 ms)`,
      );
      expect(opened.drawn).not.toBeNull();
      expect(opened.drawOpacity).toBe(1);
      expect(opened.animated).toEqual([]);
      expect(opened.fadeMs).toBe(0);
      expect(opened.flashes).toBe(0);
      // The read landed inside the watch: the chat's own tail is on screen now.
      await page.getByText(slowChat.marker).waitFor({ timeout: 5_000 });
    } finally {
      await page.close();
    }
  });

  /// The other half of Leo's ask: "even with a high number of chats and high load?". Every working
  /// chat reports a change of its own while the reader opens chats, each newer than every chat in
  /// the list, so the client rebuilds its sessions and re-sorts them twenty times a second — the
  /// load a person with forty agents running puts on the pane, and the load under which a cached
  /// open must still land on the frame it lands on.
  ///
  /// The millisecond budgets get the dev bundle's render frame again as slack (a second unminified
  /// React render under this much traffic), because what this test is really for is the two things
  /// no amount of load may change: a cached open still draws within ``CACHED_DRAW_FRAMES`` frames,
  /// and no frame of either phase shifts a row or goes blank.
  test(`opening chats with ${BUSY_LANES} chats working draws fast, with no shift and no blank frame`, async () => {
    busy = true;
    try {
      const run = await openEachTwice("loaded");
      // The load was on while each open was measured, not merely on at some point in the run: a
      // window is the draw plus SETTLE_MS of watching, so half the ticks of the settle alone is a
      // floor no real window misses and a silent end to the load cannot pass. At least one either
      // way, so raising BUSY_TICK_MS past the settle cannot turn the floor into zero.
      const leastPerWindow = Math.max(1, Math.floor(SETTLE_MS / BUSY_TICK_MS / 2));
      // Asserted per phase and in place, so the red names which window was quiet instead of
      // printing a bare number out of six.
      expect(
        Object.fromEntries(
          Object.entries(run.loadDuring).map(([phase, windows]) => [
            phase,
            windows.map((window) => (window.pushes >= leastPerWindow ? "loaded" : window.pushes)),
          ]),
        ),
      ).toEqual({ cold: picked.map(() => "loaded"), cached: picked.map(() => "loaded") });
      holdToTheBrief(run, DEV_RENDER_MS);
    } finally {
      busy = false;
    }
  });

  /// HQ#5914, finding 3: the chat's permission groups and handoff, read with its attach, answer
  /// after it (a daemon whose permission store is busy). The rows draw on the attach page, not on
  /// the slowest of the three reads, and the same no-shift, no-blank rules hold.
  test("opening chats whose side reads outlast the attach draws on the attach", async () => {
    slowSideReads = true;
    try {
      const run = await openEachTwice("side reads");
      holdToTheBrief(run);
    } finally {
      slowSideReads = false;
    }
  });
});
