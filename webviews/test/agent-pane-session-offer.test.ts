// An agent's offer of a parallel chat in the real agent pane (cx-807da). The page is the pane's
// dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket
// to a stand-in acpmux daemon that answers the way `hub/offers.rs` does.
//
// - With the session-offer experiment off, the offer draws nothing.
// - With it on, the offer is a card with its title (offer/SuggestedTasks.tsx). Start starts a new
//   chat in the offer's folder on its agent, sends it the offer's prompt, and answers the offer
//   with that chat; the pane keeps showing this chat, and the card becomes the started chat's row.
//   Dismiss answers the offer dismissed, and acpmux's decision takes the card away.
// - An offer's Options (offer/OfferOptions.tsx) start at "Default" for Effort and Permissions;
//   a pick goes to the new chat before its prompt, on this chat's agent, and a pick the new chat
//   refuses ends the start: no prompt, no answer, and the task stays open with that pick at Default.
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
    model: "opus",
    modes: {
      availableModes: [
        { id: "default", name: "Ask before edits" },
        { id: "bypassPermissions", name: "Bypass permissions" },
      ],
      currentModeId: "bypassPermissions",
    },
    configOptions: [
      {
        id: "model",
        category: "model",
        currentValue: "opus",
        options: [
          { value: "opus", name: "Opus 5.5" },
          { value: "sonnet", name: "Sonnet 5.5" },
        ],
      },
      {
        id: "effort",
        category: "thought_level",
        currentValue: "medium",
        options: [
          { value: "low", name: "Low" },
          { value: "medium", name: "Medium" },
          { value: "high", name: "High" },
        ],
      },
    ],
  });
  type Record_ = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
  const codexOffer = {
    offerId: "offer-1",
    title: "Fix the flaky upload test",
    prompt: "The upload test fails one run in five: find why and fix it.",
    cwd: "/home/dev/api",
    worktree: false,
    harness: "codex",
    model: "gpt-5.5",
  };
  /// An offer with no agent of its own: it runs on this chat's, whose lists its Options show.
  const ownOffer = {
    offerId: "offer-2",
    title: "Trim the upload log output",
    prompt: "The upload handler logs every chunk: keep only the first and the last.",
    cwd: "/home/dev/api",
    worktree: false,
  };
  let offer: typeof codexOffer | typeof ownOffer = codexOffer;
  /// The daemon refuses a permission mode (a stand-in for a ticket the host turned down).
  let refuseMode = false;
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
      case "session/set_mode":
        return refuseMode
          ? { error: { code: -32001, message: "gesture required", data: { code: "transport.gesture_required" } } }
          : { result: null };
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

  async function openChat(
    experiment: "on" | "off",
    turnEnded = false,
    offered: typeof codexOffer | typeof ownOffer = codexOffer,
  ): Promise<Page> {
    offer = offered;
    refuseMode = false;
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
      expect(created?.params._meta?.acpmux?.model).toBe("gpt-5.5");
      expect(created?.params.model).toBeUndefined();
      // Another agent's offer takes none of this chat's mode or effort.
      expect(calls.some((c) => c.method === "session/set_mode" || c.method === "session/set_config_option")).toBe(
        false,
      );
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

    /// Opens the task's Options and picks `name` from the `row` list.
    async function pickOption(page: Page, row: string, name: string) {
      const options = page.getByRole("dialog", { name: "Options" });
      if (!(await options.isVisible())) await chip(page).getByRole("button", { name: "Options" }).click();
      await options.getByText("This computer").waitFor({ timeout: 5_000 });
      await options.getByRole("button", { name: row }).click();
      await page.getByRole("menuitemradio", { name }).click();
    }

    test("Options start at Default; Start gives the new chat the picks, on this chat's agent, before its prompt", async () => {
      const page = await openChat("on", false, ownOffer);
      await chip(page).getByText(ownOffer.title).waitFor({ timeout: 10_000 });
      await chip(page).getByRole("button", { name: "Options" }).click();
      const options = page.getByRole("dialog", { name: "Options" });
      await options.getByText("This computer").waitFor({ timeout: 5_000 });
      // Nothing of this chat's own effort or mode is inherited: the new chat starts at its default.
      expect(await options.getByRole("button", { name: "Effort" }).innerText()).toContain("Default");
      expect(await options.getByRole("button", { name: "Permissions" }).innerText()).toContain("Default");
      await pickOption(page, "Model", "Sonnet 5.5");
      await pickOption(page, "Effort", "High");
      await pickOption(page, "Permissions", "Ask before edits");
      await page.keyboard.press("Escape");
      await chip(page).getByRole("button", { name: "Start", exact: true }).click();
      await waitUntil(() => calls.some((c) => c.method === "session/prompt" && c.params.sessionId === CHILD));

      const created = calls.find((c) => c.method === "session/new");
      // The model goes where the host takes it, and the lists' agent is pinned.
      expect(created?.params._meta?.acpmux?.model).toBe("sonnet");
      expect(created?.params.model).toBeUndefined();
      expect(created?.params._meta?.acpmux?.harness).toBe("claude");
      const childCalls = calls.filter((c) => c.params.sessionId === CHILD);
      const at = (method: string) => childCalls.findIndex((c) => c.method === method);
      expect(childCalls.find((c) => c.method === "session/set_mode")?.params.modeId).toBe("default");
      const effort = childCalls.find((c) => c.method === "session/set_config_option")?.params;
      expect([effort?.configId, effort?.value]).toEqual(["effort", "high"]);
      expect(at("session/set_mode")).toBeLessThan(at("session/prompt"));
      expect(at("session/set_config_option")).toBeLessThan(at("session/prompt"));
      await page.close();
    });

    test("untouched Options start the new chat on the default agent with nothing set", async () => {
      const page = await openChat("on", false, ownOffer);
      await chip(page).getByRole("button", { name: "Start", exact: true }).click();
      await waitUntil(() => calls.some((c) => c.method === "session/prompt" && c.params.sessionId === CHILD));
      const created = calls.find((c) => c.method === "session/new");
      expect(created?.params._meta?.acpmux?.harness).toBeUndefined();
      expect(created?.params._meta?.acpmux?.model).toBeUndefined();
      expect(calls.some((c) => c.method === "session/set_mode" || c.method === "session/set_config_option")).toBe(
        false,
      );
      await page.close();
    });

    test("a permission pick the new chat refuses ends the start before its prompt", async () => {
      const page = await openChat("on", false, ownOffer);
      refuseMode = true;
      await chip(page).getByText(ownOffer.title).waitFor({ timeout: 10_000 });
      await pickOption(page, "Permissions", "Ask before edits");
      await page.keyboard.press("Escape");
      await chip(page).getByRole("button", { name: "Start", exact: true }).click();
      await chip(page).getByRole("alert").waitFor({ timeout: 10_000 });
      expect(calls.some((c) => c.method === "session/set_mode" && c.params.sessionId === CHILD)).toBe(true);
      expect(calls.some((c) => c.method === "session/prompt")).toBe(false);
      expect(calls.some((c) => c.method === "_acpmux/offer_respond")).toBe(false);
      // The task stays open to try again, its spent permission pick back at Default.
      expect(await chip(page).getByRole("button", { name: "Start", exact: true }).isVisible()).toBe(true);
      await chip(page).getByRole("button", { name: "Options" }).click();
      const options = page.getByRole("dialog", { name: "Options" });
      await options.getByText("This computer").waitFor({ timeout: 5_000 });
      expect(await options.getByRole("button", { name: "Permissions" }).innerText()).toContain("Default");
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
