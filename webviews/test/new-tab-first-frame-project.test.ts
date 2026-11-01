// cmux-web-test-timeout: 300
// A New Tab page names its project and machine on its first frame, and keeps them (Leo 2026-10-19:
// "new tab still paints first frame as unexplored ... it's indecisive between 'defaults' and
// 'recently used'"). The page drew "Choose folder" until the host's handshake or the daemon's chat
// list answered, then flipped to the project the tab inherited or the one used last.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host (its handshake
// late, as a cold page's is) and a stand-in acpmux daemon (its chat list late). A script from the
// document's start records the location strip's visible text on every DOM change and every frame.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-first-frame-project.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserContext, type BrowserType } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-first-frame-project.test.ts", async () => {
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
      console.warn(`new-tab-first-frame-project: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab first frame project", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const ATLAS = `${HOME}/src/atlas`;
  const BILLING = `${HOME}/src/billing`;
  const now = Date.now();
  // atlas holds the chat used last on this Mac.
  const sessions = [
    { sessionId: "s-billing", cwd: BILLING, harness: "claude", status: "idle", turnCount: 1, updatedAt: now - 60_000 },
    { sessionId: "s-atlas", cwd: ATLAS, harness: "claude", status: "idle", turnCount: 1, updatedAt: now - 1_000 },
  ];
  /// How long the daemon takes to list its chats.
  let listDelay = 0;

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
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id === undefined) return;
          let result: unknown = null;
          if (message.method === "initialize")
            result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
          else if (message.method === "_acpmux/watch") {
            // fixed-wait: the chat list arriving late is the state under test, not a wait for one
            if (listDelay) await Bun.sleep(listDelay);
            result = { sessions };
          } else if (message.method === "_acpmux/sessions") result = { sessions: [] };
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

  type Host = { cwd?: string; handshakeDelay: number };
  /// Opens a New Tab page in `context` with the host's context injected as the document commits
  /// (AgentPaneNavigation), and returns every distinct location text it painted, in order.
  async function newTab(context: BrowserContext, { cwd, handshakeDelay }: Host, settle: string) {
    const page = await context.newPage();
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, cwd, home, handshakeDelay }) => {
        const newTab = { kind: "agent", hotkeys: {}, home, projects: [], host: "cosmic-gray", ...(cwd ? { cwd } : {}) };
        (window as unknown as Record<string, unknown>).__cmuxNewTabContext = newTab;
        // The host's answers still on their way; each comes `ms` late.
        const w = window as unknown as { __hostPending: number };
        w.__hostPending = 0;
        const later = (ms: number, value: unknown) => {
          w.__hostPending += 1;
          // fixed-wait: the stand-in host answers late on purpose; the label must hold through it
          return new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms)).then((answer) => {
            w.__hostPending -= 1;
            return answer;
          });
        };
        const answer = (method: string): unknown => {
          switch (method) {
            case "ready":
              return later(handshakeDelay, {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint,
                token: "t",
                newSession: true,
                newTab,
                // The host fills no start folder for the home folder (AgentPaneStartFolders).
                ...(cwd && cwd !== home ? { cwd } : {}),
                machineName: "cosmic-gray",
              });
            case "newTab.context":
              return later(0, { newTab });
            case "project.list":
              return later(handshakeDelay, { projects: [`${home}/src/atlas`, `${home}/src/billing`] });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        (window as unknown as { webkit: unknown }).webkit = {
          messageHandlers: { agentSession: { postMessage: (request: { method: string }) => answer(request.method) } },
        };
        // The strip's text as painted: hidden text (a reserved place) is no label.
        const painted: string[] = [];
        (window as unknown as Record<string, unknown>).__painted = painted;
        const read = () => {
          const strip = document.querySelector(".nt-location");
          if (!strip) return;
          // Each chip's visible text (a long name draws as a head and a tail), the chips apart.
          const chips = [...strip.querySelectorAll(".acpmux-location-picker")].map((chip) => {
            const walker = document.createTreeWalker(chip, NodeFilter.SHOW_TEXT);
            let label = "";
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              const parent = node.parentElement;
              if (parent && getComputedStyle(parent).visibility === "visible") label += node.textContent ?? "";
            }
            return label.trim();
          });
          const text = chips.filter(Boolean).join(" ").replace(/\s+/g, " ").trim();
          if (painted.at(-1) !== text) painted.push(text);
        };
        new MutationObserver(read).observe(document, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        window.cmuxAfterPaint(read);
      },
      { endpoint, cwd, home: HOME, handshakeDelay },
    );
    // The daemon's chat list reaching the page.
    const listed = new Promise<void>((resolve) =>
      page.on("websocket", (socket) =>
        socket.on("framereceived", (frame) => {
          if (String(frame.payload).includes('"sessions":[{')) resolve();
        }),
      ),
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".nt-location").getByText(settle).waitFor();
    // Past the handshake, the daemon's list and the projects list (the second one goes out before
    // the daemon is asked for its chats), and a painted frame after them.
    await listed;
    await page.waitForFunction(() => (window as unknown as { __hostPending: number }).__hostPending === 0);
    await page.evaluate(() => window.cmuxPaintFrame());
    const painted = await page.evaluate(() => (window as unknown as { __painted: string[] }).__painted);
    await page.close();
    console.info(`painted: ${JSON.stringify(painted)}`);
    // Empty text is the strip before React draws it, or a reserved place: never a wrong label.
    return painted.filter((text) => text !== "");
  }

  test.each(engines.map(([name]) => name))(
    "%s: a New Tab that inherits a project names it from its first frame",
    async (name) => {
      listDelay = 0;
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      const painted = await newTab(context, { cwd: BILLING, handshakeDelay: 700 }, "billing");
      await context.close();
      expect(painted.every((text) => !text.includes("Choose folder"))).toBe(true);
      expect(new Set(painted.map((text) => text.includes("billing")))).toEqual(new Set([true]));
      // The environment picker names this Mac "This Mac" (#28999), never its hostname.
      expect(painted.every((text) => text.includes("This Mac") && !text.includes("cosmic-gray"))).toBe(true);
      expect(new Set(painted).size).toBe(1);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a New Tab after another page heard the chats names the recent project from its first frame",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      // An earlier page in this run (the app's pages share one store) heard the daemon's chats.
      listDelay = 0;
      await newTab(context, { cwd: HOME, handshakeDelay: 0 }, "atlas");
      // This one's handshake and chat list come late.
      listDelay = 900;
      const painted = await newTab(context, { cwd: HOME, handshakeDelay: 700 }, "atlas");
      await context.close();
      expect(painted.every((text) => !text.includes("Choose folder"))).toBe(true);
      expect(painted.every((text) => text.includes("atlas"))).toBe(true);
      expect(new Set(painted).size).toBe(1);
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a cold New Tab with nothing heard yet paints no default before the recent project",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      listDelay = 700;
      const painted = await newTab(context, { cwd: HOME, handshakeDelay: 300 }, "atlas");
      await context.close();
      expect(painted.every((text) => !text.includes("Choose folder"))).toBe(true);
      // The machine shows at once; the folder's place stays empty until the chats answer.
      expect(painted.filter((text) => text.includes("atlas")).length).toBe(1);
      expect(painted.at(-1)).toContain("atlas");
    },
  );
});
