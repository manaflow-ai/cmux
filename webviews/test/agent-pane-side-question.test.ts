// Side questions in the real agent pane (cx-ef2m). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon that serves one recorded chat (replay/replayFixture.ts).
//
// - With the side-question experiment on, `/btw <question>` asks acpmux `_acpmux/ask` about the
//   open chat and sends no prompt; the answer shows above the composer.
// - Dismiss forgets it.
// - Add to chat sends the question to the chat as a prompt (`session/prompt`).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { REPLAY_SESSION, replayFixtureEvents } from "../src/agent-session/acpmux/replay/replayFixture";

await requireBrowserLane("agent-pane-side-question.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-side-question: skipping (run `bunx playwright install chromium`)");
    describe.skip("side question", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const events = replayFixtureEvents();
  const summary = {
    sessionId: REPLAY_SESSION,
    cwd: "/home/dev/api",
    title: "Fix the flaky retry test",
    harness: "claude",
    status: "idle",
    updatedAt: events.at(-1)!.at,
  };
  const asks: Record<string, unknown>[] = [];
  const prompts: Record<string, any>[] = [];
  const ANSWER = "The retry test raced the backoff timer.";

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "_acpmux/ask":
        asks.push(params);
        return { sessionId: params.sessionId, text: ANSWER, stopReason: "end_turn" };
      case "session/prompt":
        prompts.push(params);
        return { stopReason: "end_turn" };
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
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
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
    // again if it stalls, so the tests time only the side question.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("All 12 tests in api/client.test.ts pass.").waitFor({ timeout: 25_000 });
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

  async function openChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"side-question":"on"}'));
    await page.goto(url());
    await page.getByText("All 12 tests in api/client.test.ts pass.").waitFor();
    return page;
  }

  async function btw(page: Page, question: string): Promise<void> {
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(`/btw ${question}`);
    await page.keyboard.press("Enter");
  }

  describe("side question", () => {
    test("/btw answers above the composer without sending a prompt, and Dismiss forgets it", async () => {
      const page = await openChat();
      asks.length = 0;
      prompts.length = 0;
      await btw(page, "why did it flake?");
      const card = page.getByRole("region", { name: "Side question" });
      await card.getByText(ANSWER).waitFor();
      expect(await card.getByText("why did it flake?").count()).toBe(1);
      expect(asks).toEqual([{ sessionId: REPLAY_SESSION, text: "why did it flake?" }]);
      expect(prompts).toEqual([]);
      expect((await page.locator(".acpmux-composer-prompt .ProseMirror").innerText()).trim()).toBe("");

      await card.getByRole("button", { name: "Dismiss" }).click();
      await card.waitFor({ state: "detached" });
      expect(prompts).toEqual([]);
      await page.close();
    });

    test("Add to chat sends the side question to the chat as a prompt", async () => {
      const page = await openChat();
      asks.length = 0;
      prompts.length = 0;
      await btw(page, "is the timer mocked?");
      const card = page.getByRole("region", { name: "Side question" });
      await card.getByText(ANSWER).waitFor();

      await card.getByRole("button", { name: "Add to chat" }).click();
      await card.waitFor({ state: "detached" });
      for (let i = 0; i < 100 && prompts.length === 0; i++) await page.waitForTimeout(50);
      expect(prompts.map((p) => p.sessionId)).toEqual([REPLAY_SESSION]);
      expect(prompts[0].prompt).toEqual([{ type: "text", text: "is the timer mocked?" }]);
      await page.close();
    });
  });
});
