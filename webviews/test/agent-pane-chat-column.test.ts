// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// The agent chat reads in one column (Leo 2026-10-13, cmux NEXT): the transcript and the composer
// share one column, inset from the pane by the page edge (--page-edge, #20121) and wider in wide
// panes, as Codex and Claude desktop do. While a reply streams the view stays at its latest line
// unless the reader scrolls up, and nothing it shows moves when a queue appears or a row opens.
//
// A prompt is a translucent tinted-glass bubble, its text inset evenly; a hover shows no Copy
// on it or on a tool row (both are on right-click; a turn's answer has its own in the footer).
//
// Before: the transcript's rows used a 720px column inside 26.5px gutters and the composer a 760px
// column inside 16px ones, so their edges never met and the narrow-pane inset was neither. The
// bubble was a 5% tint the wallpaper showed through, 16px from its sides and 10.5px from its top,
// on a 16px radius, and a hover showed a second Copy over it.
//
// Each frame is read after it paints (a task queued from requestAnimationFrame), so a layout fixed
// by a ResizeObserver before paint is not a jump, and one fixed a frame late is. Growth moves a
// followed view in the frame that draws it (#23807: no glide slides the thread up from below), and
// the view is judged by its text: it only moves up, and comes to rest at the end.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-chat-column.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-chat-column: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat column", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 13, 9, 0, 0);
  const paragraph = (index: number) =>
    `Paragraph ${index}. A client that fails waits a little longer before each retry, and adds a ` +
    "random jitter so a crowd of clients does not retry in step.\n\n";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const OUTPUT = Array.from({ length: 14 }, (_, index) => `build/step-${index}.o`).join("\n");

  type Socket = { send(data: string): void };
  type Chat = { id: string; seq: number; events: Record<string, unknown>[]; ws?: Socket };
  const chats = new Map<string, Chat>();
  const summary = (chat: Chat) => ({
    sessionId: chat.id,
    cwd: "/home/dev/sun",
    title: "Backoff",
    harness: "codex",
    family: "codex",
    status: "running",
    steering: true,
    turnCount: 1,
    updatedAt: START,
  });
  const record = (chat: Chat, dir: string, kind: string, msg: Record<string, unknown>) => {
    const event = { sessionId: chat.id, seq: ++chat.seq, at: START + chat.seq * 1000, dir, kind, msg };
    chat.events.push(event);
    return event;
  };
  /// A chat a turn is running in: a prompt, a command with output to open, and a long reply so far.
  function newChat(thought?: string): Chat {
    const chat: Chat = {
      id: `0190a000-0000-7000-8000-${String(chats.size + 1).padStart(12, "0")}`,
      seq: 0,
      events: [],
    };
    chats.set(chat.id, chat);
    record(chat, "mux", "user_message", { text: "Why does the build retry?", promptId: "p-1" });
    record(chat, "mux", "turn_started", {});
    if (thought) thinks(chat, thought);
    record(
      chat,
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "c1",
        title: "ls build",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "ls build" },
      }),
    );
    record(
      chat,
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "c1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: OUTPUT } }],
      }),
    );
    for (let index = 1; index <= 24; index++) record(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
    return chat;
  }
  /// A thought chunk from the agent.
  const thinks = (chat: Chat, text: string) =>
    record(
      chat,
      "in",
      "agent_thought_chunk",
      update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
    );
  /// One more record, live to the page.
  const push = (chat: Chat, dir: string, kind: string, msg: Record<string, unknown>) =>
    chat.ws!.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(chat, dir, kind, msg) }));

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          const chat = chats.get(String(message.params?.sessionId ?? "")) ?? [...chats.values()].at(-1)!;
          let result: unknown = null;
          if (message.method === "initialize")
            result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
          else if (message.method === "_acpmux/watch") result = { sessions: [summary(chat)] };
          else if (message.method === "_acpmux/attach") {
            chat.ws = ws;
            result = { session: summary(chat), lastSeq: chat.seq, events: chat.events };
          } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: chat.seq };
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      try {
        const page = await open(newChat(), 900);
        await page.close();
        break;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The page runs as on a loaded CI runner: rows draw a frame or more after the reply grows, so the
  /// view must follow what is drawn, not an estimate a later frame takes back (cx-next-ghostty-config).
  const LOADED = 6;

  async function open(
    chat: Chat,
    width: number,
    height = 700,
    loaded = false,
    foldThoughts = false,
    attributes: Record<string, string> = {},
  ): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height } });
    await installPaintedFrames(page);
    // The Debug tunables (agentPane.debug.foldLongThoughts and the others), as the app sets them on
    // <html>: the fold is on unless the app sets it off.
    const set = { ...(!foldThoughts && { "data-fold-long-thoughts": "off" }), ...attributes };
    if (Object.keys(set).length)
      await page.addInitScript((names: Record<string, string>) => {
        const apply = () => {
          for (const [name, value] of Object.entries(names)) document.documentElement.setAttribute(name, value);
        };
        if (document.documentElement) apply();
        else document.addEventListener("readystatechange", apply, { once: true });
      }, set);
    if (loaded)
      await (await page.context().newCDPSession(page)).send("Emulation.setCPUThrottlingRate", { rate: LOADED });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat.id}`);
    await page.getByText("Paragraph 24.", { exact: false }).waitFor({ timeout: 25_000 });
    // Rows place by their drawn heights a frame after they mount.
    await settle(page);
    return page;
  }

  /// Resolves once the view is at rest: no animation running (a row's entrance, a reply's fade-in),
  /// and three painted frames in a row show the rows and the scroll position where the frame before
  /// had them.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const gliding = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const rows = [...scroller.querySelectorAll(".acpmux-row")].map((row) =>
              Math.round(row.getBoundingClientRect().top),
            );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${rows.join()}`;
            alike = !gliding && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (gliding: ${gliding})`));
              return false;
            }
          });
        }),
    );

  /// What a painted frame shows: how far the view sits above the transcript's end, where it is
  /// scrolled to, and how far the last line of text sits above the view's foot (the bottom stack's
  /// top, which lies over the transcript); or, given `text`, the top of the row that holds it.
  /// `glides` counts the animations on the thread, which nothing starts any more (#23807).
  type Frame = {
    fromEnd: number;
    scrollTop: number;
    lastLine: number;
    top: number | null;
    glides: number;
  };
  /// Reads every painted frame until `stop`.
  const watch = (page: Page, text?: string) =>
    page.evaluate((text) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const sample = () => {
        const view = scroller.getBoundingClientRect();
        // The view's foot: the top of the bottom stack lying over the transcript, else its bottom.
        const stack = document.querySelector(".acpmux-main[data-dock=float] > .acpmux-dock");
        const foot = stack ? stack.getBoundingClientRect().top : view.bottom;
        const thread = document.querySelector<HTMLElement>(".acpmux-thread");
        const lines = [...scroller.querySelectorAll("p")];
        const holds = (node: Element) => node.textContent?.includes(text!) ?? false;
        const row = text
          ? ([...scroller.querySelectorAll("button[aria-expanded]")].find(holds) ??
            [...scroller.querySelectorAll(".acpmux-row")].find(holds))
          : undefined;
        return {
          fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
          scrollTop: Math.round(scroller.scrollTop),
          lastLine: Math.round(foot - (lines.at(-1)?.getBoundingClientRect().bottom ?? foot)),
          top: row ? Math.round(row.getBoundingClientRect().top) : null,
          glides: thread?.getAnimations().length ?? 0,
        };
      };
      const frames: unknown[] = [];
      (window as any).__frames = frames;
      // A frame paints at the viewport its animation frame saw: the rendering steps apply a
      // resize before that callback, and no task runs between it and the paint. A resize that
      // lands after it is read here by a forced layout the page never painted (the rows rewrapped,
      // not yet placed), so that read is not a frame.
      let painted = "";
      window.cmuxAfterPaint(
        () => {
          if ((window as any).__frames !== frames) return false;
          if (`${innerWidth}x${innerHeight}` === painted) frames.push(sample());
        },
        () => {
          painted = `${innerWidth}x${innerHeight}`;
        },
      );
    }, text);
  const stop = async (page: Page): Promise<Frame[]> => {
    // The frames run on until the last animation has played out and the view holds still.
    await settle(page);
    return page.evaluate(() => {
      const frames = (window as any).__frames as unknown[];
      (window as any).__frames = undefined;
      return frames as never;
    });
  };
  /// The frames whose text moved down on screen from the frame before: a jump back.
  const movedDown = (frames: Frame[]) =>
    frames.flatMap((frame, index) =>
      index > 0 && frame.top !== null && frames[index - 1]!.top !== null && frame.top > frames[index - 1]!.top! + 1
        ? [[frames[index - 1]!, frame]]
        : [],
    );
  /// How far the newest line may rest from where the last one did: lines are 22.75px and rows are
  /// placed by their drawn heights, so the end can settle a few pixels off; a jump is a line.
  const REST_SLACK = 4;
  /// How far the last line of text sits above the view's foot once nothing in the transcript
  /// animates: a reply's last words fade in over 180 ms after they are drawn (and a row rises in),
  /// and a loaded runner can still be in that when the frames stop. Only running, finite animations count: a
  /// looping one (a streaming mark) never ends, and a finished one held by its fill stays listed.
  const restingLastLine = async (page: Page): Promise<number> => {
    // Passed as a function, never as source text: the page's CSP forbids eval.
    const gliding = (names: boolean) => {
      const running = document
        .querySelector(".acpmux-scroll")!
        .getAnimations({ subtree: true })
        .filter(
          (animation) => animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
        );
      if (!names) return running.length === 0;
      return running.map((animation) => {
        const target = (animation.effect as KeyframeEffect | null)?.target;
        return `${target?.className ?? "?"} ${animation.constructor.name} ${String(animation.effect?.getTiming().duration)}`;
      });
    };
    await page.waitForFunction(gliding, false, { timeout: 5_000 }).catch(async (error: unknown) => {
      throw new Error(`still gliding after 5 s: ${JSON.stringify(await page.evaluate(gliding, true))}`, {
        cause: error,
      });
    });
    return page.evaluate(
      () =>
        new Promise<number>((done) =>
          window.cmuxPaintFrame().then(() =>
            window.cmuxPaintFrame().then(() => {
              const view = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
              const stack = document.querySelector(".acpmux-main[data-dock=float] > .acpmux-dock");
              const foot = stack ? stack.getBoundingClientRect().top : view.bottom;
              const lines = [...document.querySelectorAll(".acpmux-scroll p")];
              done(Math.round(foot - (lines.at(-1)?.getBoundingClientRect().bottom ?? foot)));
            }),
          ),
        ),
    );
  };
  /// The frames whose view moved back up from the frame before.
  const backwards = (frames: Frame[]) =>
    frames.flatMap((frame, index) =>
      index > 0 && frame.scrollTop < frames[index - 1]!.scrollTop - 1 ? [[frames[index - 1]!, frame]] : [],
    );

  /// Scrolls to the transcript's start as a reader does, so its first rows mount.
  async function toStart(page: Page) {
    await page.locator(".acpmux-scroll").hover();
    for (let step = 0; step < 6; step++) await page.mouse.wheel(0, -4000);
    await page.waitForFunction(() => document.querySelector(".acpmux-scroll")!.scrollTop === 0);
    await settle(page);
  }
  /// The command's toggle, at the start of the turn.
  const commandToggle = (page: Page) => page.locator("button[aria-expanded]", { hasText: "ls build" }).first();

  test("the transcript and the composer share one column, inset by the page edge, wider in wide panes", async () => {
    const chat = newChat();
    const columns: Record<number, { main: number; row: number[]; composer: number[]; edge: number }> = {};
    for (const width of [480, 900, 1400, 1900]) {
      const page = await open(chat, width);
      columns[width] = await page.evaluate(() => {
        const main = document.querySelector(".acpmux-main")!.getBoundingClientRect();
        const edges = (selector: string) => {
          const box = document.querySelector(selector)!.getBoundingClientRect();
          return [Math.round(box.left - main.left), Math.round(main.right - box.right)];
        };
        // The column's minimum edge as the pane draws it (conversation.css --cv-edge, the grid's 16).
        const probe = document.createElement("div");
        probe.style.cssText = "position:absolute;visibility:hidden;width:var(--cv-edge)";
        document.querySelector(".acpmux-main")!.append(probe);
        const edge = Math.round(probe.getBoundingClientRect().width);
        probe.remove();
        return {
          main: Math.round(main.width),
          row: edges(".acpmux-row.acpmux-assistant"),
          composer: edges(".acpmux-composer-box"),
          edge,
        };
      });
      await page.close();
    }
    // The minimum edge is the grid's 16 (leo-workspace design/grid.md 5.5: "the minimum edge is 16
    // (today's 18 moves to it)"; #27580 set --cv-edge to it), read from the pane's own token.
    const pageEdge = columns[480]!.edge;
    expect(pageEdge).toBe(16);
    const column = (viewport: number) => {
      const { main, row } = columns[viewport]!;
      return main - row[0]! - row[1]!;
    };
    // The composer's card spans the same column as the transcript's rows, at every width.
    for (const [viewport, { row, composer }] of Object.entries(columns))
      expect({ viewport, composer }).toEqual({ viewport, composer: row });
    // A narrow pane leaves the page edge on each side.
    expect(columns[480]!.row).toEqual([pageEdge, pageEdge]);
    // The column fills the pane up to the readable cap (Chat Text Width 800, #31510); it stays centered.
    expect(column(900)).toBeGreaterThanOrEqual(799);
    expect(column(1900)).toBeGreaterThanOrEqual(799);
    expect(column(1900)).toBeLessThanOrEqual(800);
    expect(Math.abs(columns[1900]!.row[0]! - columns[1900]!.row[1]!)).toBeLessThanOrEqual(1);
  });

  test("a streaming reply keeps the view at its end, through a growing command and a queue", async () => {
    const chat = newChat();
    const page = await open(chat, 900, 700, true);
    const atRest = await restingLastLine(page);
    await watch(page, "Paragraph 20.");
    for (let index = 25; index <= 34; index++) {
      push(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
      if (index === 28) push(chat, "mux", "queued", { promptId: "q-1", text: "Then add a test for the jitter" });
      if (index === 30) push(chat, "mux", "queued", { promptId: "q-2", text: "And document the cap" });
      await page.getByText(`Paragraph ${index}.`, { exact: false }).waitFor({ state: "attached" });
    }
    await page.locator(".acpmux-queued", { hasText: "document the cap" }).waitFor();
    const frames = await stop(page);
    // The text only ever moves up while it follows the reply, and the view rests at the end.
    expect(movedDown(frames)).toEqual([]);
    expect(backwards(frames)).toEqual([]);
    // The view comes to rest where it started; the last frames read show where it was going.
    const rest = await restingLastLine(page);
    expect({
      settled: Math.abs(rest - atRest) <= REST_SLACK,
      atRest,
      rest,
      lastFrames: frames.slice(-3),
    }).toMatchObject({
      settled: true,
    });
    await page.close();
  });

  test("scrolled up, the view stays where the reader left it while the reply streams and a queue appears", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await page.locator(".acpmux-scroll").hover();
    await page.mouse.wheel(0, -900);
    await settle(page);
    const anchor = "Paragraph 12.";
    await watch(page, anchor);
    for (let index = 25; index <= 30; index++) {
      push(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
      if (index === 27) push(chat, "mux", "queued", { promptId: "q-1", text: "Then add a test for the jitter" });
      // A few painted frames for each chunk, as a reply streams.
      for (let frame = 0; frame < 4; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.locator(".acpmux-queued").waitFor();
    const tops = (await stop(page)).map((frame) => frame.top);
    expect(tops.length).toBeGreaterThan(5);
    expect(new Set(tops)).toEqual(new Set([tops[0]!]));
    await page.close();
  });

  test("opening a command's output keeps the command under the pointer", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await toStart(page);
    const command = commandToggle(page);
    await command.waitFor();
    await watch(page, "ls build");
    await command.click();
    await page.getByText("build/step-13.o").waitFor();
    const tops = (await stop(page)).map((frame) => frame.top);
    expect(new Set(tops)).toEqual(new Set([tops[0]!]));
    await page.close();
  });

  test("a reply streamed a few words at a time scrolls smoothly: its last line holds still at the bottom", async () => {
    const chat = newChat();
    const page = await open(chat, 900, 700, true);
    const atRest = await restingLastLine(page);
    await watch(page, "Paragraph 20.");
    const words = (paragraph(25) + paragraph(26) + paragraph(27)).split(/(?<= )/);
    for (let index = 0; index < words.length; index += 3) {
      push(chat, "in", "agent_message_chunk", chunk(words.slice(index, index + 3).join("")));
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.getByText("Paragraph 27.", { exact: false }).waitFor();
    const frames = await stop(page);
    // Each new line moves the text up in the frame that draws it (Leo 2026-10-21: at the bottom
    // "IMMEDIATELY"): never down and back, and the newest line comes to rest where the last one did.
    expect(movedDown(frames)).toEqual([]);
    expect(backwards(frames)).toEqual([]);
    // The view comes to rest where it started; the last frames read show where it was going.
    const rest = await restingLastLine(page);
    expect({
      settled: Math.abs(rest - atRest) <= REST_SLACK,
      atRest,
      rest,
      lastFrames: frames.slice(-3),
    }).toMatchObject({
      settled: true,
    });
    await page.close();
  });

  test("a pane resized at every frame keeps its last line at the bottom: the text never glides", async () => {
    // A window edge dragged (cx-sqj3h): the column rewraps at every frame, and rows settle to
    // their drawn heights at the new width before it paints. That is the resize, not growth, so
    // nothing slides: the last line sits where it rests in every painted frame.
    const chat = newChat();
    const page = await open(chat, 760, 700, true);
    const atRest = await restingLastLine(page);
    await watch(page);
    for (const widths of [
      Array.from({ length: 40 }, (_, step) => 754 - step * 7),
      Array.from({ length: 40 }, (_, step) => 481 + step * 7),
    ])
      for (const width of widths) {
        await page.setViewportSize({ width, height: 700 });
        await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0))));
      }
    const frames = await stop(page);
    expect(frames.length).toBeGreaterThan(40);
    expect(frames.filter((frame) => frame.glides > 0).length).toBe(0);
    expect(frames.filter((frame) => Math.abs(frame.lastLine - atRest) > REST_SLACK)).toEqual([]);
    await page.close();
  });

  test("a prompt is a translucent glass bubble with its text inset evenly, at the column's right edge", async () => {
    const page = await open(newChat(), 900);
    const bubble = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".cv-user__bubble")!;
      const box = node.getBoundingClientRect();
      const range = document.createRange();
      range.selectNodeContents(node);
      const lines = [...range.getClientRects()];
      const text = {
        left: Math.min(...lines.map((line) => line.left)),
        top: Math.min(...lines.map((line) => line.top)),
        bottom: Math.max(...lines.map((line) => line.bottom)),
      };
      // How opaque the fill is, as the page paints it.
      const canvas = document.createElement("canvas").getContext("2d")!;
      canvas.fillStyle = getComputedStyle(node).backgroundColor;
      canvas.fillRect(0, 0, 1, 1);
      const row = node.closest(".acpmux-row")!.getBoundingClientRect();
      return {
        alpha: canvas.getImageData(0, 0, 1, 1).data[3],
        radius: parseFloat(getComputedStyle(node).borderTopLeftRadius),
        left: Math.round(text.left - box.left),
        top: Math.round(text.top - box.top),
        bottom: Math.round(box.bottom - text.bottom),
        right: Math.round(row.right - box.right),
      };
    });
    // Tinted glass (Leo 2026-10-20): the window shows through, but the tint is there.
    expect(bubble.alpha).toBeGreaterThan(0);
    expect(bubble.alpha).toBeLessThan(255);
    expect(bubble.radius).toBeLessThanOrEqual(12);
    expect(bubble.left).toBeGreaterThanOrEqual(10);
    expect(bubble.left).toBeLessThanOrEqual(12);
    expect(Math.abs(bubble.top - bubble.left)).toBeLessThanOrEqual(2);
    expect(Math.abs(bubble.bottom - bubble.left)).toBeLessThanOrEqual(2);
    expect(bubble.right).toBe(0);
    await page.close();
  });

  // Leo dogfood 2026-10-13 (hover buttons everywhere): a tool row's Copy is on the right-click menu
  // (Copy Output), so a hover shows none. A prompt's action row has Copy, as Claude Code's does
  // (Leo, 2026-10-20).
  test("a hover shows Copy on a prompt's action row, none on a tool row", async () => {
    const page = await open(newChat(), 900);
    /// The Copy buttons in the row holding `text` that show, by their own and their parents' opacity.
    const shown = (text: string) =>
      page.evaluate((text) => {
        const row = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].find((node) =>
          node.textContent?.includes(text),
        )!;
        return [...row.querySelectorAll<HTMLElement>("button")].filter((button) => {
          if (!/^Cop(y|ied)$/.test(button.getAttribute("aria-label") ?? "")) return false;
          for (let node: HTMLElement | null = button; node && node !== row.parentElement; node = node.parentElement)
            if (Number(getComputedStyle(node).opacity) === 0 || getComputedStyle(node).visibility === "hidden")
              return false;
          return true;
        }).length;
      }, text);
    /// Resolves once the pointer is over `selector` and the row holding it has no fade left to run.
    const hovered = (selector: string) =>
      page.waitForFunction((selector) => {
        const row = document.querySelector(`${selector}:hover`)?.closest(".acpmux-row");
        return !!row && row.getAnimations({ subtree: true }).every((animation) => animation.playState !== "running");
      }, selector);
    await toStart(page);
    const prompt = page.locator(".acpmux-row.acpmux-user").first();
    await prompt.hover();
    await hovered(".acpmux-row.acpmux-user");
    const onPrompt = await shown("Why does the build retry?");
    await commandToggle(page).hover();
    await hovered("button[aria-expanded]");
    expect({ onPrompt, onTool: await shown("ls build") }).toEqual({ onPrompt: 1, onTool: 0 });
    await page.close();
  });

  // A long thought folds once done, behind the Debug toggle agentPane.debug.foldLongThoughts
  // (conversation/ThoughtRow.tsx): only what is below it moves, so the rows above it stay put.
  const THOUGHT = Array.from({ length: 60 }, (_, index) => `Step ${index + 1}: check the retry path.`).join("\n");
  const thoughtToggle = (page: Page) => page.locator("button[aria-expanded]", { hasText: "Thought" });

  test("a long thought streams, then folds when the next step starts without moving the rows above it", async () => {
    const chat = newChat();
    thinks(chat, THOUGHT);
    const page = await open(chat, 900, 700, false, true);
    // Streaming: the Codex-style turn (Debug toggle agentPane.debug.codexToolRuns, on by default)
    // draws no row for the thought yet; the turn's live line at its foot says "Thinking"
    // (Thinking.tsx), with nothing to open.
    await page.locator(".cv-worked.is-below .cv-thinking", { hasText: "Thinking" }).waitFor();
    expect(await page.getByText("Step 60: check the retry path.", { exact: false }).count()).toBe(0);
    expect(await thoughtToggle(page).count()).toBe(0);
    await page.locator(".acpmux-scroll").hover();
    await page.mouse.wheel(0, -1600);
    await settle(page);
    await watch(page, "Paragraph 12.");
    push(chat, "in", "tool_call", {
      ...update({
        sessionUpdate: "tool_call",
        toolCallId: "c2",
        title: "bun test",
        kind: "execute",
        status: "completed",
        rawInput: { command: "bun test" },
      }),
    });
    await thoughtToggle(page).waitFor({ state: "attached" });
    const tops = (await stop(page)).map((frame) => frame.top);
    expect(await thoughtToggle(page).getAttribute("aria-expanded")).toBe("false");
    expect(tops.length).toBeGreaterThan(5);
    expect(new Set(tops)).toEqual(new Set([tops[0]!]));
    await page.close();
  });

  test("opening and closing a folded thought keeps its line under the pointer", async () => {
    const page = await open(newChat(THOUGHT), 900, 700, false, true);
    await toStart(page);
    const toggle = thoughtToggle(page);
    await toggle.waitFor();
    expect(await toggle.getAttribute("aria-expanded")).toBe("false");
    await watch(page, "Thought");
    await toggle.click();
    await page.getByText("Step 60: check the retry path.", { exact: false }).waitFor({ state: "attached" });
    await settle(page);
    await toggle.click();
    await page.locator(".cv-fold").waitFor({ state: "detached" });
    await settle(page);
    const tops = (await stop(page)).map((frame) => frame.top);
    expect(await toggle.getAttribute("aria-expanded")).toBe("false");
    expect(new Set(tops)).toEqual(new Set([tops[0]!]));
    await page.close();
  });

  // While it streams, a long thought holds Codex's seven-line viewport with its newest line in view
  // (Debug toggle agentPane.debug.liveThoughtViewport, on by default). Only a turn drawn without the
  // Codex-style runs shows a thought while it streams (the test above), so these push
  // agentPane.debug.codexToolRuns off with the theme, as the app sends it.
  const liveThought = async (attributes: Record<string, string> = {}) => {
    const chat = newChat();
    thinks(chat, THOUGHT);
    const page = await open(chat, 900, 700, false, true, attributes);
    await page.evaluate(() => window.cmuxAcpmuxBridge!.applyTheme({ isDark: false, codexToolRuns: false }));
    const text = page.locator(".cv-thought__text");
    await text.waitFor({ state: "attached" });
    await text.scrollIntoViewIfNeeded();
    return { page, text };
  };

  test("a long live thought holds a 140px viewport with its newest line in view", async () => {
    const { page, text } = await liveThought();
    expect(await page.locator(".cv-thought.is-live .cv-thought__label").textContent()).toBe("Thinking");
    const seen = await text.evaluate((element) => {
      const box = element.getBoundingClientRect();
      // The text node itself: the text draws in its parts (ThoughtRow.tsx thoughtParts).
      const node = element.querySelector(".cv-thought__part")!.firstChild!;
      const at = (words: string) => {
        const range = document.createRange();
        const start = node.textContent!.indexOf(words);
        range.setStart(node, start);
        range.setEnd(node, start + words.length);
        return range.getBoundingClientRect();
      };
      const last = at("Step 60: check the retry path.");
      const first = at("Step 1: check the retry path.");
      return {
        height: Math.round(box.height),
        lastInView: last.top >= box.top - 1 && last.bottom <= box.bottom + 1,
        firstOut: first.bottom <= box.top + 1,
      };
    });
    expect(seen).toEqual({ height: 140, lastInView: true, firstOut: true });
    await page.close();
  });

  test("with the live viewport off, a long live thought streams in full", async () => {
    const { page, text } = await liveThought({ "data-live-thought-viewport": "off" });
    expect(await page.locator(".cv-thought.is-live").count()).toBe(0);
    expect(await text.evaluate((element) => element.getBoundingClientRect().height)).toBeGreaterThan(600);
    await page.close();
  });

  test("with the Debug toggle off, a long thought stays in full once done", async () => {
    const page = await open(newChat(THOUGHT), 900);
    await toStart(page);
    await page.getByText("Step 60: check the retry path.", { exact: false }).waitFor({ state: "attached" });
    expect(await thoughtToggle(page).count()).toBe(0);
    await page.close();
  });
});
