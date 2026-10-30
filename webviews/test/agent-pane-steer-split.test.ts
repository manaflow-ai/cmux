// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A prompt sent into a running reply (Send now, dogfood run 5, cx-f51kv). acpmux records the steer
// when it is sent, but the agent reads it only once the reply it is writing ends: the rest of that
// reply still streams after the steer's bubble, then the steer's answer follows as a new message.
// The pane drew the reply split mid-word around the bubble ("The S" [steer] "un also rises") and
// glued the answer onto its last sentence ("…of space.DONE"). The reply's text belongs to its
// message: it stays one paragraph above the bubble, and the answer is a row of its own below.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-steer-split.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-steer-split: skipping (run `bunx playwright install chromium`)");
    describe.skip("steer split", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000b1";
  const START = Date.UTC(2026, 9, 12, 9, 0, 0);
  const say = (text: string, messageId: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
    },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Write two sentences about the sun", promptId: "prompt-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("The S", "msg-1")],
    ["mux", "user_message", { text: "Then say DONE", promptId: "prompt-2", steer: true }],
    ["in", "agent_message_chunk", say("un also rises. It warms a cold reach of space.", "msg-1")],
    ["in", "agent_message_chunk", say("DONE", "msg-2")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/sun",
    title: "The sun",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
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
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the transcript.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Then say DONE").waitFor({ timeout: 25_000 });
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
    await daemon?.stop(true);
  });

  test("a steer's bubble follows the whole reply, and its answer starts a row below it", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url());
    await page.getByText("Then say DONE").waitFor();
    // Each paragraph the transcript drew, in order, with the steer's bubble among them.
    const drawn = await page.evaluate(() =>
      [...document.querySelectorAll(".cv-user__bubble, p")]
        .map((node) => node.textContent?.trim() ?? "")
        .filter((text) => text && !text.startsWith("Write two")),
    );
    expect(drawn).toEqual(["The Sun also rises. It warms a cold reach of space.", "Then say DONE", "DONE"]);
    await page.close();
  });
});
