// A new chat's home lists the other chats waiting on the user by acpmux's `indicator` (cx-zlox),
// so it agrees with the Mac tab strip and sidebar, which read the same field. The page is the
// pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a
// WebSocket to a stand-in acpmux daemon.
//
// - A question waiting on a running agent (`input`) is listed.
// - A question on a peer that went unreachable (`lost`: nobody can answer it now) is not, though
//   the summary still counts the pending permission.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-status-marks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-status-marks: skipping (run `bunx playwright install chromium`)");
    describe.skip("home waiting list", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const chat = (sessionId: string, title: string, fields: Record<string, unknown>) => ({
    sessionId,
    cwd: "/home/dev/api",
    title,
    harness: "codex",
    updatedAt: Date.now(),
    ...fields,
  });
  const sessions = [
    chat("open", "New chat", { status: "idle", turnCount: 0, indicator: null }),
    chat("asking", "Asks a question", {
      status: "waiting",
      pendingPermissions: 1,
      indicator: "input",
    }),
    chat("stranded", "Stranded on a peer", {
      status: "unreachable",
      peer: "build-box",
      pendingPermissions: 1,
      indicator: "lost",
    }),
  ];

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions };
      case "_acpmux/attach":
        return { session: sessions[0], lastSeq: 0, events: [] };
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          const result = answer(message.method);
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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

  describe("home waiting list", () => {
    test("the home lists a chat as waiting only when acpmux says input", async () => {
      const page = await browser!.newPage({ viewport: { width: 1200, height: 800 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=open`);
      // The home's waiting list is the inbox (66f0a85e43f0, #25325): a row per ask, naming its chat.
      const rows = page.locator(".acpmux-home-inbox-row");
      await rows.filter({ hasText: "Asks a question" }).waitFor();
      // The stranded chat's ask waits on nobody: its machine is unreachable (indicator `lost`).
      const listed = await rows.locator(".acpmux-home-inbox-where").allInnerTexts();
      expect(listed).toHaveLength(1);
      expect(listed[0]).toContain("Asks a question");
      await page.close();
    });
  });
});
