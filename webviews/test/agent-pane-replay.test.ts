// Session replay in the real agent pane (cx-osmw). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon that serves one recorded chat (replay/replayFixture.ts) through
// `_acpmux/events`, as acpmux does.
//
// - With the session-replay experiment on, the chat menu's Replay plays the chat back read-only:
//   the prompt first, the answer only once replay time reaches it, no composer.
// - Back returns to the live chat.
// - `]` and `[` jump between tool calls, the scrubber moves replay time either way, and the speed
//   button plays it faster.
// - Continue from here forks the chat through the last turn the replay has finished
//   (`acp.session.fork`) and opens the fork.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
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
  const forkRequests: Record<string, unknown>[] = [];
  const FORK = "forked-session";

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: ["acp.session.fork"] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        if (params.sessionId === FORK)
          return { session: { ...summary, sessionId: FORK, title: "Forked chat" }, lastSeq: 0, events: [] };
        return { session: summary, lastSeq: events.length, events };
      case "acp.session.fork":
        forkRequests.push(params);
        return { sessionId: FORK };
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // In CI the first load of a cold dev server never showed the chat, while every later load
    // did within seconds. Load it here, again if it stalls, so the tests time only the replay;
    // a stalled load's page errors go to the log.
    const { port } = vite.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon.port}/`;
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      const errors: string[] = [];
      warm.on("pageerror", (error) => errors.push(error.message));
      warm.on("console", (message) => message.type() === "error" && errors.push(message.text()));
      await warm.goto(
        `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`,
      );
      try {
        await warm.getByText("All 12 tests in api/client.test.ts pass.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        console.warn(`agent-pane-replay: load ${attempt} stalled`, errors);
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
    eventRequests.length = 0;
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
        composers: await page.locator(".acpmux-composer-prompt").count(),
        // The clock may have ticked by now; its length is fixed.
        length: (await replay.locator(".acpmux-replay-clock").textContent())?.split(" / ")[1],
      };
      // The turn took over a minute; replay shortens its 45 s wait to 2 s.
      await replay.getByText("All 12 tests in api/client.test.ts pass.").waitFor({ timeout: 40_000 });
      // The turn ends at 0:17, after its last words: Pause turns back into Play.
      await replay.getByRole("button", { name: "Play", exact: true }).waitFor();
      const ended = await replay.getByRole("button", { name: "Play", exact: true }).count();

      await replay.getByRole("button", { name: "Back to chat" }).click();
      await page.locator(".acpmux-replay").waitFor({ state: "detached" });
      await page.locator(".acpmux-composer-prompt").waitFor();
      const liveComposers = await page.locator(".acpmux-composer-prompt").count();

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

    test("jumps between tool calls, scrubs both ways and plays faster", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"session-replay":"on"}'));
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(
        `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`,
      );
      await page.getByText("All 12 tests in api/client.test.ts pass.").waitFor();
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Replay" }).click();
      const replay = page.locator(".acpmux-replay");
      const answer = replay.getByText("All 12 tests in api/client.test.ts pass.");
      const clock = async () => (await replay.locator(".acpmux-replay-clock").textContent())?.split(" / ")[0];
      await replay.getByRole("button", { name: "Pause", exact: true }).click();
      // The keys act on the replay while the Pause button keeps focus.

      // Tool calls start at 0:02 (read), 0:04 (tests), 0:11 (edit) and 0:13 (tests again).
      const jumps: (string | undefined)[] = [];
      for (const key of ["]", "]", "]", "[", "["]) {
        await page.keyboard.press(key);
        jumps.push(await clock());
      }

      const scrub = replay.getByRole("slider", { name: "Replay position" });
      await scrub.fill("17700");
      await answer.waitFor();
      await scrub.fill("0");
      await answer.waitFor({ state: "detached" });
      const rewound = await clock();

      const speeds: (string | null)[] = [];
      for (let step = 0; step < 4; step++) {
        await replay.getByRole("button", { name: "Playback speed" }).click();
        speeds.push(await replay.getByRole("button", { name: "Playback speed" }).textContent());
      }
      const started = Date.now();
      await replay.getByRole("button", { name: "Play", exact: true }).click();
      await answer.waitFor({ timeout: 15_000 });
      // 17.7 s of replay time at 16x.
      const fast = Date.now() - started < 8_000;

      expect({ jumps, rewound, speeds, fast }).toEqual({
        jumps: ["0:02", "0:04", "0:11", "0:04", "0:02"],
        rewound: "0:00",
        speeds: ["2×", "4×", "8×", "16×"],
        fast: true,
      });
      await page.close();
    });

    test("continues from the replayed point as a new live chat", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      await page.addInitScript(() => localStorage.setItem("cmux.experiments", '{"session-replay":"on"}'));
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(
        `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${REPLAY_SESSION}`,
      );
      await page.getByText("All 12 tests in api/client.test.ts pass.").waitFor();
      await page.getByRole("button", { name: "Chat actions" }).click();
      await page.getByRole("menuitem", { name: "Replay" }).click();
      const replay = page.locator(".acpmux-replay");
      await replay.getByRole("button", { name: "Pause" }).click();
      const proceed = replay.getByRole("button", { name: "Continue from here" });
      // Mid-turn nothing has finished yet.
      await replay.getByRole("slider", { name: "Replay position" }).fill("9000");
      const midTurn = await proceed.isDisabled();
      // The turn ends (turn_result, seq 17) at the end of the replay.
      await replay.getByRole("slider", { name: "Replay position" }).fill("17700");
      await replay.getByText("All 12 tests in api/client.test.ts pass.").waitFor();
      await proceed.click();
      await page.locator(".acpmux-replay").waitFor({ state: "detached" });
      await page.locator(".acpmux-composer-prompt").waitFor();

      expect({ midTurn, forks: forkRequests }).toEqual({
        midTurn: true,
        forks: [{ sessionId: REPLAY_SESSION, throughSeq: 17 }],
      });
      await page.close();
    });
  });
});
