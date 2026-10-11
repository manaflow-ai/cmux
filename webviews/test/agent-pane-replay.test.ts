// Session replay in the real agent pane (cx-osmw). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon that serves one recorded chat (replay/replayFixture.ts) through
// `_acpmux/events`, as acpmux does.
//
// - With the session-replay experiment on, the chat menu's Replay plays the chat back read-only:
//   the prompt first, the answer only once replay time reaches it, no composer.
// - Back returns to the live chat.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { REPLAY_SESSION, replayFixtureEvents } from "../src/agent-session/acpmux/replay/replayFixture";

await requireBrowserLane("agent-pane-replay.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-replay: skipping (run `bunx playwright install chromium`)");
    describe.skip("session replay", () => test("chromium", () => {}));
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
  const eventRequests: Record<string, unknown>[] = [];

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: events.length, events };
      case "_acpmux/events": {
        eventRequests.push(params);
        const after = Number(params.afterSeq ?? 0);
        const before = Number(params.beforeSeq ?? Number.POSITIVE_INFINITY);
        const page = events.filter((event) => event.seq > after && event.seq < before);
        return { events: page, hasMore: false, lastSeq: events.length };
      }
      default:
        return null;
    }
  }

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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  describe("session replay", () => {
    test("plays a recorded chat back read-only from the chat menu, then returns to the live chat", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"session-replay":"on"}'));
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(
        `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`,
      );
      // The live chat shows the whole turn, answer included.
      await page.getByText("All 12 tests in api/client.test.ts pass.").waitFor();

      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Replay" }).click();

      const replay = page.locator(".acpmux-replay");
      await replay.getByText("The retry test in api/client.test.ts is flaky.", { exact: false }).waitFor();
      const opening = {
        answerShown: await replay.getByText("All 12 tests in api/client.test.ts pass.").count(),
        composers: await page.locator(".acpmux-composer-field").count(),
        // The clock may have ticked by now; its length is fixed.
        length: (await replay.locator(".acpmux-replay-clock").textContent())?.split(" / ")[1],
      };
      // The turn took over a minute; replay shortens its 45 s wait to 2 s.
      await replay.getByText("All 12 tests in api/client.test.ts pass.").waitFor({ timeout: 40_000 });
      const ended = await replay.getByRole("button", { name: "Play" }).count();

      await replay.getByRole("button", { name: "Back to chat" }).click();
      await page.locator(".acpmux-replay").waitFor({ state: "detached" });
      const liveComposers = await page.locator(".acpmux-composer-field").count();

      expect({
        opening,
        ended,
        liveComposers,
        read: eventRequests.some((params) => params.sessionId === REPLAY_SESSION && params.afterSeq === 0),
      }).toEqual({
        opening: { answerShown: 0, composers: 0, length: "0:17" },
        ended: 1,
        liveComposers: 1,
        read: true,
      });
      await page.close();
    });
  });
});
