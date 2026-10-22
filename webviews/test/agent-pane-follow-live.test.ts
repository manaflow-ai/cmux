// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat follows its reply live, in the real agent pane (dogfood run 6). A prompt sent from the
// composer, and the agent's reply streaming in past one screen: the view stays at the reply's
// latest line, as Codex and Claude do. On a DEV build of 02f8184e the view stayed at the top of
// each reply with Jump to latest shown, and later turns arrived out of sight, though the
// transcript alone (transcript-follow.test.ts) follows. The page is the pane's dev entry with its
// browser host, talking JSON-RPC to a stand-in acpmux daemon that streams the reply.
//
// The app draws the pane in WebKit, where the view stayed behind while Chromium followed (cx-02st5),
// so each case runs in both engines from `playwright install chromium webkit`; where one is not
// installed its cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-follow-live.test.ts", async () => {
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
      console.warn(`agent-pane-follow-live: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("follow live", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000c1";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Backoff",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
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
  record("mux", "user_message", { text: "Say hi", promptId: "p-0" });
  record("mux", "turn_started", {});
  record("in", "agent_message_chunk", update("Hi there."));
  record("mux", "turn_result", { status: "completed" });
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
  /// The page the reply streams to: a paragraph goes out every two frames it paints.
  let streamingTo: Page | undefined;
  /// acpmux's run of a prompt: its row, then the reply streamed a paragraph at a time, then its end.
  async function run(ws: { send(data: string): void }, params: Record<string, any>, id: number, turn: number) {
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    send(record("mux", "user_message", { text, promptId: params._meta?.acpmux?.promptId }));
    send(record("mux", "turn_started", {}));
    for (let index = 1; index <= 30; index++) {
      send(record("in", "agent_message_chunk", update(paragraph(turn, index))));
      for (let frame = 0; frame < 2; frame++) await streamingTo?.evaluate(() => window.cmuxPaintFrame());
    }
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// How far the transcript's last line sits below the bottom of the view (0 when in view).
  const belowView = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector(".acpmux-scroll")!;
      const lines = [...scroller.querySelectorAll("p")];
      const last = lines.at(-1)!.getBoundingClientRect().bottom;
      return Math.max(0, Math.round(last - scroller.getBoundingClientRect().bottom));
    });
  /// Resolves once the view is at rest: no finite animation running, and three painted frames in a row show the
  /// transcript scrolled and sized as the frame before.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const gliding = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
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
  async function sendAndStream(page: Page, prompt: string, turn: number) {
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(prompt);
    await page.keyboard.press("Enter");
    await page.getByText(`Turn ${turn}, paragraph 30.`, { exact: false }).waitFor({ state: "attached" });
    await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached" });
    await settle(page);
  }
  /// A page on the pane, streamed to.
  async function newPage(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    streamingTo = page;
    return page;
  }

  test.each(engines.map(([name]) => name))(
    "%s: a reply sent from the composer is followed to its latest line, turn after turn",
    async (name) => {
      const page = await newPage(name);
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText("Hi there.").waitFor();
      await sendAndStream(page, "Explain backoff", turns + 1);
      const first = await belowView(page);
      await sendAndStream(page, "Now with jitter", turns + 1);
      const second = await belowView(page);
      expect({ first, second }).toEqual({ first: 0, second: 0 });
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a reply stays followed when the view moves a pixel the reader did not move",
    async (name) => {
      const page = await newPage(name);
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText("Hi there.").waitFor();
      // In the app (WebKit on macOS) the offset is whole pixels, and as the reply grows WebKit moved
      // it a pixel or so above the latest line with no input from the reader: the view then stayed
      // there for the rest of the chat (cx-02st5, run 6).
      const turn = turns + 1;
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("Explain backoff again");
      await page.keyboard.press("Enter");
      await page.getByText(`Turn ${turn}, paragraph 12.`, { exact: false }).waitFor({ state: "attached" });
      await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        scroller.scrollTop -= 2;
      });
      await page.getByText(`Turn ${turn}, paragraph 30.`, { exact: false }).waitFor({ state: "attached" });
      await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached" });
      await settle(page);
      const first = await belowView(page);
      await sendAndStream(page, "Now with jitter again", turns + 1);
      expect({ first, second: await belowView(page) }).toEqual({ first: 0, second: 0 });
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a chat opened while hidden follows its reply once it shows",
    async (name) => {
      const page = await newPage(name);
      // The chat opens behind another page (a New Tab starts its chat behind it): its transcript
      // has no height when it first lays out.
      await page.addInitScript(() => {
        const style = document.createElement("style");
        style.id = "behind";
        style.textContent = ".acpmux-scroll { display: none !important; }";
        document.addEventListener("DOMContentLoaded", () => document.head.append(style));
      });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText("Hi there.").waitFor({ state: "attached" });
      // A few frames lay the hidden transcript out with no height.
      for (let frame = 0; frame < 3; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      await page.evaluate(() => document.getElementById("behind")?.remove());
      await page.getByText("Hi there.").waitFor();
      await sendAndStream(page, "Explain backoff once more", turns + 1);
      expect(await belowView(page)).toBe(0);
      await page.close();
    },
  );
});
