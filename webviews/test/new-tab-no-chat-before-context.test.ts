// cmux-web-test-timeout: 300
// A page draws no chat screen before it knows whether it is a New Tab page (Lucas 2026-10-24: Cmd-T
// spam and fast closes flashed the chat screen, its tools at the top right and its composer at the
// bottom, in New Tab tabs). The host hands a New Tab page its context as the document commits only
// in WebKit (AgentPaneNavigation); a Chromium page has none on its first render and asks
// `newTab.context`. Until that answer, the page drew the chat screen, and Chromium shows the page in
// a window of its own that the host's alpha cannot keep clear until it paints.
//
// The real agent pane (the dev entry) in Chromium and WebKit with no injected context, a stand-in
// host answering `newTab.context` late (and the handshake later), and a stand-in acpmux daemon. A
// script from the document's start records, on every DOM change and every painted frame, which
// screen shows and whether `newTab.context` had answered.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-no-chat-before-context.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-no-chat-before-context.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-no-chat-before-context: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("no chat before the new tab context", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
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
          if (message.id === undefined) return;
          let result: unknown = null;
          if (message.method === "initialize")
            result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
          else if (message.method === "_acpmux/watch" || message.method === "_acpmux/sessions")
            result = { sessions: [] };
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Shown = { screen: "none" | "chat" | "newTab" | "both"; answered: boolean };
  /// Opens the pane with no injected context. `newTab.context` answers after `contextDelay` (naming a
  /// New Tab page when `isNewTab`), the handshake after `handshakeDelay`. Returns each distinct
  /// screen it showed, with whether `newTab.context` had answered by then.
  async function open(name: string, isNewTab: boolean, settle: string): Promise<Shown[]> {
    const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, home, isNewTab }) => {
        const newTab = { kind: "agent", hotkeys: {}, home, projects: [], host: "cosmic-gray" };
        const w = window as unknown as { __answered: boolean; __shown: Shown[] };
        w.__answered = false;
        // fixed-wait: the stand-in host answers late on purpose; the page must draw no chat meanwhile
        const later = (ms: number, value: unknown, after?: () => void) =>
          new Promise((resolve) => setTimeout(() => (after?.(), resolve({ ok: true, value })), ms));
        const answer = (method: string): unknown => {
          switch (method) {
            case "newTab.context":
              return later(300, isNewTab ? { newTab } : {}, () => (w.__answered = true));
            case "ready":
              return later(800, {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint,
                token: "t",
                newSession: true,
                ...(isNewTab ? { newTab } : {}),
                machineName: "cosmic-gray",
              });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        (window as unknown as { webkit: unknown }).webkit = {
          messageHandlers: { agentSession: { postMessage: (request: { method: string }) => answer(request.method) } },
        };
        type Shown = { screen: "none" | "chat" | "newTab" | "both"; answered: boolean };
        const shown: Shown[] = [];
        w.__shown = shown;
        const read = () => {
          const chat = document.querySelector(".acpmux-dock") !== null;
          const tab = document.querySelector(".nt-field") !== null;
          const screen = chat && tab ? "both" : chat ? "chat" : tab ? "newTab" : "none";
          const last = shown.at(-1);
          if (last?.screen !== screen || last.answered !== w.__answered) shown.push({ screen, answered: w.__answered });
        };
        new MutationObserver(read).observe(document, { subtree: true, childList: true, attributes: true });
        window.cmuxAfterPaint(read);
      },
      { endpoint, home: HOME, isNewTab },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(settle).first().waitFor();
    await page.evaluate(() => window.cmuxPaintFrame());
    const shown = await page.evaluate(() => (window as unknown as { __shown: Shown[] }).__shown);
    await context.close();
    console.info(`${name} ${isNewTab ? "new tab" : "chat"}: ${JSON.stringify(shown)}`);
    return shown;
  }

  test.each(engines.map(([name]) => name))(
    "%s: a New Tab page with no injected context never draws the chat screen",
    async (name) => {
      const shown = await open(name, true, ".nt-field");
      expect(shown.filter((entry) => entry.screen === "chat" || entry.screen === "both")).toEqual([]);
      expect(shown.at(-1)?.screen).toBe("newTab");
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a chat page draws its chat screen only once the host said it is no New Tab page",
    async (name) => {
      const shown = await open(name, false, ".acpmux-dock");
      expect(shown.filter((entry) => entry.screen !== "none" && !entry.answered)).toEqual([]);
      expect(shown.at(-1)?.screen).toBe("chat");
    },
  );
});
