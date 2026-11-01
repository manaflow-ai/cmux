// A chat on an SSH machine (an acpmux peer) in the real agent pane (cx-7ooz). The page is the
// pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host (src/dev-host/host.ts), so
// its own transport talks JSON-RPC over a WebSocket to a stand-in acpmux daemon here. The daemon
// relays the peer's session as acpmux does (hub/peers.rs): the summary names the peer and every
// event keeps the peer's own clock, here ten minutes behind this computer's.
//
// - The running turn's "Working for" counts from when the prompt was sent, not from the peer's
//   clock (Lawrence 2026-10-09: it showed "Thinking", then a wrong "Working for n").
// - The chat has started, so the composer shows no location strip: neither this Mac nor the peer
//   is offered as a machine to switch to mid-chat.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-peer-chat.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-peer-chat: skipping (run `bunx playwright install chromium`)");
    describe.skip("a chat on an SSH machine", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const PEER = "gpu-box";
  const SESSION = "peer-session-1";
  /// The peer's clock runs ten minutes behind this computer's.
  const SKEW_MS = 10 * 60_000;
  const peerNow = () => Date.now() - SKEW_MS;

  let promptAt = 0;
  let socket: Bun.ServerWebSocket<unknown> | undefined;
  const summary = () => ({
    sessionId: SESSION,
    peer: PEER,
    cwd: "/home/dev/project",
    title: "Fix the build",
    harness: "claude",
    status: "running",
    updatedAt: peerNow(),
  });

  /// The answers the pane needs to open a running chat; anything else gets an empty result.
  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/status":
        return { peers: [{ name: PEER }] };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return {
          session: summary(),
          lastSeq: 1,
          events: [
            {
              sessionId: SESSION,
              seq: 1,
              at: promptAt,
              dir: "mux",
              kind: "user_message",
              msg: { text: "Fix the build" },
            },
          ],
        };
      case "_acpmux/events":
        return { events: [] };
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
        open(ws) {
          socket = ws;
        },
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
    // In CI the first load of the dev server can stall past 30 s while it transforms deps
    // (#20276's run 38480535894), as in agent-pane-replay. Load it here, again if it stalls, so
    // the test times only the chat; a stalled load's page errors go to the log.
    const { port } = vite.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon.port}/`;
    for (let attempt = 1; ; attempt++) {
      promptAt = peerNow() - 5_000;
      const warm = await browser.newPage();
      const errors: string[] = [];
      warm.on("pageerror", (error) => errors.push(error.message));
      warm.on("console", (message) => message.type() === "error" && errors.push(message.text()));
      await warm.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      try {
        await warm.locator(".cv-worked").first().waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        console.warn(`agent-pane-peer-chat: load ${attempt} stalled`, errors);
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

  describe("a chat on an SSH machine", () => {
    for (const rejected of ["folder", "model", "start"] as const) {
      const name =
        rejected === "start"
          ? "composer Send after a rejected seeded peer start runs the prompt only on that peer"
          : `a rejected seeded peer ${rejected} keeps its connection for an explicit corrected retry`;
      test(name, async () => {
        const cwd = "/home/dev/project";
        const model = "fixture-model";
        const seed = {
          peer: PEER,
          harness: "fake",
          cwd: rejected === "folder" ? "/missing/project" : cwd,
          model: rejected === "model" ? "missing-model" : model,
        };
        const failure =
          rejected === "folder"
            ? "Peer folder does not exist"
            : rejected === "model"
              ? "Peer model is unavailable"
              : "Peer could not start the chat";
        type Start = { cwd?: string; _meta?: { acpmux?: { peer?: string; harness?: string; model?: string } } };
        type Prompt = { sessionId?: string; prompt?: { type: string; text?: string }[] };
        type Fixture = { ready: number; persisted: string[] };
        type Pane = {
          peerStartupFixture: Fixture;
          cmuxAcpmuxActions: Record<string, (args: Record<string, unknown>) => Promise<unknown>>;
          seededPeerAction?: unknown;
        };
        const starts: Start[] = [];
        const prewarms: Start[] = [];
        const prompts: Prompt[] = [];
        const prompted = Promise.withResolvers<void>();
        const connections = { opened: 0, initialized: 0, closed: 0 };
        const live = new Set<Bun.ServerWebSocket<unknown>>();
        const closed = Promise.withResolvers<void>();
        let created: string | undefined;
        const chat = () => ({
          ...summary(),
          sessionId: created ?? SESSION,
          peer: created === SESSION ? PEER : undefined,
          cwd,
          harness: "fake",
          model,
          status: "idle",
        });
        const peerDaemon = Bun.serve({
          port: 0,
          hostname: "127.0.0.1",
          fetch(request, server) {
            return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
          },
          websocket: {
            open(ws) {
              connections.opened += 1;
              live.add(ws);
            },
            close(ws) {
              connections.closed += 1;
              live.delete(ws);
              closed.resolve();
            },
            message(ws, raw) {
              const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Start & Prompt };
              if (message.id === undefined) return;
              if (message.method === "initialize") connections.initialized += 1;
              let result: unknown;
              if (message.method === "initialize") {
                result = {
                  protocolVersion: 1,
                  _meta: { acpmux: { origin: "local", extensions: ["_acpmux/prewarm"] } },
                };
              } else if (message.method === "_acpmux/prewarm") {
                prewarms.push(message.params ?? {});
                result = null;
              } else if (message.method === "session/new") {
                const params = message.params ?? {};
                starts.push(params);
                if (
                  rejected === "start"
                    ? starts.length === 1
                    : params.cwd !== cwd || params._meta?.acpmux?.model !== model
                ) {
                  // A normal RPC refusal leaves the established transport healthy.
                  ws.send(
                    JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32602, message: failure } }),
                  );
                  return;
                }
                // Accept a mistakenly local start too, so the regression observes its routing
                // and prompt destination instead of passing because the daemon refused it.
                created = params._meta?.acpmux?.peer === PEER ? SESSION : "local-session-1";
                result = { sessionId: created };
              } else if (message.method === "session/prompt") {
                prompts.push(message.params ?? {});
                result = { stopReason: "end_turn" };
                prompted.resolve();
              } else if (message.method === "_acpmux/watch") result = { sessions: created ? [chat()] : [] };
              else if (message.method === "_acpmux/attach") result = { session: chat(), lastSeq: 0, events: [] };
              else result = answer(message.method);
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
            },
          },
        });
        const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
        try {
          // Let startup and the refusal paint before taking control of the page's clock.
          await page.clock.install();
          await page.addInitScript(
            ({ endpoint, seed }) => {
              const fixture = { ready: 0, persisted: [] as string[] };
              const w = window as unknown as Record<string, unknown>;
              w.peerStartupFixture = fixture;
              w.webkit = {
                messageHandlers: {
                  agentSession: {
                    postMessage: async (request: { method: string; params?: { sessionId?: string } }) => {
                      if (request.method === "ready") {
                        fixture.ready += 1;
                        return {
                          ok: true,
                          value: {
                            protocolVersion: 1,
                            transport: "acpmux-websocket",
                            endpoint,
                            token: "t",
                            newSession: true,
                            ...seed,
                          },
                        };
                      }
                      if (request.method === "chat.persistSession" && request.params?.sessionId)
                        fixture.persisted.push(request.params.sessionId);
                      return { ok: true, value: null };
                    },
                  },
                },
              };
            },
            { endpoint: `ws://127.0.0.1:${peerDaemon.port}/`, seed },
          );
          const { port } = vite!.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${port}/`);
          await page.getByText(failure, { exact: true }).first().waitFor();
          await page.evaluate(() => {
            const w = window as unknown as Pane;
            w.seededPeerAction = w.cmuxAcpmuxActions["chat.new"];
          });
          // This used to reconnect, replace a still-open client, and retry session/new every
          // 250 ms because a successful handshake reset the backoff before each refusal.
          // Pause only after the notice is visible, then deterministically cross that delay;
          // a retry before the pause is still caught by the total handshake/connection counts.
          await page.clock.pauseAt(await page.evaluate(() => Date.now() + 1_000));
          await page.clock.runFor(1_000);
          expect(await page.evaluate(() => (window as unknown as Pane).peerStartupFixture.ready)).toBe(1);
          expect(connections).toEqual({ opened: 1, initialized: 1, closed: 0 });
          expect(live.size).toBe(1);
          expect(starts).toEqual([
            expect.objectContaining({
              cwd: seed.cwd,
              _meta: { acpmux: { peer: PEER, harness: "fake", model: seed.model } },
            }),
          ]);
          expect(
            await page.evaluate(() => {
              const w = window as unknown as Pane;
              return w.seededPeerAction === w.cmuxAcpmuxActions["chat.new"];
            }),
          ).toBe(true);

          if (rejected === "start") {
            // Use the real composer path: projectDraft used to call chat.new with cwd but no
            // peer, bypassing ensureSession's remote retry and sending this prompt locally.
            await page.clock.resume();
            const editor = page.locator(".acpmux-composer-prompt .ProseMirror");
            await editor.fill("Run this only on the peer");
            await editor.press("Enter");
            await prompted.promise;
            expect(prompts).toEqual([
              expect.objectContaining({
                sessionId: SESSION,
                prompt: [{ type: "text", text: "Run this only on the peer" }],
              }),
            ]);
            // The daemon supports local prewarm, but typing into a pending peer chat must not
            // run that peer's project folder on this computer before the actual remote start.
            expect(prewarms).toEqual([]);
            const fixture = await page.evaluate(() => (window as unknown as Pane).peerStartupFixture);
            expect(fixture.ready).toBe(1);
            expect(fixture.persisted.length).toBeGreaterThan(0);
            expect(fixture.persisted.every((id) => id === SESSION)).toBe(true);
          } else {
            const started = await page.evaluate(
              async (args) => {
                const w = window as unknown as Pane;
                return w.cmuxAcpmuxActions["chat.new"]!(args);
              },
              { peer: PEER, harness: "fake", cwd, model },
            );
            expect(started).toBe(SESSION);
            expect(await page.evaluate(() => (window as unknown as Pane).peerStartupFixture)).toEqual({
              ready: 1,
              persisted: [SESSION],
            });
          }
          expect(starts).toHaveLength(2);
          expect(starts[1]).toEqual(
            expect.objectContaining({ cwd, _meta: { acpmux: { peer: PEER, harness: "fake", model } } }),
          );
          expect(connections).toEqual({ opened: 1, initialized: 1, closed: 0 });
          expect(live.size).toBe(1);
          await page.close();
          await closed.promise;
          expect(connections.closed).toBe(1);
          expect(live.size).toBe(0);
        } finally {
          await page.close();
          await peerDaemon.stop(true);
        }
      });
    }

    test("counts its running turn from the prompt and offers no machine switch mid-chat", async () => {
      // The prompt went out 5 seconds ago, by the peer's clock.
      promptAt = peerNow() - 5_000;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.locator(".cv-worked").first().waitFor();
      const send = (seq: number, kind: string, update: Record<string, unknown>) =>
        socket!.send(
          JSON.stringify({
            jsonrpc: "2.0",
            method: "_acpmux/event",
            params: {
              sessionId: SESSION,
              seq,
              at: peerNow(),
              dir: "in",
              kind,
              msg: { method: "session/update", params: { update: { sessionUpdate: kind, ...update } } },
            },
          }),
        );
      // The peer starts a tool call: the turn has work now. Its stamp is the first live event, the
      // one the pane reads the peer's clock from (direct.ts `observeClock`).
      send(2, "tool_call", { toolCallId: "t1", title: "Run make", kind: "execute", status: "in_progress" });
      // The call in flight ("Run make") is named once, on the turn's live line (Thinking.tsx, the
      // Codex-style turn). The line already reads before the call comes in: wait for the call's name.
      const row = page.locator(".cv-thinking", { hasText: "Run make" });
      await row.first().waitFor();
      const named = await row.count();
      // The call ends: the live line holds it until the next step and times the turn from the
      // prompt ("Run make 5s"), moved onto this computer's clock, as it did while the call ran.
      send(3, "tool_call_update", { toolCallId: "t1", status: "completed" });
      const time = page.locator(".cv-worked.is-below .cv-worked__time");
      await time.waitFor();
      const label = (await time.textContent()) ?? "";
      const seconds = /^(\d+)s$/.exec(label)?.[1];
      const strips = await page.locator(".acpmux-composer-strip").count();
      // A few seconds (page load included), never the peer's ten minutes of clock skew.
      expect({
        label,
        recent: seconds !== undefined && Number(seconds) >= 4 && Number(seconds) < 30,
        named,
        strips,
      }).toEqual({
        label: expect.stringMatching(/^\d+s$/),
        recent: true,
        named: 1,
        strips: 0,
      });
      await page.close();
    });
  });
});
