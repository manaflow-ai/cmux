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
    test("counts its running turn from the prompt and offers no machine switch mid-chat", async () => {
      // The prompt went out 5 seconds ago, by the peer's clock.
      promptAt = peerNow() - 5_000;
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.locator(".cv-worked").first().waitFor();

      // The peer starts a tool call: the turn has work now, under "Working for".
      socket!.send(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/event",
          params: {
            sessionId: SESSION,
            seq: 2,
            at: peerNow(),
            dir: "in",
            kind: "tool_call",
            msg: {
              method: "session/update",
              params: {
                update: {
                  sessionUpdate: "tool_call",
                  toolCallId: "t1",
                  title: "Run make",
                  kind: "execute",
                  status: "in_progress",
                },
              },
            },
          },
        }),
      );
      const working = page.locator(".cv-worked__label");
      await working.waitFor();
      const label = (await working.textContent()) ?? "";
      const seconds = /^Working for (\d+)s$/.exec(label)?.[1];
      const strips = await page.locator(".acpmux-composer-strip").count();
      // A few seconds (page load included), never the peer's ten minutes of clock skew.
      expect({
        label,
        recent: seconds !== undefined && Number(seconds) >= 4 && Number(seconds) < 30,
        strips,
      }).toEqual({
        label,
        recent: true,
        strips: 0,
      });
      await page.close();
    });

    test("Worked for keeps pointer focus quiet and shows its ring on keyboard traversal", async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      const worked = page.locator(".cv-worked").first();
      await worked.waitFor();

      await worked.click();
      const pointer = await worked.evaluate((node) => ({
        focusVisible: node.matches(":focus-visible"),
        outline: getComputedStyle(node).outlineStyle,
      }));
      expect({ pointerRing: pointer.focusVisible || pointer.outline !== "none" }).toEqual({ pointerRing: false });

      // Focus the next tab stop, then reverse-Tab onto Worked for a real keyboard traversal.
      await page.evaluate(() => {
        const worked = document.querySelector<HTMLElement>(".cv-worked");
        if (!worked) throw new Error("Worked for is missing");
        const focusable = [...document.querySelectorAll<HTMLElement>("button, a, [tabindex]")].filter(
          (node) => node !== worked && node.tabIndex >= 0 && node.getClientRects().length > 0,
        );
        const next = focusable.find((node) =>
          Boolean(worked.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING),
        );
        if (!next) throw new Error("no focusable after Worked for");
        next.dataset.focusAfterWorked = "true";
      });
      await page.locator("[data-focus-after-worked='true']").focus();
      await page.keyboard.press("Shift+Tab");
      const keyboard = await worked.evaluate((node) => ({
        active: document.activeElement === node,
        focusVisible: node.matches(":focus-visible"),
        outline: getComputedStyle(node).outlineStyle,
      }));
      expect({ keyboardRing: keyboard.active && keyboard.focusVisible && keyboard.outline !== "none" }).toEqual({
        keyboardRing: true,
      });
      await page.close();
    });
  });
});
