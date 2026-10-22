// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript's scrollbar thumb moves smoothly as a sent prompt and its reply come in (Leo
// 2026-10-21: "the scrollbar keeps flashing way too much whenever sending off new chats ... it
// doesn't animate/render smoothly as new things occur"). Followed at the latest line, the chat only
// grows while a prompt goes out and its reply streams, so on every painted frame the thumb (from the
// scroller's own metrics, as the engine draws it) only gets shorter or keeps its length, never
// longer, and its foot stays at the track's foot: it never jumps up and back.
//
// Red before #23807 (its growth glide held the followed view a frame or more under its content: the
// thumb's foot lifted 12, 10 and 6 px over the frames after a send, then the thumb lengthened as the
// view caught up). This file keeps it that way.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux that streams the
// reply to a prompt sent from the composer. Real Chromium and WebKit (the app's engine); CI fails
// the file when it cannot launch them (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-scrollbar-steady-thumb.test.ts", async () => {
  setDefaultTimeout(300_000);
  type Thumb = { length: number; foot: number; track: number; top: number; height: number };
  type Recording = Window & { __thumbs?: Thumb[]; __stopThumbs?: () => void };
  const engines: [string, () => Promise<Browser>][] = [
    ["chromium", () => chromium.launch({ headless: true, timeout: 30_000 })],
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
      console.warn(`agent-pane-scrollbar-steady-thumb: skipping ${name} (run \`bunx playwright install ${name}\`)`);
    }
  }
  if (launchers.length === 0) {
    describe.skip("agent-pane-scrollbar-steady-thumb", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-00000000f5b2";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/cmux",
    title: "Thumb",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 24,
    updatedAt: Date.now(),
  };
  const update = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  for (let n = 1; n <= 24; n++) {
    record("mux", "user_message", { text: `Question ${n}`, promptId: `p-${n}` });
    record("mux", "turn_started", {});
    record("in", "agent_message_chunk", update(`Answer ${n}: the checks on the merged head are green.`));
    record("mux", "turn_result", { status: "completed" });
  }
  const opened = events.length;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  const paragraph = (turn: number, index: number) =>
    `Turn ${turn}, paragraph ${index}. A client that fails waits a little longer before each retry, ` +
    "and adds a random jitter so a crowd of clients does not retry in step.\n\n";
  let streamingTo: Page | undefined;
  /// acpmux's run of a prompt: its row, then the reply a paragraph every two painted frames. A
  /// prompt sent while a turn runs waits behind it (`queued`) and runs once it ends (`dequeued`).
  let running: Promise<void> | undefined;
  async function run(ws: { send(data: string): void }, params: Record<string, any>, id: number, turn: number) {
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    const promptId = params._meta?.acpmux?.promptId;
    const before = running;
    let finished = () => {};
    running = new Promise((done) => (finished = done));
    if (before) {
      send(record("mux", "queued", { promptId, text }));
      await before;
      send(record("mux", "dequeued", { promptId }));
    }
    send(record("mux", "user_message", { text, promptId }));
    send(record("mux", "turn_started", {}));
    for (let index = 1; index <= 20; index++) {
      send(record("in", "agent_message_chunk", update(paragraph(turn, index))));
      for (let frame = 0; frame < 2; frame++) await streamingTo?.evaluate(() => window.cmuxPaintFrame());
    }
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
    finished();
  }

  let turns = 0;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt" && message.id !== undefined) {
            void run(ws, message.params ?? {}, message.id, ++turns);
            return;
          }
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

  /// Resolves once three painted frames in a row show the transcript scrolled and sized alike.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
            alike = now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error("the view did not come to rest in 10 s"));
              return false;
            }
          });
        }),
    );

  /// Records the thumb after every painted frame: its length and its foot's distance from the
  /// track's foot, in px of the track (the scroller's height), as the engine sizes it.
  const recordThumbs = (page: Page) =>
    page.evaluate(() => {
      const thumbs: Thumb[] = [];
      const page = window as Recording;
      page.__thumbs = thumbs;
      page.__stopThumbs = window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const track = scroller.clientHeight;
        const height = scroller.scrollHeight;
        const length = (track * track) / height;
        const top = (track * scroller.scrollTop) / height;
        thumbs.push({ length, foot: track - (top + length), track, top: scroller.scrollTop, height });
      });
    });
  const recordedThumbs = (page: Page) =>
    page.evaluate(() => {
      const page = window as Recording;
      page.__stopThumbs?.();
      return page.__thumbs ?? [];
    });

  /// The frames where the thumb got longer by more than half a pixel (the content shrank while only
  /// coming in, and the thumb jumped), and those where its foot sat more than a pixel above the
  /// track's end (the followed view lagged its content and the thumb jumped up before coming back).
  const jumps = (thumbs: Thumb[]) => ({
    lengthened: thumbs.flatMap((thumb, index) =>
      index > 0 && thumb.length - thumbs[index - 1]!.length > 0.5
        ? [{ frame: index, from: thumbs[index - 1], to: thumb }]
        : [],
    ),
    lifted: thumbs.flatMap((thumb, index) =>
      thumb.foot > 1 ? [{ frame: index, foot: Math.round(thumb.foot * 10) / 10, thumb }] : [],
    ),
  });

  /// The chat opened at its latest reply, at rest, with the reply streamed to it.
  async function openChat(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    streamingTo = page;
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Answer 24:", { exact: false }).waitFor({ timeout: 120_000 });
    await settle(page);
    return page;
  }

  for (const [name] of launchers) {
    describe(name, () => {
      test("a sent prompt and its streamed reply never lengthen the thumb or lift its foot from the track's end", async () => {
        const page = await openChat(name);
        const turn = turns + 1;
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("Explain backoff");
        await recordThumbs(page);
        await page.keyboard.press("Enter");
        await page.getByText(`Turn ${turn}, paragraph 20.`, { exact: false }).waitFor({ state: "attached" });
        await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached" });
        await settle(page);
        const thumbs = await recordedThumbs(page);
        await page.close();

        expect(thumbs.length).toBeGreaterThan(30);
        expect(jumps(thumbs)).toEqual({ lengthened: [], lifted: [] });
      });

      test("a prompt sent while a reply streams waits in the queue and runs after it, and the thumb never jumps", async () => {
        const page = await openChat(name);
        const first = turns + 1;
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("Explain backoff");
        await recordThumbs(page);
        await page.keyboard.press("Enter");
        await page.getByText(`Turn ${first}, paragraph 6.`, { exact: false }).waitFor({ state: "attached" });
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("Then add a test for the jitter");
        await page.keyboard.press("Enter");
        await page.getByText(`Turn ${first + 1}, paragraph 20.`, { exact: false }).waitFor({ state: "attached", timeout: 60_000 });
        await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached" });
        await settle(page);
        const thumbs = await recordedThumbs(page);
        await page.close();

        expect(thumbs.length).toBeGreaterThan(60);
        expect(jumps(thumbs)).toEqual({ lengthened: [], lifted: [] });
      });
    });
  }
});
