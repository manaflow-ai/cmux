// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The agent chat transcript keeps its scrollbar (Leo 2026-10-21: "WHY DOES THE FUCKING SCROLLBAR IN
// THE CHAT AREA KEEP FUCKING HIDING ITSELF ... SCROLLBAR IT SHOULD FUCKING SHOW", and "the scrollbar
// keeps flashing way too much whenever sending off new chats"). The transcript is a shown scroller
// (scrollers.ts SHOWN_SCROLLER_ATTRIBUTE): a thin thumb on no track that stays drawn while the chat
// overflows, at rest, after a scroll, and while a new turn comes in and the view follows it, with a
// lane that never changes width on any painted frame. The opt-in fade (Debug Settings
// agentPane.debug.scrollerFade, the theme's `scrollerFade`) hides it at rest and fades it out with
// an animation: some painted frames of the fade show the thumb part-way.
//
// Before: the transcript had the engine's own scroller. WebKit's overlay scroller in the app shows
// while the view scrolls and fades out a moment later, so it flashed on every follow of a new row
// and was gone at rest; headless engines draw a wide classic bar or none, never the thin one.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux that streams a
// new turn. Real Chromium (scrollbars on: headless hides them by default) and WebKit (the app's
// engine); CI fails the file when it cannot launch them (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-scrollbar-shown.test.ts", async () => {
  setDefaultTimeout(300_000);
  type Recording = Window & { __lanes?: number[]; __stopLanes?: () => void };
  const engines: [string, () => Promise<Browser>][] = [
    ["chromium", () => chromium.launch({ headless: true, timeout: 30_000, ignoreDefaultArgs: ["--hide-scrollbars"] })],
    ["webkit", () => webkit.launch({ headless: true, timeout: 30_000 })],
  ];
  // An engine that cannot launch here is skipped and says so; on GitHub Actions requireBrowserLane
  // fails the file first, so CI runs both.
  const launchers: [string, () => Promise<Browser>][] = [];
  for (const [name, launch] of engines) {
    try {
      await (await launch()).close();
      launchers.push([name, launch]);
    } catch {
      console.warn(`agent-pane-scrollbar-shown: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (launchers.length === 0) {
    describe.skip("agent-pane-scrollbar-shown", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000f5b1";
  const TURNS = 30;
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const opening: Record<string, unknown>[] = [];
  const push = (dir: string, kind: string, msg: Record<string, unknown>) =>
    opening.push({ sessionId: CHAT, seq: opening.length + 1, at: START + opening.length * 1000, dir, kind, msg });
  const chunk = (text: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  });
  for (let n = 1; n <= TURNS; n++) {
    push("mux", "user_message", { text: `Question ${n}` });
    push("mux", "turn_started", {});
    push("in", "agent_message_chunk", chunk(`Answer ${n}: the checks on the merged head are green.`));
    push("mux", "turn_result", { status: "completed" });
  }
  let seq = opening.length;
  let running = false;
  const summary = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Scrollbar",
    harness: "claude",
    family: "claude",
    status: running ? "running" : "ready",
    ...(running ? { turn: { turnId: "turn-new", promptId: "p-new", startedAt: Date.now(), prompt: "One more" } } : {}),
    turnCount: TURNS,
    updatedAt: Date.now(),
    lastSeq: seq,
  });
  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: seq, events: opening, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      default:
        return null;
    }
  }

  type Socket = { send(data: string): void };
  let socket: Socket | undefined;
  /// One record of the new turn, as acpmux relays it live.
  const live = (dir: string, kind: string, msg: Record<string, unknown>) =>
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: CHAT, seq: ++seq, at: Date.now(), dir, kind, msg },
      }),
    );

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
          socket = ws;
        },
        message(ws, raw) {
          socket = ws;
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
    for (const [name, launch] of launchers) browsers.set(name, await launch());
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(name: string): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Answer ${TURNS}:`, { exact: false }).waitFor({ timeout: 120_000 });
    await page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
    });
    await painted(page, 3);
    return page;
  }

  const painted = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let left = count; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  /// Lets `ms` of the page's time pass, frame by frame (an overlay scroller fades about a second
  /// after its last scroll; the fade is what is under test, so the wait is the behavior's own time).
  const paintedFor = (page: Page, ms: number) =>
    page.evaluate(
      (ms) =>
        new Promise<void>((done) => {
          const from = performance.now();
          window.cmuxAfterPaint(() => {
            if (performance.now() - from < ms) return true;
            done();
            return false;
          });
        }),
      ms,
    );

  /// Records the transcript's scrollbar lane after every painted frame.
  const recordLanes = (page: Page) =>
    page.evaluate(() => {
      const lanes: number[] = [];
      const page = window as Recording;
      page.__lanes = lanes;
      page.__stopLanes = window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        lanes.push(scroller.offsetWidth - scroller.clientWidth);
      });
    });
  const recordedLanes = (page: Page) =>
    page.evaluate(() => {
      const page = window as Recording;
      page.__stopLanes?.();
      return page.__lanes ?? [];
    });

  /// The transcript's scrollbar lane as the page draws it: how many pixel rows of the lane differ
  /// from the gutter beside it (a thumb, not a track, when some do and most do not), and the
  /// largest difference (how much ink the thumb has).
  async function thumb(page: Page) {
    await painted(page, 1);
    const box = await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const rect = scroller.getBoundingClientRect();
      return {
        right: rect.right,
        top: rect.top,
        height: rect.height,
        bar: scroller.offsetWidth - scroller.clientWidth,
      };
    });
    if (box.bar <= 0) return { bar: box.bar, thumb: false, track: false, ink: 0 };
    const shot = await page.screenshot({
      clip: { x: box.right - box.bar - 4, y: box.top, width: box.bar + 4, height: Math.floor(box.height) },
    });
    const png = PNG.sync.read(shot);
    const at = (x: number, y: number) => {
      const index = (y * png.width + x) * 4;
      return [png.data[index]!, png.data[index + 1]!, png.data[index + 2]!];
    };
    let drawn = 0;
    let ink = 0;
    for (let y = 0; y < png.height; y++) {
      const beside = at(1, y);
      let row = 0;
      for (let x = 4; x < png.width; x++) {
        const pixel = at(x, y);
        row = Math.max(
          row,
          Math.abs(pixel[0]! - beside[0]!) + Math.abs(pixel[1]! - beside[1]!) + Math.abs(pixel[2]! - beside[2]!),
        );
      }
      if (row > 24) drawn++;
      ink = Math.max(ink, row);
    }
    return { bar: box.bar, thumb: drawn >= 8, track: drawn > png.height - 8, ink };
  }
  /// The thin scroller's widest lane; WebKit's and Chromium's classic bars are 15 px.
  const THIN = 10;

  /// Scrolls the transcript up with the wheel over its middle, then waits for it to settle.
  async function wheelUp(page: Page) {
    await page.mouse.move(450, 300);
    await page.mouse.wheel(0, -900);
    await painted(page, 6);
  }

  /// A new turn comes in at the latest row, the view following it: the prompt, then a reply in
  /// fifteen chunks of a few lines each.
  async function newTurn(page: Page, onChunk?: (index: number) => Promise<void>) {
    running = true;
    live("mux", "user_message", { text: "One more question", promptId: "p-new", turnId: "turn-new" });
    live("mux", "turn_started", {});
    for (let index = 0; index < 15; index++) {
      live(
        "in",
        "agent_message_chunk",
        chunk(`\n\nPart ${index + 1}: the follow-up run is green on every lane, and the merged head still builds.`),
      );
      await painted(page, 4);
      await onChunk?.(index);
    }
    live("mux", "turn_result", { status: "completed" });
    running = false;
    await page.getByText("Part 15:", { exact: false }).waitFor({ timeout: 30_000 });
    await painted(page, 4);
  }

  for (const [name] of launchers) {
    describe(name, () => {
      test("the thumb stays drawn at rest, after a scroll and while a new turn comes in, on a lane that never changes", async () => {
        const page = await open(name);
        await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTheme({ isDark: true }));
        await recordLanes(page);
        const seen: Record<string, Awaited<ReturnType<typeof thumb>>> = {};
        await paintedFor(page, 2000);
        seen.rest = await thumb(page);
        await wheelUp(page);
        await paintedFor(page, 2000);
        seen["after a scroll"] = await thumb(page);
        // Back to the latest row, where a new turn follows.
        await page.mouse.wheel(0, 100_000);
        await painted(page, 6);
        await newTurn(page, async (index) => {
          if (index === 7) seen["mid-turn"] = await thumb(page);
        });
        await paintedFor(page, 2000);
        seen["after the turn"] = await thumb(page);
        const lanes = await recordedLanes(page);
        await page.close();

        const shown = Object.fromEntries(
          Object.entries(seen).map(([at, sample]) => [at, sample.thumb && !sample.track && sample.bar <= THIN]),
        );
        expect({ seen, shown }).toEqual({
          seen,
          shown: Object.fromEntries(Object.keys(seen).map((at) => [at, true])),
        });
        // One lane on every painted frame: never a frame without a scrollbar, never a wide one.
        expect(lanes.length).toBeGreaterThan(30);
        expect([...new Set(lanes)]).toEqual([seen.rest!.bar]);
        expect(seen.rest!.bar).toBeGreaterThan(0);
      });

      test("with the opt-in fade the thumb hides at rest, shows on a scroll and fades out over several frames", async () => {
        const page = await open(name);
        await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTheme({ isDark: true, scrollerFade: true }));
        // A slower fade out than the pane's 180 ms, so screenshots land inside it on a loaded runner,
        // and an instant fade in, so the sample taken while it scrolls has the thumb's full ink.
        await page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.style.setProperty("--cmux-scroller-fade-out", "1500ms");
          scroller.style.setProperty("--cmux-scroller-fade-in", "0ms");
        });
        await paintedFor(page, 2000);
        const rest = await thumb(page);
        await wheelUp(page);
        const scrolling = await thumb(page);
        // The mark clears 800 ms after the last scroll (SCROLLING_HIDE_MS); then the fade runs.
        const fade: number[] = [];
        const from = Date.now();
        while (Date.now() - from < 3200) fade.push((await thumb(page)).ink);
        await paintedFor(page, 500);
        const after = await thumb(page);
        await page.close();

        expect({ rest: rest.thumb, scrolling: scrolling.thumb, after: after.thumb }).toEqual({
          rest: false,
          scrolling: true,
          after: false,
        });
        // Part-way frames: some samples between the shown ink and none.
        const full = scrolling.ink;
        const partWay = fade.filter((ink) => ink > full * 0.15 && ink < full * 0.85);
        expect({ full, fade, partWay: partWay.length > 0 }).toEqual({ full, fade, partWay: true });
      });
    });
  }
});
