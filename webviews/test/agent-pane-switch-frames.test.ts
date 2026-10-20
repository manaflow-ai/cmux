// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// Leo, 2026-10-19: switching chats flickers (the permission UI, the transcript). A chat switch
// should draw the old chat until the new one can draw whole, then the new one: never a frame in
// between (an empty transcript, the access chip without its mode, one chat's rows under the
// other's chip). acpmux's session list carries no permission modes and the attach takes a while,
// as in the app. A per-frame sampler in the page records what each frame shows from the switch
// until it settles; every frame must be all old or all new.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-switch-frames.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-switch-frames: skipping (run `bunx playwright install chromium`)");
    describe.skip("switch frames", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 19, 9, 0, 0);
  /// How long acpmux takes to answer an attach (a busy daemon, a large chat).
  const ATTACH_MS = 150;
  const modes = (current: string) => ({
    currentModeId: current,
    availableModes: [
      { id: "default", name: "Normal", description: "Ask before edits and commands" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "bypassPermissions", name: "Full access", description: "Never ask" },
    ],
  });
  const chat = (sessionId: string, title: string, reply: string, mode: string) => {
    const listed = {
      sessionId,
      cwd: "/home/dev/uploader",
      title,
      harness: "claude",
      family: "claude",
      model: "claude-sonnet",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      currentModeId: mode,
    };
    const steps: [string, string, Record<string, unknown>][] = [
      ["mux", "user_message", { text: title }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: reply },
            },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    ];
    const events = steps.map(([dir, kind, msg], index) => ({
      sessionId,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
    return { listed, attached: { ...listed, modes: modes(mode) }, events };
  };
  const A = chat("0190a000-0000-7000-8000-0000000000f1", "Uploader retry", "Retry added.", "bypassPermissions");
  const B = chat("0190a000-0000-7000-8000-0000000000f2", "Docs pass", "Docs updated.", "default");
  const chats = new Map([A, B].map((entry) => [entry.listed.sessionId, entry]));

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        // acpmux's list names each chat's mode, not the modes it offers (protocol/session.rs).
        return { sessions: [...chats.values()].map((entry) => entry.listed) };
      case "_acpmux/attach": {
        const entry = chats.get(String(params.sessionId))!;
        return { session: entry.attached, lastSeq: entry.events.length, events: entry.events };
      }
      case "_acpmux/events":
        return {
          events: [],
          hasMore: false,
          lastSeq: chats.get(String(params.sessionId))?.events.length ?? 0,
        };
      default:
        return null;
    }
  }
  const sockets = new Set<Bun.ServerWebSocket<unknown>>();
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
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
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, any>;
          };
          if (message.id === undefined) return;
          const reply = () =>
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params ?? {}),
              }),
            );
          if (message.method === "_acpmux/attach") setTimeout(reply, ATTACH_MS);
          else reply();
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(B.listed.sessionId));
        await warm.getByText("Docs updated.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    // Not awaited: after the reconnect test's forced close, Bun's stop can wait on that socket for good.
    void daemon?.stop(true);
  });

  test("a chat switch draws the old chat, then the new one, never a frame in between", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(A.listed.sessionId));
    await page.getByText("Retry added.").waitFor();
    const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
    await page.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Full access", CHIP);
    await page.evaluate((selector) => {
      const frames: { at: number; chip: string; old: boolean; fresh: boolean; text: string }[] = [];
      (window as unknown as { switchFrames: typeof frames }).switchFrames = frames;
      const start = performance.now();
      const sample = () => {
        const text = document.body.innerText;
        frames.push({
          at: performance.now() - start,
          chip: document.querySelector(selector)?.textContent ?? "",
          old: text.includes("Retry added."),
          fresh: text.includes("Docs updated."),
          text: text.slice(0, 160).replace(/\s+/g, " "),
        });
        if (performance.now() - start < 1500) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.select"]?.({ sessionId: "0190a000-0000-7000-8000-0000000000f2" });
    }, CHIP);
    await page.getByText("Docs updated.").waitFor();
    await page.waitForFunction(() => {
      const frames = (window as unknown as { switchFrames: { at: number }[] }).switchFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1400;
    });
    const frames = await page.evaluate(
      () =>
        (
          window as unknown as {
            switchFrames: { at: number; chip: string; old: boolean; fresh: boolean }[];
          }
        ).switchFrames,
    );
    await page.close();
    const oldFrame = (frame: (typeof frames)[number]) => frame.old && !frame.fresh && frame.chip === "Full access";
    const newFrame = (frame: (typeof frames)[number]) => frame.fresh && !frame.old && frame.chip === "Normal";
    const between = frames.filter((frame) => !oldFrame(frame) && !newFrame(frame));
    const firstNew = frames.findIndex(newFrame);
    const span = between.length ? between.at(-1)!.at - between[0].at : 0;
    console.log(
      `switch-frames: ${frames.length} frames, ${between.length} in between over ${span.toFixed(0)} ms ` +
        `(first: ${JSON.stringify(between[0] ?? null)}), new chat whole at ${firstNew < 0 ? "never" : frames[firstNew].at.toFixed(0) + " ms"}`,
    );
    expect(firstNew).toBeGreaterThanOrEqual(0);
    expect(between).toEqual([]);
  });

  test("a reconnect keeps the chat on screen until the chat is read again", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(A.listed.sessionId));
    await page.getByText("Retry added.").waitFor();
    const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
    await page.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Full access", CHIP);
    await page.evaluate((selector) => {
      const frames: { at: number; chip: string; old: boolean; text: string }[] = [];
      (window as unknown as { reconnectFrames: typeof frames }).reconnectFrames = frames;
      const start = performance.now();
      const sample = () => {
        const text = document.body.innerText;
        frames.push({
          at: performance.now() - start,
          chip: document.querySelector(selector)?.textContent ?? "",
          old: text.includes("Retry added."),
          text: text.slice(0, 160).replace(/\s+/g, " "),
        });
        if (performance.now() - start < 2000) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    }, CHIP);
    // acpmux restarts: the pane's socket drops and it connects again.
    for (const socket of sockets) socket.close(1012, "restart");
    await page.waitForFunction(() => {
      const frames = (window as unknown as { reconnectFrames: { at: number }[] }).reconnectFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1900;
    });
    const frames = await page.evaluate(
      () =>
        (window as unknown as { reconnectFrames: { at: number; chip: string; old: boolean; text: string }[] })
          .reconnectFrames,
    );
    await page.close();
    const lost = frames.filter((frame) => !frame.old || frame.chip !== "Full access");
    console.log(
      `reconnect-frames: ${frames.length} frames, ${lost.length} without the chat or its chip` +
        (lost.length
          ? ` over ${(lost.at(-1)!.at - lost[0].at).toFixed(0)} ms (first: ${JSON.stringify(lost[0])})`
          : ""),
    );
    expect(lost).toEqual([]);
  });
});
