// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Jump to latest after the composer grew while the reader was scrolled up (#23257), in the real
// agent pane. With cmux's animations off (`data-agent-motion="off"`, ui.animations.enabled) the
// jump lands at the end in one frame: no glide, and no glide aimed again at a moved end. With
// them on, a reply that streams in during the glide is followed: the view never steps back, lands
// at the latest row above the composer's card, and does so within the jump's settle window.
//
// Before: the jump checked only the system's Reduce Motion, so with cmux's animations off it still
// glided over many frames (review of #23257).
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

await requireBrowserLane("agent-pane-jump-latest-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
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
        `agent-pane-jump-latest-motion: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("jump to latest motion", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  /// App.tsx JUMP_LATEST_SETTLE_MS: the jump's landing, whether or not the glide arrived.
  const JUMP_LATEST_SETTLE_MS = 600;
  const CHAT = "0190a000-0000-7000-8000-00000000f021";
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
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
  for (let n = 1; n <= 40; n++) {
    record("mux", "user_message", { text: `Question ${n}` });
    record("mux", "turn_started", {});
    record("in", "agent_message_chunk", chunk(`Answer ${n}: the checks on the merged head are green.`));
    record("mux", "turn_result", { status: "completed" });
  }
  /// The chat as each page opens it: a reply streamed by an earlier case is not part of it.
  const opened = events.length;
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Jump to latest",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 40,
    updatedAt: START,
    lastSeq: events.length,
  });

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach":
        return { session: session(), lastSeq: events.length, events: [...events], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(name: string): Promise<Page> {
    events.length = opened;
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
    // The jump glides unless the person asked for reduced motion; these cases set cmux's own switch.
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 60_000 });
    await untilStill(page);
    return page;
  }

  /// The view and the composer's card: how far the view is from its end, and how far the last row's
  /// bottom sits above the card's top (negative: under the card).
  const measure = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const lines = [...scroller.querySelectorAll("p")];
      return {
        top: scroller.scrollTop,
        fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
        rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
        lastLine: lines.at(-1)?.textContent ?? "",
        lastLineAboveCard: Math.round(card.top - lines.at(-1)!.getBoundingClientRect().bottom),
        // The chat has no older pages, so the transcript's last row is the last of the set.
        lastIsLatest: last.getAttribute("aria-posinset") === last.getAttribute("aria-setsize"),
        cardHeight: Math.round(card.height),
      };
    });

  /// Resolves once the offset, the content's height and the card's height have held for 200ms of
  /// painted frames, so a read never lands mid-glide or before the last growth is painted.
  const untilStill = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const read = () => {
            const card = document.querySelector(".acpmux-composer-box")?.getBoundingClientRect().height;
            return `${scroller.scrollTop}:${scroller.scrollHeight}:${card}`;
          };
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

  type Frame = { at: number; top: number; height: number; fromEnd: number; rowAboveCard: number };
  /// Records the offset, the content's height, the distance from the end and the last row's place
  /// over the card after every painted frame, and when the jump was clicked, until `stopFrames`.
  const startFrames = (page: Page) =>
    page.evaluate(() => {
      const holder = window as unknown as { __frames?: Frame[]; __clickedAt?: number };
      const frames: Frame[] = [];
      holder.__frames = frames;
      holder.__clickedAt = undefined;
      document.addEventListener(
        "click",
        (event) => {
          if ((event.target as Element | null)?.closest?.(".acpmux-jump-latest"))
            holder.__clickedAt ??= performance.now();
        },
        { capture: true },
      );
      window.cmuxAfterPaint((frame) => {
        if (holder.__frames !== frames) return false;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const card = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = rows.reduce((a, b) =>
          Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
        );
        frames.push({
          at: frame,
          top: scroller.scrollTop,
          height: scroller.scrollHeight,
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
          rowAboveCard: Math.round(card.top - last.getBoundingClientRect().bottom),
        });
      });
    });
  /// The frames painted after the jump was clicked, and the click's time.
  const stopFrames = (page: Page) =>
    page.evaluate(() => {
      const holder = window as unknown as { __frames?: Frame[]; __clickedAt?: number };
      const frames = holder.__frames ?? [];
      holder.__frames = undefined;
      const clickedAt = holder.__clickedAt ?? Number.POSITIVE_INFINITY;
      return { clickedAt, frames: frames.filter((frame) => frame.at > clickedAt) };
    });

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
    await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
  }
  const atEnd = (page: Page) =>
    page.waitForFunction(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight <= 1;
    });

  // Review of #23257: the jump and its glide aimed again at a moved end checked only the system's
  // Reduce Motion, so with cmux's animations off they still glided.
  test.each(engines.map(([name]) => name))(
    "%s: with cmux's animations off, Jump to latest after the composer grew lands in one frame",
    async (name) => {
      const page = await open(name);
      const before = await measure(page);
      await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
      await growWhileScrolledUp(page);
      const start = (await measure(page)).top;
      await startFrames(page);
      await page.locator(".acpmux-jump-latest").click();
      await atEnd(page);
      await untilStill(page);
      const { frames } = await stopFrames(page);
      const end = await measure(page);
      expect({ fromEnd: end.fromEnd, lastIsLatest: end.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
      expect(end.top - start).toBeGreaterThan(400);
      expect(Math.abs(end.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
      // The first frame painted after the click is at the end, and no frame shows the way there.
      expect(frames.length).toBeGreaterThan(0);
      expect(frames[0]!.fromEnd).toBeLessThanOrEqual(1);
      expect(frames.filter((frame) => frame.top > start + 1 && frame.top < end.top - 1)).toEqual([]);
      await page.close();
    },
  );

  // Review of #23257: a reply that streams in while the jump glides moves the end under it. The
  // glide follows it there: never a step back, the latest row above the card at the end, landed
  // within the jump's settle window.
  test.each(engines.map(([name]) => name))(
    "%s: a reply streaming in during Jump to latest's glide is followed to its latest row",
    async (name) => {
      const page = await open(name);
      const before = await measure(page);
      await growWhileScrolledUp(page);
      const start = await measure(page);
      await startFrames(page);
      await page.locator(".acpmux-jump-latest").click();
      // The reply: a paragraph every frame painted, starting with the glide.
      send(record("mux", "turn_started", {}));
      for (let index = 1; index <= 12; index++) {
        send(
          record(
            "in",
            "agent_message_chunk",
            chunk(`Streamed paragraph ${index}: the retry waits a little longer each time, with jitter.\n\n`),
          ),
        );
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      send(record("mux", "turn_result", { status: "completed" }));
      await page.getByText("Streamed paragraph 12:", { exact: false }).waitFor({ state: "attached" });
      await atEnd(page);
      await untilStill(page);
      const { clickedAt, frames } = await stopFrames(page);
      const end = await measure(page);
      // At the end, the streamed reply's last line is the transcript's, whole above the card.
      expect({ fromEnd: end.fromEnd, lastIsLatest: end.lastIsLatest }).toEqual({ fromEnd: 0, lastIsLatest: true });
      expect(end.lastLine).toContain("Streamed paragraph 12:");
      expect(end.lastLineAboveCard).toBeGreaterThanOrEqual(0);
      expect(end.rowAboveCard).toBeGreaterThanOrEqual(-1);
      expect(Math.abs(end.rowAboveCard - before.rowAboveCard)).toBeLessThanOrEqual(2);
      expect(end.top - start.top).toBeGreaterThan(400);
      // The reply grew while the view was still on its way.
      const landed = frames.findIndex((frame) => frame.fromEnd <= 1);
      expect(landed).toBeGreaterThan(0);
      expect(frames.slice(0, landed).some((frame) => frame.height > frames[0]!.height)).toBe(true);
      // Landed within the settle window (with a few frames' slack), never a step back on the way.
      expect(frames[landed]!.at - clickedAt).toBeLessThanOrEqual(JUMP_LATEST_SETTLE_MS + 150);
      const tops = [start.top, ...frames.slice(0, landed + 1).map((frame) => frame.top)];
      expect(tops.slice(1).filter((top, index) => top < tops[index]! - 1)).toEqual([]);
      expect(frames.filter((frame) => frame.fromEnd <= 1 && frame.rowAboveCard < -1)).toEqual([]);
      await page.close();
    },
  );
});
