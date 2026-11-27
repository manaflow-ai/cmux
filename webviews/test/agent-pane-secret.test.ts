// An agent's secret card in the real agent pane (cx-ncc.42). The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon. The stand-in filters records the way acpmux does: an attach's `kinds`
// pass a record by exact kind or by category, and `transcript` passes acpmux's own
// TRANSCRIPT_MUX_KINDS (read from paging.rs), so a card the pane does not ask for never arrives.
//
// - The agent's ask shows the card; Provide sends the value; acpmux's decision closes the card.
// - A card acpmux no longer has (a daemon restart lost it) closes when Provide is refused.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-secret.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-secret: skipping (run `bunx playwright install chromium`)");
    describe.skip("secret card", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const paging = readFileSync(path.join(webviews, "../cmux-tui/crates/acpmux/src/hub/paging.rs"), "utf8");
  const transcriptMuxKinds = [
    ...(paging.match(/TRANSCRIPT_MUX_KINDS: &\[&str\] = &\[([\s\S]*?)\];/)?.[1] ?? "").matchAll(/"([^"]+)"/g),
  ].map((m) => m[1]);

  const SESSION = "secret-session";
  const VALUE = "sk-live-4f9a2c7e1b";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Create the webhook",
    harness: "codex",
    status: "waiting",
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
  const ask = { secretId: "card-1", name: "STRIPE_API_KEY", reason: "Create the test webhook" };
  let seq = 0;
  let history: Record_[] = [];
  let live = true; // whether acpmux still holds the card (false: a restart lost it)
  const submits: Record<string, unknown>[] = [];
  let wanted: string[] | undefined;

  /// acpmux's EventFilter::matches for the attach's kinds.
  const passes = (rec: Record_) =>
    !wanted ||
    wanted.some((k) =>
      k === "all"
        ? true
        : k === "transcript"
          ? rec.dir === "mux" && transcriptMuxKinds.includes(rec.kind)
          : k === "mux"
            ? rec.dir === "mux"
            : k === rec.kind,
    );
  const record = (kind: string, msg: Record<string, unknown>): Record_ => ({
    sessionId: SESSION,
    seq: ++seq,
    at: Date.now(),
    dir: "mux",
    kind,
    msg,
  });

  type Socket = { send(data: string): void };
  const emit = (ws: Socket, rec: Record_) => {
    if (passes(rec)) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
  };

  /// acpmux's answer (`result`, or `error` as acpmux refuses), and the records every client hears.
  function answer(ws: Socket, method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions: [summary()] } };
      case "_acpmux/attach": {
        wanted = Array.isArray(params.kinds) ? params.kinds : undefined;
        // The agent asks once the pane is attached.
        if (live) setTimeout(() => emit(ws, record("secret_request", ask)), 50);
        return { result: { session: summary(), lastSeq: seq, events: history.filter(passes) } };
      }
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: seq } };
      case "_acpmux/secret_submit": {
        submits.push({ ...params });
        if (!live || params.secretId !== ask.secretId)
          return { error: { code: -32602, message: "no secret request with that id in this chat" } };
        emit(ws, record("secret_decision", { secretId: ask.secretId, name: ask.name, outcome: "provided" }));
        return { result: {} };
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

  async function openChat(): Promise<Page> {
    submits.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    return page;
  }

  async function provide(page: Page) {
    const field = page.getByLabel("Value of STRIPE_API_KEY");
    await field.waitFor({ timeout: 10_000 });
    await field.fill(VALUE);
    await page.getByRole("button", { name: "Provide" }).click();
  }

  describe("an agent's secret card", () => {
    test("the agent's ask shows the card, Provide sends the value, and acpmux's answer closes it", async () => {
      live = true;
      history = [];
      const page = await openChat();
      // The file's first page loads the pane's modules cold; on a busy runner that took over 10 s.
      await page.getByText("Create the test webhook").waitFor({ timeout: 60_000 });
      await provide(page);
      await page.locator(".acpmux-secret-card").waitFor({ state: "detached" });
      expect(submits).toEqual([{ sessionId: SESSION, secretId: "card-1", value: VALUE }]);
      expect(await page.locator("body").innerText()).not.toContain(VALUE);
      await page.close();
    });

    test("a card acpmux no longer has closes when Provide is refused", async () => {
      // History holds the ask, but a restart lost the card: no decision ever comes.
      live = false;
      history = [record("secret_request", ask)];
      const page = await openChat();
      await provide(page);
      await page.locator(".acpmux-secret-card").waitFor({ state: "detached", timeout: 10_000 });
      expect(submits).toEqual([{ sessionId: SESSION, secretId: "card-1", value: VALUE }]);
      await page.close();
    });
  });
});
