// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The composer and the transcript move as one while a multi-line draft is typed and sent (Leo,
// 2026-11-11, on his NIGHTLY: "when there's a composer thing raised then it gets sent: / ok the fact
// that [it] is animated up... do we even want stuff to push up vs just simple... covering stuff? im not
// sure. if we can get it fast, MAYBE / otherwise idk / but if you look at the [animation] for when
// things get sent: it's not good").
//
// Both looks of the composer's dock (composer/dockMotion.experiment.ts) under the same steps, with
// and without a busy main thread. On every painted frame (paintedFrames.ts) it reads the composer
// box's top, the transcript's rows on screen, the hat's pull tab and the sent bubble:
// (a) typing five lines, each Shift-Return: `rowLagFrames`, frames where the composer's top moved
//     and the rows over it did not move with it in the same frame (push-up's measure only), and
//     `rowMovedFrames`, frames any row moved at all (overlay keeps them at 0), and `boxRunMax`, the
//     most frames the composer's top took to settle one line (Leo's "slowly, a step per line");
// (b) the send: `sendMoves`, separate moves of the rows from the press until the bubble rests (a
//     move is frames of motion with no more than two still frames inside it), `sendMaxStep`, the
//     most a row moved in one frame, and `bubbleHidden`, frames between the draft clearing and the
//     sent bubble being drawn;
// (c) `tabLag`, the most the hat's pull tab ever trailed the composer's top in a frame.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon (as agent-pane-stream-row-overlap.test.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-composer-dock-motion.test.ts", async () => {
  setDefaultTimeout(540_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-dock-motion: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer dock motion", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d8";
  /// The (c) case: a turn runs with a background command, so the hat (or, tucked, its pull tab)
  /// stands on the composer's top edge while the person types.
  let running = false;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Dock",
    harness: "claude",
    family: "claude",
    status: running ? "running" : "idle",
    steering: true,
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
  const history = () => {
    events = [];
    running = false;
    record("mux", "user_message", { text: "Fill the view", promptId: "p-0" });
    record("mux", "turn_started", {});
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
    record("mux", "turn_result", { status: "completed" });
    opened = events.length;
  };
  history();
  let socket: { send(data: string): void } | undefined;
  function answer(method: string, params: Record<string, unknown> | undefined): unknown {
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
          processes: running
            ? [
                {
                  id: "proc-wait",
                  sessionId: SESSION,
                  command: "glaeda-gh wait run 42953147604 --timeout 2700",
                  startedAt: Date.now() - 100 * 60_000,
                  state: "running",
                },
              ]
            : [],
        };
      case "session/prompt": {
        // The daemon records the person's prompt as acpmux does, a little later (its echo).
        const prompt = (params?.prompt as { type: string; text?: string }[] | undefined) ?? [];
        const text = prompt.map((block) => block.text ?? "").join("");
        const meta = params?._meta as { acpmux?: { promptId?: string } } | undefined;
        const promptId = meta?.acpmux?.promptId ?? `p-${events.length}`;
        setTimeout(() => {
          const event = record("mux", "user_message", { text, promptId });
          socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
        }, 60);
        return { stopReason: "end_turn" };
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          if (message.method === "_acpmux/attach") socket = ws;
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

  type Report = {
    frames: number;
    rowLagFrames: number;
    rowMovedFrames: number;
    boxRunMax: number;
    typingMaxStep: number;
    sendMoves: number;
    sendMaxStep: number;
    bubbleHidden: number;
    tabLag: number;
    hiddenAtRest: number;
    bubbles: number;
  };

  const sample = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as {
        __phase: string;
        __r: Record<string, number>;
        __moving: boolean[];
        __boxMoving: boolean[];
        __cleared: boolean;
        __stop: () => void;
      };
      w.__phase = "before";
      w.__r = {
        frames: 0,
        rowLagFrames: 0,
        rowMovedFrames: 0,
        typingMaxStep: 0,
        sendMaxStep: 0,
        bubbleHidden: 0,
        tabLag: 0,
      };
      w.__moving = [];
      w.__boxMoving = [];
      w.__cleared = false;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let last: { box: number; tab?: number; rows: Map<Element, number> } | undefined;
      const read = () => {
        const r = w.__r;
        r.frames! += 1;
        const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
        if (!box) return;
        const boxTop = box.getBoundingClientRect().top;
        const tabNode = document.querySelector<HTMLElement>(".acpmux-tray-pull, .acpmux-running-tray__tuck");
        const tab = tabNode && tabNode.getClientRects().length > 0 ? tabNode.getBoundingClientRect().bottom : undefined;
        const view = scroller.getBoundingClientRect();
        const rows = new Map<Element, number>();
        for (const row of scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")) {
          const rect = row.getBoundingClientRect();
          if (rect.height > 0.5 && rect.bottom > view.top && rect.top < view.bottom) rows.set(row, rect.top);
        }
        if (last) {
          const boxDy = boxTop - last.box;
          let rowDy = 0;
          for (const [row, top] of rows) {
            const before = last.rows.get(row);
            if (before !== undefined && Math.abs(top - before) > Math.abs(rowDy)) rowDy = top - before;
          }
          if (w.__phase === "typing") {
            if (Math.abs(rowDy) > 0.5) r.rowMovedFrames! += 1;
            r.typingMaxStep = Math.max(r.typingMaxStep!, Math.abs(rowDy));
            w.__boxMoving.push(Math.abs(boxDy) > 0.5);
            // Push-up: the rows over the composer move with its top in the same frame, by as much, and
            // never in a frame it holds still (a trail behind it).
            if ((Math.abs(boxDy) > 0.5 || Math.abs(rowDy) > 0.5) && Math.abs(rowDy - boxDy) > 1) r.rowLagFrames! += 1;
          }
          if (w.__phase === "send") {
            w.__moving.push(Math.abs(rowDy) > 0.5);
            r.sendMaxStep = Math.max(r.sendMaxStep!, Math.abs(rowDy));
            const field = document.querySelector<HTMLElement>(".acpmux-composer-box .ProseMirror");
            if (field && !(field.textContent ?? "").trim()) w.__cleared = true;
            const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find((node) =>
              (node.textContent ?? "").includes("Dock line five"),
            );
            if (w.__cleared && (!bubble || bubble.getClientRects().length === 0)) r.bubbleHidden! += 1;
          }
          if (tab !== undefined && last.tab !== undefined)
            r.tabLag = Math.max(r.tabLag!, Math.abs(tab - last.tab - boxDy));
        }
        last = { box: boxTop, tab, rows };
      };
      w.__stop = window.cmuxAfterPaint(read);
    });
  const phase = (page: Page, value: string) =>
    page.evaluate((value) => {
      (window as unknown as { __phase: string }).__phase = value;
    }, value);
  const stop = (page: Page): Promise<Report> =>
    page.evaluate(() => {
      const w = window as unknown as {
        __r: Record<string, number>;
        __moving: boolean[];
        __boxMoving: boolean[];
        __stop: () => void;
      };
      w.__stop();
      // The longest the composer's top took to settle a typed line: a run of frames it moved in, split
      // by three or more still frames (a step per line drawn out over many frames is the slow climb).
      let boxRunMax = 0;
      let run = 0;
      let quiet = 3;
      for (const moving of w.__boxMoving) {
        if (moving) {
          if (quiet >= 3) run = 0;
          run += 1;
          quiet = 0;
          boxRunMax = Math.max(boxRunMax, run);
        } else {
          quiet += 1;
          if (quiet < 3) run += 1;
        }
      }
      // Separate moves: runs of motion, split by three or more still frames.
      let moves = 0;
      let still = 3;
      for (const moving of w.__moving) {
        if (moving) {
          if (still >= 3) moves += 1;
          still = 0;
        } else still += 1;
      }
      // At rest after the send: the sent bubble's bottom under the composer's top (hidden px).
      const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find((node) =>
        (node.textContent ?? "").includes("Dock line five"),
      );
      const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
      const tray = document.querySelector<HTMLElement>(".acpmux-dock");
      const top = Math.min(box?.getBoundingClientRect().top ?? Infinity, tray?.getBoundingClientRect().top ?? Infinity);
      const hiddenAtRest = bubble ? Math.max(0, bubble.getBoundingClientRect().bottom - top) : -1;
      const bubbles = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].filter((node) =>
        (node.textContent ?? "").includes("Dock line five"),
      ).length;
      const r = w.__r;
      return {
        frames: r.frames!,
        rowLagFrames: r.rowLagFrames!,
        rowMovedFrames: r.rowMovedFrames!,
        boxRunMax,
        typingMaxStep: Math.round(r.typingMaxStep! * 10) / 10,
        sendMoves: moves,
        sendMaxStep: Math.round(r.sendMaxStep! * 10) / 10,
        bubbleHidden: r.bubbleHidden!,
        tabLag: Math.round(r.tabLag! * 10) / 10,
        hiddenAtRest: Math.round(hiddenAtRest * 10) / 10,
        bubbles,
      };
    });
  const lag = (page: Page, busy: number, every: number) =>
    page.evaluate(
      ([busy, every]) => {
        window.setInterval(() => {
          const until = performance.now() + busy;
          while (performance.now() < until) {
            /* busy */
          }
        }, every);
      },
      [busy, every] as const,
    );

  async function open(name: string, look: string) {
    history();
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(
      (look) => localStorage.setItem("cmux.experiments", JSON.stringify({ "composer-dock-motion": look })),
      look,
    );
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("History paragraph 13.").waitFor();
    // fixed-wait: the opened chat settles (its fades end) before the frames under test.
    await page.waitForTimeout(600);
    return page;
  }

  const LINES = ["Dock line one", "Dock line two", "Dock line three", "Dock line four", "Dock line five"];
  for (const [name] of engines)
    for (const look of ["overlay", "push"])
      for (const lagging of [false, true])
        test(`${name}, ${look}${lagging ? ", lagging" : ""}: the composer and the transcript move as one`, async () => {
          const page = await open(name, look);
          if (lagging) await lag(page, 40, 70);
          const field = page.locator(".acpmux-composer-box .ProseMirror").first();
          await field.click();
          await sample(page);
          await phase(page, "typing");
          for (const [index, line] of LINES.entries()) {
            await page.keyboard.type(line, { delay: 8 });
            if (index < LINES.length - 1) await page.keyboard.press("Shift+Enter");
            // fixed-wait: a person's pace between lines, so each line's growth plays out.
            await page.waitForTimeout(260);
          }
          await phase(page, "send");
          await page.keyboard.press("Enter");
          await page.locator(".cv-user__bubble", { hasText: "Dock line five" }).first().waitFor({ timeout: 30_000 });
          // fixed-wait: the send's motion comes to rest.
          await page.waitForTimeout(900);
          const report = await stop(page);
          console.log(`DOCK_MOTION_REPORT ${JSON.stringify({ engine: name, look, lagging, ...report })}`);
          await page.close();
          expect(report.frames).toBeGreaterThan(40);
          // (a) push-up moves in the same frame as the composer's growth; overlay moves no row.
          // `rowLagFrames` is push-up's measure only: under overlay the rows hold still by design.
          if (look === "overlay") expect(report.rowMovedFrames).toBe(0);
          else expect(report.rowLagFrames).toBe(0);
          // Either look: each typed line's growth settles inside one structural step (about 12 frames
          // at 60 Hz), never a slow climb.
          expect(report.boxRunMax).toBeLessThanOrEqual(lagging ? 16 : 12);
          // (b) one move on send, never a blank frame for the sent text, nothing left hidden.
          expect(report.sendMoves).toBeLessThanOrEqual(1);
          expect(report.bubbleHidden).toBe(0);
          expect(report.hiddenAtRest).toBeLessThanOrEqual(0.5);
          // (c) the hat's tab rides the composer's top in the same frame.
          expect(report.tabLag).toBeLessThanOrEqual(1);
        });

  // (c) The hat's pull tab (or the hat, untucked) rides the composer's top edge in the frame the edge
  // moves, never a frame behind it, while a running turn's draft grows three lines.
  for (const [name] of engines)
    test(`${name}: the hat's tab rides the composer's top edge as the draft grows`, async () => {
      history();
      running = true;
      record("mux", "user_message", { text: "Wait on the run", promptId: "p-run" });
      record("mux", "turn_started", {});
      opened = events.length;
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText("History paragraph 13.").waitFor();
      await page.locator(".acpmux-running-tray, .acpmux-tray-pull").first().waitFor({ timeout: 30_000 });
      // fixed-wait: the opened chat settles (its fades end) before the frames under test.
      await page.waitForTimeout(600);
      const field = page.locator(".acpmux-composer-box .ProseMirror").first();
      await field.click();
      const sampled = page.evaluate(async () => {
        let worst = 0;
        let frames = 0;
        let last: { box: number; tab: number } | undefined;
        const stop = window.cmuxAfterPaint(() => {
          const box = document.querySelector<HTMLElement>(".acpmux-composer-box");
          const tab = document.querySelector<HTMLElement>(".acpmux-tray-pull, .acpmux-running-tray");
          if (!box || !tab) return;
          frames += 1;
          const now = { box: box.getBoundingClientRect().top, tab: tab.getBoundingClientRect().bottom };
          if (last) worst = Math.max(worst, Math.abs(now.tab - last.tab - (now.box - last.box)));
          last = now;
        });
        // fixed-wait: the typing below runs while this samples.
        await new Promise((resolve) => setTimeout(resolve, 2_400));
        stop();
        return { frames, tabLag: Math.round(worst * 10) / 10 };
      });
      for (const line of ["Tab line one", "Tab line two", "Tab line three"]) {
        await page.keyboard.press("Shift+Enter");
        await page.keyboard.type(line, { delay: 8 });
        // fixed-wait: a person's pace between lines, so each line's growth plays out.
        await page.waitForTimeout(260);
      }
      const report = await sampled;
      console.log(`DOCK_TAB_REPORT ${JSON.stringify({ engine: name, ...report })}`);
      await page.close();
      running = false;
      expect(report.frames).toBeGreaterThan(40);
      expect(report.tabLag).toBeLessThanOrEqual(1);
    });
});
