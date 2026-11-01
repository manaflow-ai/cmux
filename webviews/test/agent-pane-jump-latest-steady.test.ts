// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Jump to latest holds still while the reader scrolls up (Leo 2026-10-28: "when I scroll up, I don't
// want to see that fucking, like, jump to bottom button be jumping around jittering and flickering
// like that"). In the real agent pane, the reader wheels up for two seconds in small trackpad steps
// while a reply streams below and, in the second case, older history pages in above. Every painted
// frame records the control's drawn box, whether it is shown, and its opacity. Once it starts to
// show it shows for good: it turns on once and never off, its box never moves, and its opacity only
// rises.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// that streams the reply. Each case runs in Chromium and WebKit (the app draws the pane in WebKit)
// from `playwright install chromium webkit`; an engine that is not installed is skipped and says so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-jump-latest-steady.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `agent-pane-jump-latest-steady: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("jump to latest holds still", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000f051";
  const START = Date.UTC(2026, 9, 28, 9, 0, 0);
  const TURNS = 160;
  /// The turns the attach answers with; older ones page in as the reader nears the top.
  const LATEST_TURNS = 30;
  const PAGE_TURNS = 30;
  const chunk = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: CHAT, seq: events.length + 1, at: START + events.length * 1000, dir, kind, msg };
    events.push(event);
    return event;
  };
  for (let n = 1; n <= TURNS; n++) {
    record("mux", "user_message", { text: `Question ${n}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Answer ${n}: the checks on the merged head are green, and the retry waits a little longer ` +
          `each time with jitter so two clients never hammer the daemon together.`,
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  /// The chat as each page opens it: a reply streamed by an earlier case is not part of it.
  const opened = events.length;
  /// Whether this page's attach answers with the latest turns only, paging the rest in.
  let paged = false;
  /// Older pages the stand-in has answered for this page.
  let olderServed = 0;
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Jump to latest holds still",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq: events.length,
  });
  const firstLatest = () => (TURNS - LATEST_TURNS) * 4 + 1;

  function answer(method: string, params: Record<string, unknown> | undefined): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach": {
        const shown = paged ? events.filter((event) => event.seq >= firstLatest()) : [...events];
        return { session: session(), lastSeq: events.length, events: shown, hasMore: paged };
      }
      case "_acpmux/events": {
        const before = typeof params?.beforeSeq === "number" ? params.beforeSeq : undefined;
        if (before === undefined) return { events: [], hasMore: false, lastSeq: events.length };
        const older = events.filter((event) => event.seq < before).slice(-PAGE_TURNS * 4);
        if (older.length) olderServed++;
        return { events: older, hasMore: (older[0]?.seq ?? 1) > 1, lastSeq: older.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  }

  type Socket = { send(data: string): void };
  const sockets = new Set<Socket>();
  const send = (event: Event) => {
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
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
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(name: string, withPages: boolean): Promise<Page> {
    events.length = opened;
    paged = withPages;
    olderServed = 0;
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
    // The control's own motion is what is measured: the page keeps its animations on.
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 60_000 });
    await untilStill(page);
    return page;
  }

  /// Resolves once the offset and the content's height have held for 200ms of painted frames.
  const untilStill = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const read = () => `${scroller.scrollTop}:${scroller.scrollHeight}`;
          let last = read();
          let since = performance.now();
          window.cmuxAfterPaint((frame) => {
            const seen = read();
            if (seen !== last) [last, since] = [seen, frame];
            if (frame - since < 200) return true;
            resolve();
            return false;
          });
        }),
    );

  type Frame = {
    at: number;
    shown: boolean;
    opacity: number;
    x: number;
    y: number;
    w: number;
    h: number;
    fromEnd: number;
  };
  /// Records the control after every painted frame, read as the frame paints (a ResizeObserver on a
  /// probe resized in each frame's callbacks, as agent-pane-jump-latest-motion does), until `stop`.
  const startFrames = (page: Page) =>
    page.evaluate(() => {
      const holder = window as unknown as { __jumpFrames?: Frame[] };
      const frames: Frame[] = [];
      holder.__jumpFrames = frames;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
      document.body.append(probe);
      let wide = false;
      const read = (frame: number) => {
        const control = document.querySelector<HTMLElement>(".acpmux-jump-latest");
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const fromEnd = Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight);
        if (!control) {
          frames.push({ at: frame, shown: false, opacity: 0, x: 0, y: 0, w: 0, h: 0, fromEnd });
          return;
        }
        const box = control.getBoundingClientRect();
        frames.push({
          at: frame,
          shown: control.hasAttribute("data-shown"),
          opacity: Number(getComputedStyle(control).opacity),
          x: box.x,
          y: box.y,
          w: box.width,
          h: box.height,
          fromEnd,
        });
      };
      const observer = new ResizeObserver(() => read(performance.now()));
      observer.observe(probe);
      window.cmuxAfterPaint(
        () => {
          if (holder.__jumpFrames === frames) return;
          observer.disconnect();
          probe.remove();
          return false;
        },
        () => {
          wide = !wide;
          probe.style.width = wide ? "2px" : "1px";
        },
      );
    });
  const stopFrames = (page: Page) =>
    page.evaluate(() => {
      const holder = window as unknown as { __jumpFrames?: Frame[] };
      const frames = holder.__jumpFrames ?? [];
      holder.__jumpFrames = undefined;
      return frames;
    });

  /// What the reader sees of the control over the frames: how often it turned on or off, how often
  /// its drawn box moved once it began to show, and how often its opacity fell while shown.
  function tally(frames: Frame[]) {
    let flips = 0;
    const flipLog: string[] = [];
    for (let index = 1; index < frames.length; index++)
      if (frames[index]!.shown !== frames[index - 1]!.shown) {
        flips++;
        flipLog.push(`${index}:${frames[index]!.shown ? "on" : "off"}@${frames[index]!.fromEnd}`);
      }
    const from = frames.findIndex((frame) => frame.shown);
    const visible = from < 0 ? [] : frames.slice(from);
    let moves = 0;
    let dips = 0;
    const moveLog: string[] = [];
    for (let index = 1; index < visible.length; index++) {
      const [a, b] = [visible[index - 1]!, visible[index]!];
      if (Math.abs(a.x - b.x) > 0.5 || Math.abs(a.y - b.y) > 0.5 || Math.abs(a.w - b.w) > 0.5) {
        moves++;
        if (moveLog.length < 12) moveLog.push(`${from + index}:dy${(b.y - a.y).toFixed(1)}`);
      }
      if (b.opacity < a.opacity - 0.001) dips++;
    }
    const last = frames.at(-1);
    return {
      frames: frames.length,
      flips,
      moves,
      dips,
      shownAtEnd: last?.shown ?? false,
      opacityAtEnd: last?.opacity,
      flipLog: flipLog.slice(0, 12),
      moveLog,
    };
  }

  /// Two seconds of upward trackpad steps over the transcript while a reply streams below: `step(n)`
  /// px at the nth frame painted (12px each by default), and a paragraph of the reply every
  /// `chunkEvery` frames.
  async function scrollUpWhileStreaming(page: Page, step = (_n: number) => 12, chunkEvery = 4) {
    const view = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(view.x + view.width / 2, view.y + 160);
    send(record("mux", "turn_started", {}));
    send(record("in", "agent_message_chunk", chunk("Streaming the reply: ")));
    // Hidden, the control is inert (out of the accessibility tree): find it by its label.
    await page
      .locator('.acpmux-jump-latest[aria-label="Jump to latest, still replying"]')
      .waitFor({ state: "attached" });
    await untilStill(page);
    await startFrames(page);
    const began = Date.now();
    let frame = 0;
    while (Date.now() - began < 2000) {
      await page.mouse.wheel(0, -step(frame));
      if (frame++ % chunkEvery === 0)
        send(
          record(
            "in",
            "agent_message_chunk",
            chunk(`paragraph ${frame}: the reader scrolls up while this streams.\n\n`),
          ),
        );
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await untilStill(page);
    const frames = await stopFrames(page);
    send(record("mux", "turn_result", { status: "completed" }));
    return frames;
  }

  test.each(engines.map(([name]) => name))(
    "%s: scrolling up while a reply streams, Jump to latest shows once and holds still",
    async (name) => {
      const page = await open(name, false);
      const frames = await scrollUpWhileStreaming(page);
      const seen = tally(frames);
      console.info("jump-latest steady (stream)", JSON.stringify({ engine: name, ...seen }));
      await page.close();
      expect(seen.shownAtEnd).toBe(true);
      expect(seen.opacityAtEnd).toBe(1);
      expect(seen.flips).toBe(1);
      expect(seen.moves).toBe(0);
      expect(seen.dips).toBe(0);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a trackpad's first small steps up while every frame streams, Jump to latest shows once and holds still",
    async (name) => {
      const page = await open(name, false);
      // A gesture starts slow (a pixel, then two...) and speeds up; the reply grows every frame.
      const frames = await scrollUpWhileStreaming(page, (n) => Math.min(12, 1 + Math.floor(n / 3)), 1);
      const seen = tally(frames);
      console.info("jump-latest steady (slow start)", JSON.stringify({ engine: name, ...seen }));
      await page.close();
      expect(seen.shownAtEnd).toBe(true);
      expect(seen.flips).toBe(1);
      expect(seen.moves).toBe(0);
      expect(seen.dips).toBe(0);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a gesture that turns back and forth near where it shows, Jump to latest shows once and holds still",
    async (name) => {
      const page = await open(name, false);
      const view = (await page.locator(".acpmux-scroll").boundingBox())!;
      await page.mouse.move(view.x + view.width / 2, view.y + 160);
      await startFrames(page);
      const wheel = async (dy: number, steps: number) => {
        for (let index = 0; index < steps; index++) {
          await page.mouse.wheel(0, dy);
          await page.evaluate(() => window.cmuxPaintFrame());
        }
      };
      // Up past where it shows (80px from the end), then a trackpad's back-and-forth around there:
      // down to 60px from the end and up to 120px, four times, never reaching the latest message.
      await wheel(-10, 12);
      for (let turn = 0; turn < 4; turn++) {
        await wheel(6, 10);
        await wheel(-6, 10);
      }
      await untilStill(page);
      const frames = await stopFrames(page);
      const seen = tally(frames);
      console.info("jump-latest steady (back and forth)", JSON.stringify({ engine: name, ...seen }));
      await page.close();
      // It never reached the latest message, where it rightly hides.
      const away = frames.slice(frames.findIndex((frame) => frame.shown));
      expect(Math.min(...away.map((frame) => frame.fromEnd))).toBeGreaterThan(20);
      expect(seen.shownAtEnd).toBe(true);
      expect(seen.flips).toBe(1);
      expect(seen.moves).toBe(0);
      expect(seen.dips).toBe(0);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: scrolling up while older history pages in and a reply streams, Jump to latest holds still",
    async (name) => {
      const page = await open(name, true);
      const frames = await scrollUpWhileStreaming(page);
      // Keep going up until an older page has landed, still recording.
      await startFrames(page);
      for (let step = 0; step < 60; step++) {
        await page.mouse.wheel(0, -60);
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await untilStill(page);
      frames.push(...(await stopFrames(page)));
      const seen = tally(frames);
      const pages = olderServed;
      console.info("jump-latest steady (paging)", JSON.stringify({ engine: name, pages, ...seen }));
      await page.close();
      expect(pages).toBeGreaterThan(0);
      expect(seen.shownAtEnd).toBe(true);
      expect(seen.flips).toBe(1);
      expect(seen.moves).toBe(0);
      expect(seen.dips).toBe(0);
    },
  );
});
