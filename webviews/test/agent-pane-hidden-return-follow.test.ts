// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat the reader comes back to shows what streamed while it was hidden at rest, where it lies
// (Leo, 2026-11-11: "we just ran into this CRAZY display animation where a new message from you
// seemed to come down from the heavens... austin was navigating between workspaces and there was
// existing tool calls adn messages and a sliver of space at the bottom that the newest few lines
// started from the top").
//
// Each workspace's chat page stays alive and hides (`visibilityState`) while another workspace
// shows (shared/pageReveal.ts): WebKit draws no frames for it and runs no `requestAnimationFrame`
// callbacks, and the transcript's text stream waits for the page to show (direct.ts `nextFrame`),
// while other changes (a call finishing, a new call) still commit while it is hidden. The page here
// hides the same way: `visibilityState` reads "hidden", `visibilitychange` fires, and frame
// callbacks wait until it shows again. Variants: the pane keeps its size while hidden, the pane is
// laid out at no size (`display: none`), and the window shrinks while hidden.
//
// One chat of 40 finished turns and a running one with two calls (support/papercutChat.ts), its
// reply streaming at the latest row, through the pane's dev entry and a stand-in acpmux. Every read
// is of a painted frame (support/paintedFrames.ts).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-hidden-return-follow.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-hidden-return-follow.test.ts", async () => {
  setDefaultTimeout(600_000);
  const engines: [string, BrowserType][] = [];
  const only = process.env.HIDDEN_RETURN_ENGINE;
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && only !== engine[0]) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`agent-pane-hidden-return-follow: skipping ${engine[0]}: ${String(error).slice(0, 400)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("hidden return follow", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const { events, session } = papercutEvents({ turns: 40, running: true });
  const answer = (method: string): unknown => {
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
  };
  let socket: { send(data: string): void } | undefined;
  let seq = events.length;
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const hear = (dir: string, kind: string, msg: Record<string, unknown>) => {
    seq += 1;
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: PAPERCUT_CHAT, seq, at: Date.now(), dir, kind, msg },
      }),
    );
  };
  const chunk = (text: string) =>
    hear(
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
    );
  const call = (id: string, status: string) =>
    hear(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: `bun test ${id}`,
        kind: "execute",
        status,
        rawInput: { command: `bun test ${id}` },
      }),
    );
  const callDone = (id: string) =>
    hear("in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }));

  const browsers = new Map<string, Browser>();
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
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
          socket = ws;
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
    await warmViteServer(vite, "/", { timeoutMs: 600_000, jobs: 4 });
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Hiding as WebKit hides a page another workspace covers: `visibilityState` reads "hidden",
  /// `visibilitychange` fires, and frame callbacks wait for the page to show (then run in its first
  /// frame). Installed before the page's scripts.
  const installHide = (page: Page) =>
    page.addInitScript(() => {
      let hidden = false;
      const raf = window.requestAnimationFrame.bind(window);
      const caf = window.cancelAnimationFrame.bind(window);
      const waiting = new Map<number, FrameRequestCallback>();
      let ids = 1 << 29;
      window.requestAnimationFrame = (run) => {
        if (!hidden) return raf(run);
        ids += 1;
        waiting.set(ids, run);
        return ids;
      };
      window.cancelAnimationFrame = (id) => {
        if (!waiting.delete(id)) caf(id);
      };
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => (hidden ? "hidden" : "visible"),
      });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
      (window as unknown as { chatnftHide: (next: boolean) => void }).chatnftHide = (next) => {
        hidden = next;
        document.dispatchEvent(new Event("visibilitychange"));
        if (!next) {
          const due = [...waiting.values()];
          waiting.clear();
          for (const run of due) raf(run);
        }
      };
    });
  const setHidden = (page: Page, hidden: boolean) =>
    page.evaluate(
      (hidden) => (window as unknown as { chatnftHide: (next: boolean) => void }).chatnftHide(hidden),
      hidden,
    );

  type Frame = {
    t: number;
    fromEnd: number;
    /// How far the newest row ends above the bottom stack (px).
    gap: number;
    /// The thread's drawn offset (followChase `translate`, px; negative: drawn up).
    thread: number;
    /// The newest rows' own drawn offsets (tailGlide and the like), px.
    rows: string;
    /// Finite animations running, with where they start.
    anims: string[];
    count: number;
  };
  const readFrame = () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const thread = document.querySelector<HTMLElement>(".acpmux-thread")!;
    const rows = document.querySelectorAll<HTMLElement>(".acpmux-thread .acpmux-row");
    const dock = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock")!;
    const shift = (node: Element) => {
      const style = getComputedStyle(node);
      const translate = style.translate && style.translate !== "none" ? (style.translate.split(" ")[1] ?? "0") : "0";
      const matrix = style.transform && style.transform !== "none" ? new DOMMatrix(style.transform).m42 : 0;
      return parseFloat(translate) + matrix;
    };
    const last = rows[rows.length - 1]!;
    return {
      fromEnd: scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight,
      gap: dock.getBoundingClientRect().top - last.getBoundingClientRect().bottom,
      thread: shift(thread),
      rows: [...rows]
        .slice(-4)
        .map((row) => shift(row).toFixed(1))
        .join(","),
      anims: document
        .getAnimations()
        .filter((animation) => {
          const end = animation.effect?.getComputedTiming().endTime;
          return animation.playState === "running" && end !== Infinity;
        })
        .map((animation) => {
          const effect = animation.effect as KeyframeEffect | null;
          const target = effect?.target as HTMLElement | null;
          const frames = effect?.getKeyframes?.() ?? [];
          const first = frames[0] as Record<string, unknown> | undefined;
          const what = first
            ? Object.entries(first)
                .filter(([key]) => !["offset", "easing", "composite", "computedOffset"].includes(key))
                .map(([key, value]) => `${key}=${String(value)}`)
                .join(";")
            : "";
          return `${target?.className?.toString().split(" ")[0] ?? "?"}:${(animation as CSSAnimation).animationName ?? ""}[${what}]`;
        }),
      count: rows.length,
    };
  };

  /// Each painted frame for `ms`, starting with the next one; `act` runs first.
  async function paintedFor(page: Page, ms: number, act?: () => Promise<unknown>): Promise<Frame[]> {
    const done = page.evaluate(
      (ms) =>
        new Promise<Frame[]>((resolve) => {
          const reader = (window as unknown as { readTranscriptFrame: () => Omit<Frame, "t"> }).readTranscriptFrame;
          const out: Frame[] = [];
          let start: number | undefined;
          window.cmuxAfterPaint((frame) => {
            start ??= frame;
            out.push({ t: Math.round(frame - start), ...reader() });
            if (frame - start < ms || out.length < 6) return true;
            resolve(out);
            return false;
          });
        }),
      ms,
    );
    await act?.();
    return done;
  }
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames++;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const rows = document.querySelectorAll<HTMLElement>(".acpmux-thread .acpmux-row");
            const dock = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock")!;
            const now = [
              scroller.scrollTop,
              scroller.scrollHeight,
              dock.getBoundingClientRect().top,
              rows[rows.length - 1]!.getBoundingClientRect().bottom,
            ].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 600) return true;
            resolve();
            return false;
          });
        }),
    );
  // fixed-wait: wall time is the behavior: a reply's chunks arrive over time, and a hidden page gets no frames to wait on.
  const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

  async function open(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 980, height: 700 } });
    await installHide(page);
    await installPaintedFrames(page);
    await page.addInitScript(`window.readTranscriptFrame = ${readFrame.toString()}`);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 120_000 });
    await settle(page);
    return page;
  }

  const LINE = "The parser keeps every token's span, and the checker reads them back in order.";
  const variants: { name: string; away?: (page: Page) => Promise<unknown>; back?: (page: Page) => Promise<unknown> }[] =
    [
      { name: "kept its size" },
      {
        name: "laid out at no size",
        away: (page) => page.evaluate(() => (document.body.style.display = "none")),
        back: (page) => page.evaluate(() => document.body.style.removeProperty("display")),
      },
      {
        name: "window shrunk",
        away: (page) => page.setViewportSize({ width: 980, height: 120 }),
        back: (page) => page.setViewportSize({ width: 980, height: 700 }),
      },
    ];
  const scenarios: { name: string; away: () => void }[] = [
    {
      name: "the reply streams on",
      away: () => {
        for (let n = 0; n < 8; n++) chunk(` ${LINE}\n\n`);
      },
    },
    {
      name: "calls finish, a new call and a new message segment",
      away: () => {
        callDone("r1");
        callDone("r2");
        call("r3", "in_progress");
        callDone("r3");
        for (let n = 0; n < 6; n++) chunk(` ${LINE}\n\n`);
      },
    },
    {
      name: "the turn ends",
      away: () => {
        for (let n = 0; n < 6; n++) chunk(` ${LINE}\n\n`);
        callDone("r1");
        callDone("r2");
        hear("mux", "turn_result", { status: "completed" });
      },
    },
  ];

  const summary = (frames: Frame[], rest: number) =>
    frames.map(
      (frame, index) =>
        `#${index} t=${frame.t} gap=${frame.gap.toFixed(1)} (rest ${rest.toFixed(1)}) fromEnd=${frame.fromEnd.toFixed(1)} thread=${frame.thread.toFixed(1)} rows=[${frame.rows}] n=${frame.count} ${frame.anims.join(" ")}`,
    );

  for (const [engine] of engines)
    describe(engine, () => {
      for (const variant of variants)
        for (const scenario of scenarios)
          test(`${scenario.name}, hidden and ${variant.name}: shown again, the newest rows rest where they lie`, async () => {
            // A fresh chat per test: the stand-in daemon's attach always starts from the fixture.
            seq = events.length;
            const page = await open(engine);
            // The reply starts streaming at the latest row, followed.
            for (let n = 0; n < 4; n++) {
              chunk(` ${LINE}\n\n`);
              // fixed-wait: chunks a live stream spaces out, not a condition.
              await pause(120);
            }
            await settle(page);
            const before = (await paintedFor(page, 0))[0]!;
            expect(before.fromEnd).toBeLessThanOrEqual(1.5);
            const rest = before.gap;
            // Away: another workspace shows.
            await setHidden(page, true);
            await variant.away?.(page);
            scenario.away();
            // Long enough for the hidden page's 50 ms draws of what is not text (direct.ts).
            // fixed-wait: a hidden page paints no frame and signals nothing to wait for.
            await pause(600);
            // Back.
            await variant.back?.(page);
            const frames = await paintedFor(page, 900, () => setHidden(page, false));
            await settle(page);
            const after = (await paintedFor(page, 0))[0]!;
            const lines = summary(frames, after.gap);
            if (process.env.HIDDEN_RETURN_VERBOSE)
              console.log(`${engine} | ${scenario.name} | ${variant.name}\n${lines.join("\n")}`);
            // Each frame from the first one back: the newest row ends where it rests over the bottom
            // stack (within 2 px, or a little above it while the reply's last lines still reveal), and
            // nothing draws the thread or the newest rows up above their layout and lets them fall.
            const tolerance = 2;
            const off = frames
              .map((frame, index) => ({ frame, index }))
              .filter(
                ({ frame }) =>
                  frame.fromEnd > 1.5 ||
                  frame.thread < -tolerance ||
                  frame.rows.split(",").some((value) => Number(value) < -tolerance) ||
                  frame.gap - after.gap > 24,
              )
              .map(({ index }) => lines[index]);
            expect({
              engine,
              scenario: scenario.name,
              variant: variant.name,
              rest,
              settled: after.gap,
              off: off.slice(0, 6),
            }).toEqual({
              engine,
              scenario: scenario.name,
              variant: variant.name,
              rest,
              settled: after.gap,
              off: [],
            });
            await page.close();
          });
    });
});
