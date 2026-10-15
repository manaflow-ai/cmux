// acpmux owns what the person has seen (cx-n8ou): the pane tells it whether it shows its chat,
// and draws acpmux's `unread`. The page is the pane's dev entry (vite.config.acpmux-pane.mjs) with
// its browser host, talking JSON-RPC over a WebSocket to a stand-in acpmux daemon that records what
// the pane sends.
//
// - The chat attaches with `visible` from the page's visibility.
// - Hiding the page (a tab in a background workspace, an occluded window) sends
//   `_acpmux/view` visible false; showing it again sends true.
// - acpmux handles each request on its own task, so a view sent while the attach is in flight
//   could overtake it and be refused; the pane sends it once the attach is answered.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-seen.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-seen: skipping (run `bunx playwright install chromium`)");
    describe.skip("seen", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "seen-session";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Refactor the parser",
    harness: "codex",
    status: "idle",
    updatedAt: Date.now(),
  };
  const sent: { method: string; params: Record<string, unknown> }[] = [];
  /// The first pane's `initialize` is answered this late: on a busy runner (dev server files run
  /// side by side, #19831) the first page's cold modules load slowly and its attach came after 10 s.
  const COLD_START_MS = 11_000;
  let coldStart = true;
  /// While set, the stand-in holds the attach's reply until `releaseAttach` runs.
  let holdAttach = false;
  let releaseAttach: (() => void) | undefined;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: ["_acpmux/view"] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: 0, events: [] };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return {};
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          sent.push({ method: message.method, params: message.params ?? {} });
          const result = answer(message.method);
          const reply = () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          if (message.id === undefined) return;
          if (coldStart && message.method === "initialize") {
            coldStart = false;
            setTimeout(reply, COLD_START_MS);
            return;
          }
          if (holdAttach && message.method === "_acpmux/attach") releaseAttach = reply;
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Sets the page's visibility as WebKit reports it for a hidden or shown web view.
  const setVisibility = (page: Page, state: "hidden" | "visible") =>
    page.evaluate((next) => {
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => next });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => next === "hidden" });
      document.dispatchEvent(new Event("visibilitychange"));
    }, state);

  const views = (from = 0) =>
    sent
      .slice(from)
      .filter((m) => m.method === "_acpmux/view")
      .map((m) => ({ sessionId: m.params.sessionId, visible: m.params.visible }));

  /// Waits until `done` holds (or `ms` pass).
  async function until(done: () => boolean, ms = 10_000): Promise<void> {
    const deadline = Date.now() + ms;
    while (!done() && Date.now() < deadline) await Bun.sleep(20);
  }

  /// A pane's first attach: its cold modules can take far longer than 10 s on a busy runner.
  const ATTACH_MS = 60_000;

  /// Waits until the pane has sent `count` `_acpmux/view` requests.
  const sentViews = (count: number) => until(() => views().length >= count);

  async function openPane(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    return page;
  }

  describe("seen", () => {
    test("the pane tells acpmux whether it shows its chat", async () => {
      const page = await openPane();
      // Closed even on a failure: a page left open would attach during the next test.
      try {
        const attached = () => sent.find((m) => m.method === "_acpmux/attach" && m.params.sessionId === SESSION);
        await until(() => attached() !== undefined, ATTACH_MS);
        const attach = attached();
        expect(attach?.params.visible).toBe(true);
        await setVisibility(page, "hidden");
        await sentViews(1);
        await setVisibility(page, "visible");
        await sentViews(2);
        expect(views()).toEqual([
          { sessionId: SESSION, visible: false },
          { sessionId: SESSION, visible: true },
        ]);
      } finally {
        await page.close();
      }
    }, 120_000);

    test("a pane hidden while its attach is in flight tells acpmux once the attach is answered", async () => {
      const from = sent.length;
      holdAttach = true;
      releaseAttach = undefined;
      const page = await openPane();
      try {
        await until(() => releaseAttach !== undefined, ATTACH_MS);
        expect(releaseAttach).toBeDefined();
        await setVisibility(page, "hidden");
        await Bun.sleep(500);
        // acpmux would refuse a view for a chat it has not attached yet.
        expect(views(from)).toEqual([]);
        holdAttach = false;
        releaseAttach!();
        await until(() => views(from).length >= 1);
        expect(views(from)).toEqual([{ sessionId: SESSION, visible: false }]);
      } finally {
        holdAttach = false;
        await page.close();
      }
    }, 120_000);
  });
});
