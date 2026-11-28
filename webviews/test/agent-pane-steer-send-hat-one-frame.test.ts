// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A steer sent while a turn runs: the composer hat (the strip over the composer) and the composer
// move as one, in the same painted frame, never the composer first and the hat after it. Leo,
// 2026-11-24: "hm recently upon send there's like a huge whole-pane flicker up down" / "composer hat
// seems to be getting a lot of flickers recently. it needs to stay tight like the composer".
//
// The real pane against a stand-in acpmux daemon (as agent-pane-composer-dock-motion.test.ts): a turn
// runs with a background command, so the hat shows over the composer; five lines are typed and sent
// with Return in steer mode. On every painted frame (paintedFrames.ts) it reads the composer box's top
// and the hat's box, and counts:
//   `hatGapFrames`: frames where the hat's bottom does not stand on the composer's top (it trails),
//   `hatHeightFrames`: frames where the hat's height changed (a collapse of its own),
//   `hatGoneFrames`: frames where the hat was not drawn at all after it showed,
//   `hatMoves`: separate moves of the hat's top (runs of motion split by three or more still frames).
// `CMUX_HAT_FRAMES=1` prints every frame's reading (the before/after capture).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-steer-send-hat-one-frame.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`steer-send-hat: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("steer send hat", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000e3";
  // `idle`: the same send from an idle chat, a fresh prompt that starts the turn, instead of a steer
  // into a running one. The background command still runs from the turn before: the hat shows it
  // before the send (the registry is read as the chat opens), so the turn the send starts brings
  // nothing in a beat after the composer cleared.
  let idle = false;
  let running = true;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Hat",
    harness: "claude",
    family: "claude",
    status: running ? "running" : "idle",
    steering: !idle,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 1,
    updatedAt: Date.now(),
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  let events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>) => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  let opened = 0;
  const methods: string[] = [];
  const history = () => {
    events = [];
    methods.length = 0;
    record("mux", "user_message", { text: "Fill the view", promptId: "p-0", turnId: "turn-1" });
    record("mux", "turn_started", { turnId: "turn-1" });
    for (let index = 0; index < 14; index++)
      record("in", "agent_message_chunk", {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: `History paragraph ${index}. Words that fill the view.\n\n` },
          },
        },
      });
    if (idle) record("mux", "turn_result", { stopReason: "end_turn" });
    running = !idle;
    opened = events.length;
  };
  history();
  let socket: { send(data: string): void } | undefined;
  const push = (event: Event) =>
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  function answer(method: string, params: Record<string, unknown> | undefined): unknown {
    methods.push(method);
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "_acpmux/process/list":
        return {
          processes: [
            {
              id: "proc-wait",
              sessionId: SESSION,
              command: "glaeda-gh wait run 42953147604 --timeout 2700",
              startedAt: Date.now() - 100 * 60_000,
              state: "running",
            },
          ],
        };
      case "session/prompt": {
        // acpmux steers the prompt into the running turn a little later (its echo).
        const prompt = (params?.prompt as { type: string; text?: string }[] | undefined) ?? [];
        const text = prompt.map((block) => block.text ?? "").join("");
        const meta = params?._meta as { acpmux?: { promptId?: string } } | undefined;
        const promptId = meta?.acpmux?.promptId ?? `p-${events.length}`;
        const echoMs = Number(process.env.CMUX_HAT_ECHO_MS ?? 60);
        if (idle) {
          setTimeout(() => {
            running = true;
            push(record("mux", "user_message", { text, promptId, turnId: "turn-2" }));
            push(record("mux", "turn_started", { turnId: "turn-2" }));
            socket?.send(
              JSON.stringify({
                jsonrpc: "2.0",
                method: "_acpmux/session_changed",
                params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
              }),
            );
          }, echoMs);
          return new Promise(() => {});
        }
        setTimeout(
          () => push(record("mux", "user_message", { text, promptId, turnId: "turn-1", steer: true })),
          echoMs,
        );
        return { stopReason: "steered" };
      }
      default:
        return null;
    }
  }

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
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.method === "_acpmux/attach") socket = ws;
          if (message.id !== undefined) {
            const result = answer(message.method, message.params);
            // An idle send's prompt runs its turn: no answer while the capture reads.
            if (!(result instanceof Promise)) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          }
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

  type Frame = {
    box: number;
    hatTop?: number;
    hatBottom?: number;
    hatHeight?: number;
    field: string;
    rowDy: number;
    bubble: boolean;
  };
  const sample = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: unknown[]; __stop: () => void };
      w.__frames = [];
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let lastRows = new Map<Element, number>();
      w.__stop = window.cmuxAfterPaint(() => {
        const view = scroller.getBoundingClientRect();
        const rows = new Map<Element, number>();
        for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")) {
          const rect = row.getBoundingClientRect();
          if (rect.height > 0.5 && rect.bottom > view.top && rect.top < view.bottom) rows.set(row, rect.top);
        }
        let rowDy = 0;
        for (const [row, top] of rows) {
          const before = lastRows.get(row);
          if (before !== undefined && Math.abs(top - before) > Math.abs(rowDy)) rowDy = top - before;
        }
        lastRows = rows;
        const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].some(
          (node) => (node.textContent ?? "").includes("Hat line five") && node.getClientRects().length > 0,
        );
        const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
        if (!box) return;
        const hat = document.querySelector<HTMLElement>(".acpmux-running-tray");
        const rect = hat && hat.getClientRects().length > 0 ? hat.getBoundingClientRect() : undefined;
        const field = document.querySelector<HTMLElement>(".acpmux-composer-box .ProseMirror");
        w.__frames.push({
          box: Math.round(box.getBoundingClientRect().top * 10) / 10,
          hatTop: rect && rect.height > 0.5 ? Math.round(rect.top * 10) / 10 : undefined,
          hatBottom: rect && rect.height > 0.5 ? Math.round(rect.bottom * 10) / 10 : undefined,
          hatHeight: rect && rect.height > 0.5 ? Math.round(rect.height * 10) / 10 : undefined,
          field: (field?.textContent ?? "").trim().slice(0, 12),
          rowDy: Math.round(rowDy * 10) / 10,
          bubble,
        });
      });
    });
  const stop = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: unknown[]; __stop: () => void };
      w.__stop();
      return w.__frames;
    }) as Promise<Frame[]>;

  function analyze(frames: Frame[]) {
    let hatGapFrames = 0;
    let hatHeightFrames = 0;
    let hatGoneFrames = 0;
    let seen = false;
    const gap0 = frames.find((frame) => frame.hatBottom !== undefined);
    const restGap = gap0 ? gap0.box - gap0.hatBottom! : 0;
    const moving: boolean[] = [];
    for (let index = 0; index < frames.length; index++) {
      const frame = frames[index]!;
      if (frame.hatBottom === undefined) {
        if (seen) hatGoneFrames += 1;
        moving.push(false);
        continue;
      }
      seen = true;
      if (Math.abs(frame.box - frame.hatBottom - restGap) > 1) hatGapFrames += 1;
      const last = frames[index - 1];
      if (last?.hatHeight !== undefined && Math.abs(frame.hatHeight! - last.hatHeight) > 0.5) hatHeightFrames += 1;
      moving.push(last?.hatTop !== undefined && Math.abs(frame.hatTop! - last.hatTop) > 0.5);
    }
    let hatMoves = 0;
    let still = 3;
    for (const move of moving) {
      if (move) {
        if (still >= 3) hatMoves += 1;
        still = 0;
      } else still += 1;
    }
    // The transcript's rows: separate moves from the press until the bubble rests, and frames where
    // the rows went down (into the composer's room) and later up (by the bubble): the "up down".
    let rowMoves = 0;
    let rowStill = 3;
    let down = 0;
    let up = 0;
    for (const frame of frames) {
      if (Math.abs(frame.rowDy) > 0.5) {
        if (rowStill >= 3) rowMoves += 1;
        rowStill = 0;
        if (frame.rowDy > 0) down += frame.rowDy;
        else up -= frame.rowDy;
      } else rowStill += 1;
    }
    const upDown = Math.round(Math.min(down, up) * 10) / 10;
    // The frame the composer first moved and the frame the hat first drew (an idle send's hat comes in).
    const boxMoved = frames.findIndex(
      (frame, index) => index > 0 && Math.abs(frame.box - frames[index - 1]!.box) > 0.5,
    );
    const hatShown = frames.findIndex((frame) => frame.hatBottom !== undefined);
    return {
      frames: frames.length,
      hatGapFrames,
      hatHeightFrames,
      hatGoneFrames,
      hatMoves,
      rowMoves,
      upDown,
      boxMoved,
      hatShown,
    };
  }

  const LINES = ["Hat line one", "Hat line two", "Hat line three", "Hat line four", "Hat line five"];
  for (const [name] of engines)
    for (const mode of ["steer", "idle"] as const)
      test(`${name}: ${mode === "steer" ? "a steer's send" : "a send from an idle chat"} moves the hat with the composer, in the same frame`, async () => {
        idle = mode === "idle";
        history();
        const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
        await page.goto(
          `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`,
          {
            timeout: 180_000,
          },
        );
        await page.getByText("History paragraph 13.").waitFor();
        await page.locator(".acpmux-running-tray").first().waitFor({ timeout: 120_000 });
        // fixed-wait: the opened chat settles (its fades end) before the frames under test.
        await page.waitForTimeout(800);
        const field = page.locator(".acpmux-composer-box .ProseMirror").first();
        await field.click();
        for (const [index, line] of LINES.entries()) {
          await page.keyboard.type(line, { delay: 4 });
          if (index < LINES.length - 1) await page.keyboard.press("Shift+Enter");
        }
        // fixed-wait: the typed lines' growth comes to rest before the send's window opens.
        await page.waitForTimeout(500);
        await sample(page);
        await page.keyboard.press("Enter");
        await page.locator(".cv-user__bubble", { hasText: "Hat line five" }).first().waitFor({ timeout: 120_000 });
        // fixed-wait: the send's motion comes to rest.
        await page.waitForTimeout(900);
        const frames = await stop(page);
        const report = analyze(frames);
        console.log(
          `HAT_SEND_REPORT ${JSON.stringify({ engine: name, mode, ...report, methods: [...new Set(methods)] })}`,
        );
        if (process.env.CMUX_HAT_FRAMES)
          for (const [index, frame] of frames.entries())
            console.log(`HAT_FRAME ${name} ${mode} ${index} ${JSON.stringify(frame)}`);
        await page.close();
        expect(report.frames).toBeGreaterThan(30);
        expect(report.hatShown).toBe(0);
        expect(report.hatGoneFrames).toBe(0);
        expect(report.hatGapFrames).toBe(0);
        expect(report.hatHeightFrames).toBe(0);
        expect(report.hatMoves).toBeLessThanOrEqual(1);
        // The rows move once, one way: never down into the composer's room and then up by the bubble.
        expect(report.rowMoves).toBeLessThanOrEqual(1);
        expect(report.upDown).toBeLessThanOrEqual(1);
      });
});
