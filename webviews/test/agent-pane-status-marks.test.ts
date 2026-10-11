// The chat list draws each chat's status mark from acpmux's `indicator` (cx-zlox), so it agrees
// with the Mac tab strip and sidebar, which read the same field. The page is the pane's dev entry
// (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon whose chats carry an `indicator` that their other fields alone would not
// give, so a mark worked out from `status` instead shows up wrong.
//
// - `failed`: a turn failed while the agent still runs (status idle): the error mark.
// - `done`: the agent left after it answered (status disconnected): no error mark.
// - `lost`: the agent left before it answered: the error mark.
// - `input`: a question waits: the needs-input mark.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-status-marks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-status-marks: skipping (run `bunx playwright install chromium`)");
    describe.skip("status marks", () => test("chromium", () => {}));
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
    chat("open", "Open chat", { status: "idle", indicator: null }),
    chat("failed", "Failed turn", { status: "idle", lastTurn: { status: "failed" }, indicator: "failed" }),
    chat("answered", "Answered then left", {
      status: "disconnected",
      lastTurn: { status: "completed" },
      indicator: "done",
    }),
    chat("lost", "Left mid-answer", { status: "disconnected", lastTurn: { status: "cancelled" }, indicator: "lost" }),
    chat("asking", "Asks a question", { status: "waiting", pendingPermissions: 1, indicator: "input" }),
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  describe("status marks", () => {
    test("each chat's mark is the indicator acpmux sent", async () => {
      const page = await browser!.newPage({ viewport: { width: 1200, height: 800 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=open`);
      await page.locator('[data-session-id="asking"]').waitFor();
      const marks = await page.evaluate(() =>
        Object.fromEntries(
          [...document.querySelectorAll<HTMLElement>("[data-session-id]")].map((row) => [
            row.dataset.sessionId,
            [...(row.querySelector(".acpmux-session-mark")?.classList ?? [])]
              .find((name) => name.startsWith("acpmux-session-mark-"))
              ?.slice("acpmux-session-mark-".length) ?? null,
          ]),
        ),
      );
      expect(marks).toEqual({ open: null, failed: "error", answered: null, lost: "error", asking: "input" });
      await page.close();
    });
  });
});
