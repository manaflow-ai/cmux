// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
// cmux-web-test-timeout: 420
//
// Leo, 2026-11-12: "it should essentially take a snapshot of, like, okay, whatever you just clicked
// on, that should be the breakpoint ... You put a breakpoint right at the moment that tick when you
// click into it, and then afterwards, that subsequent bit, then you can start playing animations ...
// you need to load it steady, and you don't jolt ... and you don't thrash ... if you try to scroll
// up, you can't really scroll much of anything up at all. Like it doesn't load enough."
//
// A cold-open harness: the agent pane (Vite dev server, real headless Chromium) opens a chat against
// a stand-in acpmux that pages as acpmux does (bench/daemonPage.ts: newest `limit` within `maxBytes`,
// the prompt index, the attach's turn opener), for two chats from bench/godFixture.ts: its ordinary
// `small` log (300 turns) and the full `god` log (7,000 turns, MB tool outputs, nested subagents).
// Every painted frame from the document's start is read (support/paintedFrames.ts), and one JSON line
// per chat is printed, `open-breakpoint: {...}`, so a PR can quote before and after:
//
//   framesToSettled / msToSettled  frames (and ms from navigation) to the first frame after which no
//                                  visible row moves or changes (top, height, text length, opacity)
//                                  for SETTLE_QUIET_MS;
//   rowsMovedAfterFirstPaint       rows visible at the first painted frame whose top later moved > 1 px,
//                                  with no input (target 0);
//   preBreakpointAnimations        opacity/transform animations or transitions started on rows that were
//                                  mounted at or before the first painted frame (target 0);
//   clears                         frames after first paint where the mounted row count fell to 0 or
//                                  below half the previous frame's (target 0; asserted);
//   screensAboveAtFirstPaint/At2s  (scrollTop - scroll origin) / clientHeight: how much a reader can
//                                  scroll up at the breakpoint and 2 s later (target >= 3 eventually);
//   screensMountedAboveAtFirstPaint/At2s
//                                  the height of rows actually mounted in the DOM above the viewport's
//                                  top / clientHeight: history drawn and ready to scroll into, not
//                                  the virtual list's estimated spacer (Leo, 2026-11-12: "if you try
//                                  to scroll up, you can't really scroll much of anything up at all");
//   loadedRowsAboveAtFirstPaint/At2s
//                                  rows in the transcript's model above the first visible row
//                                  (aria-posinset), mounted or not: what the open page held above;
//   msToThreeScreensMounted        ms from the first painted frame to the first frame with three screens
//                                  of rows mounted above the view (target: within the first older page's
//                                  round trip; the open page of the fixtures holds its last two turns,
//                                  half a screen, so the first frame cannot hold three);
//   leastScreensMountedAboveAfter  from then on, the fewest screens mounted above in any frame (target
//                                  >= 3; asserted, with screensMountedAboveAt2s >= 3);
//   reconnectRowsSubSecond         after settle the stand-in drops the socket and accepts the pane's
//                                  reconnect at once: frames showing [data-host-recovering] (target 0;
//                                  asserted).
//
// Held hard: `clears`, `reconnectRowsSubSecond`, `rowsMovedAfterFirstPaint`, every row the open page
// held above the view mounted at the first painted frame (up to three screens), and three screens
// mounted above by 2 s and in every frame after they first were. The rest are the deliverable, printed
// and checked to be finite.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { newestPage } from "../bench/daemonPage";
import { godLog, LATEST_TEXT, type ChatEvent, type Scale } from "../bench/godFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-open-breakpoint-harness.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-open-breakpoint-harness: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat open breakpoint harness", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  /// chat-open-long.test.ts's quiet daemon: a round trip, and what an attach costs on top.
  const LATENCY = { call: 20, attach: 150 };
  /// Nothing visible moved or changed for this long: the open has settled.
  const SETTLE_QUIET_MS = 1000;
  /// The second read of how far up the reader can scroll, after the first painted frame.
  const LATER_MS = 2000;
  /// The longest an open is watched for (from navigation) before it is reported unsettled.
  const LIMIT_MS = 60_000;
  /// After the reconnect's attach answered, frames are read this much longer.
  const AFTER_RECONNECT_MS = 1500;

  type Chat = { events: ChatEvent[]; session: Record<string, unknown> };
  /// godFixture's log at `scale` as the stand-in holds it (godChat's shape, for either scale).
  const chatOf = (scale: Scale, sessionId: string): Chat => {
    const log = godLog(scale);
    const events: ChatEvent[] = log.events.map((event) => ({
      sessionId,
      seq: event.seq,
      at: event.at,
      dir: event.dir,
      kind: event.kind,
      msg: event.msg as Record<string, unknown>,
    }));
    const session = {
      ...log.summary,
      sessionId,
      family: "claude",
      model: "claude-sonnet",
      status: "ready",
      turnCount: events.filter((event) => event.kind === "user_message").length,
      updatedAt: events.at(-1)!.at,
      lastSeq: events.length,
      currentModeId: "default",
    };
    return { events, session };
  };
  const built = performance.now();
  const chats: Record<Scale, Chat> = {
    small: chatOf("small", "0190a000-0000-7000-8000-0000000b0001"),
    god: chatOf("god", "0190a000-0000-7000-8000-0000000b0002"),
  };
  const fixtureMs = performance.now() - built;
  let current: Chat = chats.small;

  const answer = (method: string, params: Record<string, any>): unknown => {
    const { events, session } = current;
    const lastSeq = events.at(-1)?.seq ?? 0;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach": {
        const { page, hasMore } = newestPage(events, { limit: Number(params.limit ?? 400), maxBytes: params.maxBytes });
        // acpmux names the opener of the turn its page starts inside (server/requests/turn_opener.rs).
        let turnOpener: unknown = null;
        for (let at = (page[0]?.seq ?? 1) - 2; hasMore && at >= 0; at -= 1)
          if (events[at]!.kind === "user_message" && events[at]!.dir === "mux") {
            turnOpener = events[at];
            break;
          }
        return { session, lastSeq, events: page, hasMore, turnOpener };
      }
      case "_acpmux/events": {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, in one reply.
        if (params.promptIndex === true)
          return {
            events: events
              .filter((event) => event.kind === "user_message" && event.seq < before)
              .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } })),
            hasMore: false,
            lastSeq,
          };
        if (params.beforeSeq === undefined) return { events: [], hasMore: false, lastSeq };
        const { page, hasMore } = newestPage(events, {
          limit: Number(params.limit ?? 400),
          beforeSeq: before,
          maxBytes: params.maxBytes,
        });
        return { events: page, hasMore, lastSeq };
      }
      // A folder the person trusted long ago: no Trust card.
      case "acp.trust.get":
        return { cwd: current.session.cwd, level: "trusted" };
      default:
        return null;
    }
  };

  const sockets = new Set<{ close(code?: number, reason?: string): void }>();
  /// Date.now() of every socket open and every attach answer, in order.
  let opens: number[] = [];
  let attaches: number[] = [];
  const waiters: (() => void)[] = [];
  const heard = () => waiters.splice(0).forEach((wake) => wake());
  /// Resolves once `ready()` holds, checked at each socket open or attach answer (an event, not a poll;
  /// the test's own timeout bounds it).
  const when = (ready: () => boolean) =>
    new Promise<void>((resolve) => {
      const check = () => (ready() ? resolve() : void waiters.push(check));
      check();
    });

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${String(current.session.sessionId)}`;
  };

  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
          opens.push(Date.now());
          heard();
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          const attach = message.method === "_acpmux/attach";
          // fixed-wait: a quiet daemon's round trip is the condition under test (chat-open-long.test.ts).
          setTimeout(
            () => {
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
              if (attach) {
                attaches.push(Date.now());
                heard();
              }
            },
            attach ? LATENCY.attach : LATENCY.call,
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
    // One load of each chat warms Vite's transforms (the god chat's cards too), so the measured
    // loads time the pane, not the dev server.
    for (const scale of ["small", "god"] as const) {
      current = chats[scale];
      const warm = await browser.newPage({ viewport: { width: 1000, height: 760 } });
      await warm.goto(url());
      await warm.getByText(LATEST_TEXT, { exact: false }).first().waitFor({ timeout: 120_000 });
      await warm.close();
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Opened = {
    frames: number;
    firstPaintFrame: number | null;
    firstPaintMs: number | null;
    firstPaintClock: number | null;
    settledFrame: number | null;
    settledMs: number | null;
    settledClock: number | null;
    visibleAtFirstPaint: number;
    mountedAtFirstPaint: number;
    atLatestAtFirstPaint: boolean;
    rowsMovedAfterFirstPaint: number;
    worstMovePx: number;
    movedRows: string[];
    preBreakpointAnimations: number;
    animated: string[];
    containerAnimations: number;
    clears: number;
    firstClear: unknown;
    screensAboveAtFirstPaint: number | null;
    screensAboveAt2s: number | null;
    screensMountedAboveAtFirstPaint: number | null;
    screensMountedAboveAt2s: number | null;
    loadedRowsAboveAtFirstPaint: number | null;
    loadedRowsAboveAt2s: number | null;
    msToThreeScreensMounted: number | null;
    leastScreensMountedAboveAfter: number | null;
  };

  /// Runs in the page from its first script (closes over nothing): reads every painted frame until the
  /// open has settled and LATER_MS has passed since its first painted frame.
  const sampler = ({ quietMs, laterMs, limitMs }: { quietMs: number; laterMs: number; limitMs: number }) => {
    const state: Opened = {
      frames: 0,
      firstPaintFrame: null,
      firstPaintMs: null,
      firstPaintClock: null,
      settledFrame: null,
      settledMs: null,
      settledClock: null,
      visibleAtFirstPaint: 0,
      mountedAtFirstPaint: 0,
      atLatestAtFirstPaint: false,
      rowsMovedAfterFirstPaint: 0,
      worstMovePx: 0,
      movedRows: [],
      preBreakpointAnimations: 0,
      animated: [],
      containerAnimations: 0,
      clears: 0,
      firstClear: null,
      screensAboveAtFirstPaint: null,
      screensAboveAt2s: null,
      screensMountedAboveAtFirstPaint: null,
      screensMountedAboveAt2s: null,
      loadedRowsAboveAtFirstPaint: null,
      loadedRowsAboveAt2s: null,
      msToThreeScreensMounted: null,
      leastScreensMountedAboveAfter: null,
    };
    /// Rows mounted at or before the first painted frame (the breakpoint's rows).
    const early = new Set<string>();
    /// Each visible row's top at the first painted frame.
    const firstTops = new Map<string, number>();
    const moved = new Set<string>();
    const seen = new WeakSet<Animation>();
    const seenContainer = new WeakSet<Animation>();
    const MOTION = /^(opacity|transform|translate|scale|rotate|all)$/;
    const motion = (animation: Animation) => {
      const transition = (animation as Animation & { transitionProperty?: string }).transitionProperty;
      if (transition !== undefined) return MOTION.test(transition);
      const effect = animation.effect as KeyframeEffect | null;
      const frames = effect?.getKeyframes?.() ?? [];
      return frames.some((frame) => Object.keys(frame).some((key) => MOTION.test(key)));
    };
    const nameOf = (animation: Animation) =>
      (animation as Animation & { animationName?: string }).animationName ??
      (animation as Animation & { transitionProperty?: string }).transitionProperty ??
      animation.id ??
      "animation";
    const isEarlyRow = (row: HTMLElement | null) =>
      !!row && (state.firstPaintFrame === null || early.has(row.dataset.rowId ?? ""));
    const countOn = (row: HTMLElement, animation: Animation) => {
      if (seen.has(animation) || !motion(animation)) return;
      seen.add(animation);
      state.preBreakpointAnimations += 1;
      if (state.animated.length < 12) state.animated.push(`${row.dataset.rowId}:${nameOf(animation)}`);
    };
    // A short animation can start and end between two frames: its start event is read too.
    const started = (event: Event) => {
      if (state.settledFrame !== null && performance.now() > (state.firstPaintMs ?? 0) + laterMs) return;
      const target = event.target instanceof HTMLElement ? event.target : null;
      const row = target?.closest<HTMLElement>(".acpmux-row") ?? null;
      if (!target || !row || !isEarlyRow(row)) return;
      const name =
        event instanceof TransitionEvent
          ? event.propertyName
          : event instanceof AnimationEvent
            ? event.animationName
            : "";
      const live = target
        .getAnimations()
        .find(
          (animation) =>
            (animation as Animation & { animationName?: string }).animationName === name ||
            (animation as Animation & { transitionProperty?: string }).transitionProperty === name,
        );
      if (live) return countOn(row, live);
      if (event instanceof TransitionEvent && !MOTION.test(name)) return;
      state.preBreakpointAnimations += 1;
      if (state.animated.length < 12) state.animated.push(`${row.dataset.rowId}:${name}`);
    };
    document.addEventListener("animationstart", started, true);
    document.addEventListener("transitionstart", started, true);

    let previousMounted = -1;
    let previousSignature = "";
    let lastChange = { frame: 0, at: 0, clock: 0 };
    const screensAbove = (scroller: HTMLElement) => {
      const origin = Number.parseFloat(scroller.style.getPropertyValue("--acpmux-scroll-origin")) || 0;
      return scroller.clientHeight > 0 ? (scroller.scrollTop - origin) / scroller.clientHeight : null;
    };
    type Placed = { row: HTMLElement; rect: DOMRect };
    /// Mounted rows' height above the view's top, in viewports: what a reader can scroll up into with
    /// every pixel already drawn (a row straddling the top counts its part above).
    const mountedAbove = (scroller: HTMLElement, view: DOMRect, placed: Placed[]) => {
      if (scroller.clientHeight === 0) return null;
      let above = 0;
      for (const { rect } of placed)
        if (rect.width > 0) above += Math.max(0, Math.min(rect.bottom, view.top) - rect.top);
      return above / scroller.clientHeight;
    };
    /// Rows in the transcript above the first visible row (its aria-posinset), mounted or not.
    const loadedAbove = (visible: Placed[]) => {
      const first = visible.reduce<Placed | null>(
        (top, each) => (!top || each.rect.top < top.rect.top ? each : top),
        null,
      );
      const at = Number(first?.row.getAttribute("aria-posinset"));
      return Number.isFinite(at) && at > 0 ? at - 1 : null;
    };
    const done = new Promise<Opened>((resolve) => {
      window.cmuxAfterPaint(() => {
        const at = performance.now();
        state.frames += 1;
        const frame = state.frames;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (scroller) {
          const view = scroller.getBoundingClientRect();
          const mounted = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
          const placed = mounted.map((row) => ({ row, rect: row.getBoundingClientRect() }));
          const visible = placed.filter(
            ({ rect }) => rect.width > 0 && rect.bottom > view.top && rect.top < view.bottom,
          );
          const shows =
            visible.some(({ row }) => (row.textContent ?? "").trim() !== "") &&
            Number(getComputedStyle(scroller).opacity) > 0;
          const signature = visible
            .map(
              ({ row, rect }) =>
                `${row.dataset.rowId}:${Math.round(rect.top)}:${Math.round(rect.height)}:${(row.textContent ?? "").length}:${Number(getComputedStyle(row).opacity).toFixed(2)}`,
            )
            .join("|");
          if (signature !== previousSignature) lastChange = { frame, at, clock: Date.now() };
          previousSignature = signature;
          if (state.firstPaintFrame === null) {
            for (const { row } of placed) early.add(row.dataset.rowId ?? "");
            if (shows) {
              state.firstPaintFrame = frame;
              state.firstPaintMs = at;
              state.firstPaintClock = Date.now();
              state.visibleAtFirstPaint = visible.length;
              state.mountedAtFirstPaint = mounted.length;
              state.atLatestAtFirstPaint = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop <= 2;
              state.screensAboveAtFirstPaint = screensAbove(scroller);
              state.screensMountedAboveAtFirstPaint = mountedAbove(scroller, view, placed);
              state.loadedRowsAboveAtFirstPaint = loadedAbove(visible);
              for (const { row, rect } of visible) firstTops.set(row.dataset.rowId ?? "", rect.top);
            }
          } else {
            if (mounted.length === 0 || (previousMounted > 0 && mounted.length < previousMounted / 2)) {
              state.clears += 1;
              state.firstClear ??= { frame, at: Math.round(at), from: previousMounted, to: mounted.length };
            }
            for (const { row, rect } of placed) {
              const id = row.dataset.rowId ?? "";
              const was = firstTops.get(id);
              if (was === undefined || Math.abs(rect.top - was) <= 1) continue;
              state.worstMovePx = Math.max(state.worstMovePx, Math.abs(rect.top - was));
              if (moved.has(id)) continue;
              moved.add(id);
              if (state.movedRows.length < 8) state.movedRows.push(`${id}:${Math.round(rect.top - was)}`);
            }
            state.rowsMovedAfterFirstPaint = moved.size;
            const above = mountedAbove(scroller, view, placed);
            if (above !== null) {
              if (state.msToThreeScreensMounted === null && above >= 3)
                state.msToThreeScreensMounted = at - state.firstPaintMs!;
              // Once three screens were up, the least any later frame kept (scrolling up never hits a wall).
              if (state.msToThreeScreensMounted !== null)
                state.leastScreensMountedAboveAfter = Math.min(state.leastScreensMountedAboveAfter ?? above, above);
            }
            if (state.screensAboveAt2s === null && at >= state.firstPaintMs! + laterMs) {
              state.screensAboveAt2s = screensAbove(scroller);
              state.screensMountedAboveAt2s = mountedAbove(scroller, view, placed);
              state.loadedRowsAboveAt2s = loadedAbove(visible);
            }
          }
          previousMounted = mounted.length;
          // Animations on the breakpoint's rows (every row before the first painted frame).
          for (const row of mounted)
            if (isEarlyRow(row)) for (const animation of row.getAnimations({ subtree: true })) countOn(row, animation);
          for (const node of [scroller, document.querySelector<HTMLElement>(".acpmux-thread")])
            for (const animation of node?.getAnimations() ?? [])
              if (!seenContainer.has(animation) && motion(animation)) {
                seenContainer.add(animation);
                state.containerAnimations += 1;
              }
          if (state.firstPaintMs !== null && state.settledFrame === null && at - lastChange.at >= quietMs) {
            state.settledFrame = lastChange.frame;
            state.settledMs = lastChange.at;
            state.settledClock = lastChange.clock;
          }
        }
        const finished =
          state.firstPaintMs !== null && state.settledFrame !== null && at >= state.firstPaintMs + laterMs;
        if (!finished && at < limitMs) return;
        document.removeEventListener("animationstart", started, true);
        document.removeEventListener("transitionstart", started, true);
        resolve(state);
        return false;
      });
    });
    (window as { __openBreakpoint?: Promise<Opened> }).__openBreakpoint = done;
  };

  type Recovery = { frames: number; recovering: number; blank: number; leastVisible: number };
  /// Runs in the page: counts frames that show the recovering line; `__stopRecovery(ms)` resolves after
  /// the first painted frame `ms` past its call.
  const recoverySampler = () => {
    const state: Recovery = { frames: 0, recovering: 0, blank: 0, leastVisible: Number.POSITIVE_INFINITY };
    let until = Number.POSITIVE_INFINITY;
    let finish: ((state: Recovery) => void) | undefined;
    window.cmuxAfterPaint(() => {
      state.frames += 1;
      if (document.querySelector("[data-host-recovering]")) state.recovering += 1;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const view = scroller?.getBoundingClientRect();
      const visible = view
        ? [...scroller!.querySelectorAll<HTMLElement>(".acpmux-row")].filter((row) => {
            const rect = row.getBoundingClientRect();
            return rect.width > 0 && rect.bottom > view.top && rect.top < view.bottom;
          }).length
        : 0;
      if (visible === 0) state.blank += 1;
      state.leastVisible = Math.min(state.leastVisible, visible);
      if (performance.now() < until) return;
      finish?.(state);
      return false;
    });
    (window as { __stopRecovery?: (ms: number) => Promise<Recovery> }).__stopRecovery = (ms) =>
      new Promise<Recovery>((resolve) => {
        until = performance.now() + ms;
        finish = resolve;
      });
  };

  const openBreakpoint = async (scale: Scale) => {
    current = chats[scale];
    opens = [];
    attaches = [];
    const tab = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    try {
      await installPaintedFrames(tab);
      await tab.addInitScript(
        `(${sampler.toString()})(${JSON.stringify({ quietMs: SETTLE_QUIET_MS, laterMs: LATER_MS, limitMs: LIMIT_MS })})`,
      );
      const navigated = Date.now();
      await tab.goto(url());
      const opened = (await tab.evaluate(
        () => (window as unknown as { __openBreakpoint: Promise<unknown> }).__openBreakpoint,
      )) as Opened;
      const connected = opens[0] ?? navigated;

      // The socket drops once and the stand-in takes the pane's next connect at once.
      await tab.evaluate(`(${recoverySampler.toString()})()`);
      const opensBefore = opens.length;
      const attachesBefore = attaches.length;
      const dropped = Date.now();
      for (const socket of sockets) socket.close(1012, "restart");
      await when(() => opens.length > opensBefore);
      await when(() => attaches.length > attachesBefore);
      // Frames are read until AFTER_RECONNECT_MS of painted frames follow the reattach.
      const recovery = (await tab.evaluate(
        (ms) => (window as unknown as { __stopRecovery: (ms: number) => Promise<unknown> }).__stopRecovery(ms),
        AFTER_RECONNECT_MS,
      )) as Recovery;

      const round = (value: number | null, digits = 0) =>
        value === null || !Number.isFinite(value) ? null : Number(value.toFixed(digits));
      return {
        chat: scale,
        records: current.events.length,
        framesToSettled: opened.settledFrame,
        msToSettled: round(opened.settledMs),
        msToSettledAfterConnect: opened.settledClock === null ? null : opened.settledClock - connected,
        firstPaintFrame: opened.firstPaintFrame,
        msToFirstPaint: round(opened.firstPaintMs),
        msToFirstPaintAfterConnect: opened.firstPaintClock === null ? null : opened.firstPaintClock - connected,
        framesFirstPaintToSettled:
          opened.settledFrame === null || opened.firstPaintFrame === null
            ? null
            : opened.settledFrame - opened.firstPaintFrame,
        rowsMovedAfterFirstPaint: opened.rowsMovedAfterFirstPaint,
        worstMovePx: round(opened.worstMovePx),
        movedRows: opened.movedRows,
        preBreakpointAnimations: opened.preBreakpointAnimations,
        animated: opened.animated,
        containerAnimations: opened.containerAnimations,
        clears: opened.clears,
        firstClear: opened.firstClear,
        screensAboveAtFirstPaint: round(opened.screensAboveAtFirstPaint, 2),
        screensAboveAt2s: round(opened.screensAboveAt2s, 2),
        screensMountedAboveAtFirstPaint: round(opened.screensMountedAboveAtFirstPaint, 2),
        screensMountedAboveAt2s: round(opened.screensMountedAboveAt2s, 2),
        loadedRowsAboveAtFirstPaint: opened.loadedRowsAboveAtFirstPaint,
        loadedRowsAboveAt2s: opened.loadedRowsAboveAt2s,
        msToThreeScreensMounted: round(opened.msToThreeScreensMounted),
        leastScreensMountedAboveAfter: round(opened.leastScreensMountedAboveAfter, 2),
        visibleAtFirstPaint: opened.visibleAtFirstPaint,
        mountedAtFirstPaint: opened.mountedAtFirstPaint,
        atLatestAtFirstPaint: opened.atLatestAtFirstPaint,
        reconnectRowsSubSecond: recovery.recovering,
        reconnectMs: opens[opensBefore]! - dropped,
        reattachMs: attaches[attachesBefore]! - dropped,
        reconnectBlankFrames: recovery.blank,
        reconnectLeastVisibleRows: Number.isFinite(recovery.leastVisible) ? recovery.leastVisible : 0,
        reconnectFrames: recovery.frames,
        framesSampled: opened.frames,
      };
    } finally {
      await tab.close();
    }
  };

  for (const scale of ["small", "god"] as const)
    test(`a ${scale} chat opened cold: the open-breakpoint numbers`, async () => {
      const result = await openBreakpoint(scale);
      console.log(`open-breakpoint: ${JSON.stringify({ ...result, fixtureMs: Math.round(fixtureMs) })}`);
      // The deliverable is the line above; these only say the harness measured something.
      expect(result.firstPaintFrame).not.toBeNull();
      for (const value of [
        result.msToFirstPaint,
        result.rowsMovedAfterFirstPaint,
        result.preBreakpointAnimations,
        result.screensAboveAtFirstPaint,
      ])
        expect(Number.isFinite(value)).toBe(true);
      if (result.framesToSettled === null) console.log(`open-breakpoint: ${scale} never settled within ${LIMIT_MS} ms`);
      // Held hard: both are 0 on feat-cmux-next (281f9aa9). No frame after the breakpoint empties the
      // transcript, and a drop the stand-in takes back at once never shows "Reconnecting…".
      expect(result.clears).toBe(0);
      expect(result.reconnectRowsSubSecond).toBe(0);
      // Leo, 2026-11-12: "Like it doesn't load enough." History to scroll up into is drawn: what the
      // open page holds above the view is mounted in the first painted frame (the fixtures' pages hold
      // none: their last two turns fit the view), three screens are mounted above once the first older
      // page is in, and no later frame drops below that. Nothing visible moved to get there.
      expect(result.rowsMovedAfterFirstPaint).toBe(0);
      if ((result.loadedRowsAboveAtFirstPaint ?? 0) > 0)
        expect(result.screensMountedAboveAtFirstPaint!).toBeGreaterThan(0);
      expect(result.screensMountedAboveAt2s!).toBeGreaterThanOrEqual(3);
      expect(result.msToThreeScreensMounted).not.toBeNull();
      expect(result.leastScreensMountedAboveAfter!).toBeGreaterThanOrEqual(3);
    });
});
