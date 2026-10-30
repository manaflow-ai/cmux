// An agent's offer of a parallel chat in the real agent pane (cx-807da). The page is the pane's
// dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket
// to a stand-in acpmux daemon that answers the way `hub/offers.rs` does.
//
// - With the session-offer experiment off, the offer draws nothing.
// - With it on, the offer is a card with its title (offer/SuggestedTasks.tsx). Start starts a new
//   chat in the offer's folder on its agent, sends it the offer's prompt, and answers the offer
//   with that chat; the pane keeps showing this chat, and the card becomes the started chat's row.
//   Dismiss answers the offer dismissed, and acpmux's decision takes the card away.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-session-offer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-session-offer: skipping (run `bunx playwright install chromium`)");
    describe.skip("session offer", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "offer-session";
  const CHILD = "offered-child";
  const summary = (sessionId = SESSION) => ({
    sessionId,
    cwd: "/home/dev/api",
    title: "Add the upload endpoint",
    harness: "claude",
    status: "running",
    updatedAt: Date.now(),
  });
  type Record_ = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
  const offer = {
    offerId: "offer-1",
    title: "Fix the flaky upload test",
    prompt: "The upload test fails one run in five: find why and fix it.",
    cwd: "/home/dev/api",
    worktree: false,
    harness: "codex",
    model: "gpt-5.5",
  };
  let seq = 0;
  let history: Record_[] = [];
  let calls: { method: string; params: Record<string, any> }[] = [];
  /// Run after each call the daemon hears.
  const onCall = new Set<() => void>();
  let wanted: string[] | undefined;

  const record = (kind: string, msg: Record<string, unknown>): Record_ => ({
    sessionId: SESSION,
    seq: ++seq,
    at: Date.now(),
    dir: "mux",
    kind,
    msg,
  });
  /// acpmux's EventFilter::matches for the attach's kinds (`transcript` holds both offer kinds,
  /// the turn's records and the agent's output).
  const passes = (rec: Record_) =>
    !wanted ||
    wanted.some((k) =>
      k === "all" || k === "mux"
        ? rec.dir === "mux"
        : k === "transcript"
          ? rec.dir === "in" ||
            (rec.dir === "mux" &&
              ["user_message", "session_offer", "session_offer_decision", "turn_end", "turn_result"].includes(rec.kind))
          : k === rec.kind,
    );

  type Socket = { send(data: string): void };
  const emit = (ws: Socket, rec: Record_) => {
    if (passes(rec)) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
  };

  function answer(ws: Socket, method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    calls.push({ method, params: { ...params } });
    for (const listener of onCall) listener();
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions: [summary()] } };
      case "_acpmux/attach":
        if (params.sessionId !== SESSION) return { result: { session: summary(CHILD), lastSeq: 0, events: [] } };
        wanted = Array.isArray(params.kinds) ? params.kinds : undefined;
        return { result: { session: summary(), lastSeq: seq, events: history.filter(passes) } };
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: seq } };
      case "session/new":
        return { result: { sessionId: CHILD } };
      case "session/prompt":
        return { result: { stopReason: "end_turn" } };
      case "_acpmux/offer_respond": {
        if (params.sessionId !== SESSION || params.offerId !== offer.offerId)
          return { error: { code: -32602, message: "no open offer has that offerId" } };
        const decision: Record<string, unknown> = { offerId: offer.offerId, outcome: params.outcome };
        if (params.childSessionId) decision.childSessionId = params.childSessionId;
        emit(ws, record("session_offer_decision", decision));
        return { result: decision };
      }
      default:
        return { result: null };
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
          const reply = answer(ws, message.method, message.params ?? {});
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }));
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(experiment: "on" | "off", turnEnded = false): Promise<Page> {
    calls = [];
    seq = 0;
    history = [record("user_message", { text: "Add the upload endpoint" }), record("session_offer", offer)];
    // The agent answered after its offer, and its turn ended: the turn's work folds away.
    if (turnEnded) {
      const update = {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Offered a parallel chat." },
      };
      history.push(
        {
          ...record("agent_message_chunk", { method: "session/update", params: { sessionId: SESSION, update } }),
          dir: "in",
        },
        record("turn_end", { stopReason: "end_turn" }),
        record("turn_result", { status: "completed", stopReason: "end_turn" }),
      );
    }
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.addInitScript(
      (arm) => localStorage.setItem("cmux.experiments", JSON.stringify({ "session-offer": arm })),
      experiment,
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // The file's first page loads the pane's modules cold; on a busy runner that took over 10 s.
    await page.getByText("Add the upload endpoint").first().waitFor({ timeout: 60_000 });
    return page;
  }
  /// Waits until `done` holds, checking after each call the daemon hears (at most 5 s).
  async function waitUntil(done: () => boolean) {
    await new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!done()) return;
        onCall.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        onCall.delete(check);
        reject(new Error(`the daemon never heard what ${String(done)} waits for`));
      }, 5_000);
      onCall.add(check);
      check();
    });
  }
  const chip = (page: Page) => page.locator(".acpmux-tasks");

  describe("an agent's session offer", () => {
    test("with the experiment off, the offer draws nothing", async () => {
      const page = await openChat("off");
      // The offer comes in the same attach answer as the message that is drawn now (with the
      // experiment on it draws with it); a painted frame more for anything that answer earns.
      await page.evaluate(() => window.cmuxPaintFrame());
      expect(await chip(page).count()).toBe(0);
      expect(await page.locator("body").innerText()).not.toContain(offer.title);
      await page.close();
    });

    test("Start starts the offered chat beside this one and answers the offer with it", async () => {
      const page = await openChat("on");
      await chip(page).getByText(offer.title).waitFor({ timeout: 10_000 });
      await chip(page).getByRole("button", { name: "Start", exact: true }).click();
      await chip(page).getByText("Started").waitFor({ timeout: 10_000 });

      const created = calls.find((c) => c.method === "session/new");
      expect(created?.params.cwd).toBe(offer.cwd);
      expect(created?.params._meta?.acpmux?.harness).toBe("codex");
      expect(created?.params.model).toBe("gpt-5.5");
      // The prompt goes after the answer, and its turn ends at once here: its attach ends with it.
      await waitUntil(() => calls.some((c) => c.method === "_acpmux/detach" && c.params.sessionId === CHILD));
      const prompt = calls.find((c) => c.method === "session/prompt");
      expect(prompt?.params.sessionId).toBe(CHILD);
      expect(JSON.stringify(prompt?.params.prompt)).toContain(offer.prompt);
      const respond = calls.filter((c) => c.method === "_acpmux/offer_respond");
      expect(respond.map((c) => c.params)).toEqual([
        { sessionId: SESSION, offerId: offer.offerId, outcome: "accepted", childSessionId: CHILD },
      ]);
      // This chat stays shown. The new one is attached only hidden, before its prompt (which would
      // attach it as seen), so its turn is not marked seen here.
      const childCalls = calls.filter((c) => c.params.sessionId === CHILD).map((c) => c.method);
      expect(childCalls).toEqual(["_acpmux/attach", "session/prompt", "_acpmux/detach"]);
      expect(calls.find((c) => c.method === "_acpmux/attach" && c.params.sessionId === CHILD)?.params.visible).toBe(
        false,
      );
      expect(await page.locator(".acpmux-task-row-title").first().innerText()).toBe(offer.title);
      expect(await chip(page).getByRole("button", { name: "Start", exact: true }).count()).toBe(0);
      await page.close();
    });

    test("an offer made during a turn stays out of the turn's fold once it ends", async () => {
      const page = await openChat("on", true);
      await page.getByText("Offered a parallel chat.").waitFor({ timeout: 10_000 });
      await chip(page).getByText(offer.title).waitFor({ timeout: 5_000 });
      expect(await chip(page).getByRole("button", { name: "Start", exact: true }).isVisible()).toBe(true);
      await page.close();
    });

    test("Dismiss answers the offer dismissed and starts nothing", async () => {
      const page = await openChat("on");
      await chip(page).getByRole("button", { name: "Dismiss" }).click();
      await chip(page).waitFor({ state: "detached", timeout: 10_000 });
      const respond = calls.filter((c) => c.method === "_acpmux/offer_respond");
      expect(respond.map((c) => c.params)).toEqual([
        { sessionId: SESSION, offerId: offer.offerId, outcome: "dismissed" },
      ]);
      expect(calls.some((c) => c.method === "session/new")).toBe(false);
      await page.close();
    });
  });
});
