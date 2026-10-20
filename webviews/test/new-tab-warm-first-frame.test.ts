// cmux-web-test-timeout: 420
// A New Tab page draws its final Chats list and project on its first frame, however it opens (Leo
// 2026-10-19: "there's still a split second flicker upon opening up new workspaces wrt the semi
// dynamic content on the recent chats and the recent project... it sometimes doesnt load fast
// enough"; "likewise with opening up new tabs like it cant decide what default is vs what recently
// used is"). A page that just mounted listed no chats until its own daemon connection answered, so
// it painted an empty list and then filled it. Each local page now posts its newest chats
// (`newTab.warm`), the host keeps the last, and every opening's context carries it (`warm`).
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host that keeps the
// posted snapshot as AgentPaneNewTab.warmed does, and a stand-in acpmux daemon whose chat list comes
// late. A script from the document's start records what the Chats list and the location strip
// show on every DOM change and every frame; a warm open must paint one state only.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-warm-first-frame.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserContext, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-warm-first-frame.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-warm-first-frame: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab warm first frame", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const ATLAS = `${HOME}/src/atlas`;
  const BILLING = `${HOME}/src/billing`;
  // Hours old, so no age label turns over while a test runs.
  const now = Date.now();
  const hours = (count: number) => now - count * 3_600_000 - 600_000;
  const sessions = [
    {
      sessionId: "s-atlas",
      cwd: ATLAS,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: hours(1),
      title: "Fix the atlas build",
    },
    {
      sessionId: "s-billing",
      cwd: BILLING,
      harness: "codex",
      status: "idle",
      turnCount: 1,
      updatedAt: hours(3),
      title: "Invoice rounding",
    },
    {
      sessionId: "s-docs",
      cwd: ATLAS,
      harness: "claude",
      status: "idle",
      turnCount: 2,
      updatedAt: hours(5),
      title: "Write the API docs",
    },
  ];
  // The chat index's device chats the host pushes after the handshake (AgentPaneDeviceChat).
  const device = [{ key: "codex:d-old", harness: "codex", title: "Older device chat", updatedAt: hours(30) }];
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

  /// The host's side: the last `newTab.warm` a page posted (AgentPaneNewTab.warmed), as JSON text.
  let warmed: string | undefined;
  type Context = Record<string, unknown>;

  /// Loads a page with `context` injected as the document commits (AgentPaneNavigation) and
  /// records each distinct Chats list and location strip it paints.
  async function load(browserContext: BrowserContext, context: Context, handshakeDelay = 300): Promise<Page> {
    const page = await browserContext.newPage();
    await page.exposeFunction("__postWarm", (warm: unknown) => {
      warmed = JSON.stringify(warm);
    });
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, context, handshakeDelay, device }) => {
        const w = window as unknown as Record<string, unknown> & {
          __postWarm(warm: unknown): void;
          cmuxAcpmuxBridge?: { applyDeviceChats?(chats: unknown): void };
        };
        w.__cmuxNewTabContext = context;
        const later = (ms: number, value: unknown) =>
          new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms));
        const answer = (request: { method: string; params?: { warm?: unknown } }): unknown => {
          switch (request.method) {
            case "ready":
              // The host pushes the device chats as it accepts the handshake (AgentPaneBridge).
              setTimeout(() => w.cmuxAcpmuxBridge?.applyDeviceChats?.(device), handshakeDelay + 50);
              return later(handshakeDelay, {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint,
                token: "t",
                newSession: true,
                newTab: context,
                ...(typeof context.cwd === "string" ? { cwd: context.cwd } : {}),
                machineName: "cosmic-gray",
              });
            case "newTab.context":
              return later(0, { newTab: context });
            case "newTab.warm":
              w.__postWarm(request.params?.warm);
              return later(0, null);
            case "project.list":
              return later(handshakeDelay, {
                projects: [`${String(context.home)}/src/atlas`, `${String(context.home)}/src/billing`],
              });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        w.webkit = { messageHandlers: { agentSession: { postMessage: answer } } };
        const painted: string[] = [];
        w.__painted = painted;
        const read = () => {
          const screen = document.querySelector(".nt-screen");
          if (!screen) return;
          const chats = document.querySelector<HTMLElement>(".nt-chats");
          const cards = [...document.querySelectorAll(".nt-card")].map(
            (card) =>
              `${(card as HTMLElement).innerText.replace(/\s+/g, " ").trim()}|${card.querySelectorAll("svg").length}`,
          );
          const location = (document.querySelector<HTMLElement>(".nt-location")?.innerText ?? "").replace(/\s+/g, " ");
          const text = `${location.trim()} :: ${chats ? (cards.length ? cards.join(" / ") : "(empty)") : "(no list)"}`;
          if (painted.at(-1) !== text) painted.push(text);
        };
        new MutationObserver(read).observe(document, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        const frame = () => {
          read();
          requestAnimationFrame(frame);
        };
        requestAnimationFrame(frame);
      },
      { endpoint, context, handshakeDelay, device },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    return page;
  }

  /// What `page` painted from now until its handshake, chats and projects have all answered.
  async function settle(page: Page): Promise<string[]> {
    await page.locator(".nt-card", { hasText: "Fix the atlas build" }).waitFor({ timeout: 30_000 });
    await page.waitForTimeout(listDelay + 900);
    const painted = await page.evaluate(() => (window as unknown as { __painted: string[] }).__painted);
    return painted;
  }

  const base = { kind: "agent", hotkeys: {}, home: HOME, projects: [ATLAS, BILLING], host: "cosmic-gray" };
  /// Each way a New Tab opens, as NewTabPage.page() makes its context.
  const entries: [string, Context][] = [
    // Cmd-T from a chat in atlas: the tab's folder and location.
    ["Cmd-T", { ...base, cwd: ATLAS, location: ATLAS }],
    // The tab strip's + button: the same page, opened beside the selected tab.
    ["the + button", { ...base, cwd: ATLAS }],
    // A new workspace's first tab: no folder of its own, so it starts on the recent project.
    ["a new workspace", { ...base }],
    // A split: the workspace's tabs to move into the new pane.
    ["a split", { ...base, cwd: ATLAS, openTabs: [{ id: "t-zsh", kind: "terminal", title: "zsh" }] }],
  ];

  /// A page of this Mac that listed the chats posts them; the host keeps that as `warmed`.
  async function warmUp(browserContext: BrowserContext) {
    warmed = undefined;
    listDelay = 0;
    const source = await load(browserContext, { ...base }, 0);
    await source.locator(".nt-card", { hasText: "Fix the atlas build" }).waitFor({ timeout: 30_000 });
    // The post after the host's device chats push carries them too.
    for (let tries = 0; tries < 50 && !(warmed as string | undefined)?.includes("d-old"); tries += 1)
      await source.waitForTimeout(100);
    await source.close();
  }

  const counts: Record<string, number> = {};

  for (const [entry, context] of entries) {
    test.each(engines.map(([name]) => name))(
      `%s: ${entry} paints its final chats and project on its first frame`,
      async (name) => {
        const browserContext = await browsers.get(name)!.newContext({ viewport: { width: 1000, height: 900 } });
        await warmUp(browserContext);
        // This page's own chat list comes late, as a fresh page's does.
        listDelay = 1_200;
        const page = await load(browserContext, { ...context, warm: warmed });
        const painted = await settle(page);
        await page.close();
        await browserContext.close();
        console.info(`${name} ${entry} warm: ${painted.length} state(s) ${JSON.stringify(painted)}`);
        counts[`${name} ${entry} warm`] = painted.length - 1;
        expect(warmed).toBeDefined();
        // One state from the first frame on: the final list and the recent project, never empty first.
        expect(painted).toHaveLength(1);
        expect(painted[0]).toContain("Fix the atlas build");
        expect(painted[0]).toContain("Older device chat");
        expect(painted[0]).toStartWith("atlas cosmic-gray ::");
      },
    );
  }

  test.each(engines.map(([name]) => name))(
    "%s: an adopted spare paints its final chats from the adoption on",
    async (name) => {
      const browserContext = await browsers.get(name)!.newContext({ viewport: { width: 1000, height: 900 } });
      await warmUp(browserContext);
      // A spare made before any page listed chats, whose own list has not come yet.
      listDelay = 2_500;
      const spare = await load(browserContext, { ...base });
      await spare.locator(".nt-field").waitFor();
      await spare.waitForTimeout(400);
      // Cmd-T adopts it: the host dispatches the opening's context (AgentPaneView.adoptNewTab).
      await spare.evaluate(
        (detail) => {
          (window as unknown as { __painted: string[] }).__painted.length = 0;
          window.dispatchEvent(new CustomEvent("acpmux-newtab-adopt", { detail }));
        },
        { ...base, cwd: ATLAS, warm: warmed },
      );
      listDelay = 0;
      const painted = await settle(spare);
      await spare.close();
      await browserContext.close();
      console.info(`${name} adopted spare warm: ${painted.length} state(s) ${JSON.stringify(painted)}`);
      counts[`${name} adopted spare warm`] = painted.length - 1;
      expect(warmed).toBeDefined();
      expect(painted).toHaveLength(1);
      expect(painted[0]).toContain("Fix the atlas build");
      // The adopting tab's project, not the spare's "Choose folder".
      expect(painted[0]).toStartWith("atlas cosmic-gray ::");
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a cold launch with nothing listed yet fills the list once",
    async (name) => {
      const browserContext = await browsers.get(name)!.newContext({ viewport: { width: 1000, height: 900 } });
      listDelay = 1_200;
      const page = await load(browserContext, { ...base });
      const painted = await settle(page);
      await page.close();
      await browserContext.close();
      console.info(`${name} cold: ${painted.length} state(s) ${JSON.stringify(painted)}`);
      counts[`${name} cold`] = painted.length - 1;
      // The empty state once, then the final list.
      expect(painted.length).toBeLessThanOrEqual(2);
      expect(painted.at(-1)).toContain("Fix the atlas build");
    },
  );

  afterAll(() => console.info(`changed frames: ${JSON.stringify(counts)}`));
});
