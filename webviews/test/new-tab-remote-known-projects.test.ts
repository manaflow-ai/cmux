// cmux-web-test-timeout: 300
// Codex review of #24274: a pane's page keeps the daemon's project list it loaded for an earlier
// New Tab (`project.list`, App's directProjects). When the pane's next New Tab is another machine's
// (no home, no folder of its own) and that machine's list has not answered (or fails), the stale
// list of this Mac's folders must not decide its project: the page starts on the newest chat folder
// it lists, never on this Mac's folder and never on none.
//
// The real agent pane (the dev entry) in Chromium and WebKit, a stand-in host and a stand-in acpmux
// daemon. The first page is this Mac's; the host then hands the same page another machine's
// context (`acpmux-newtab-adopt`, as Cmd-T adopting a spare does) and never answers its second
// `project.list`.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-remote-known-projects.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-remote-known-projects.test.ts", async () => {
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
      console.warn(`new-tab-remote-known-projects: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab remote known projects", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const ATLAS = `${HOME}/src/atlas`;
  const REMOTE = "/home/dev/api";
  const now = Date.now();
  // The machine's chats: its newest is in a folder this Mac's project list does not have.
  const sessions = [
    { sessionId: "s-atlas", cwd: ATLAS, harness: "claude", status: "idle", turnCount: 1, updatedAt: now - 60_000 },
    { sessionId: "s-api", cwd: REMOTE, harness: "claude", status: "idle", turnCount: 1, updatedAt: now - 1_000 },
  ];

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
          else if (message.method === "_acpmux/watch") result = { sessions };
          else if (message.method === "_acpmux/sessions") result = { sessions: [] };
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

  test.each(engines.map(([name]) => name))(
    "%s: another machine's New Tab after this Mac's starts on its newest chat folder while its project list is pending",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.addInitScript(
        ({ endpoint, home, atlas }) => {
          const newTab = { kind: "agent", hotkeys: {}, home, cwd: home, projects: [], host: "cosmic-gray" };
          (window as unknown as Record<string, unknown>).__cmuxNewTabContext = newTab;
          const answer = (request: { method: string }): unknown => {
            switch (request.method) {
              case "ready":
                return Promise.resolve({
                  ok: true,
                  value: {
                    protocolVersion: 1,
                    transport: "acpmux-websocket",
                    endpoint,
                    token: "t",
                    newSession: true,
                    newTab,
                    machineName: "cosmic-gray",
                  },
                });
              case "newTab.context":
                return Promise.resolve({ ok: true, value: { newTab } });
              case "project.list":
                // This Mac's list answers; the other machine's (after the handoff) never does.
                return (window as unknown as { __remote?: boolean }).__remote
                  ? new Promise(() => undefined)
                  : Promise.resolve({ ok: true, value: { projects: [atlas, `${home}/src/billing`] } });
              default:
                return Promise.resolve({ ok: true, value: null });
            }
          };
          (window as unknown as { webkit: unknown }).webkit = {
            messageHandlers: {
              agentSession: { postMessage: (request: { method: string }) => answer(request) },
            },
          };
        },
        { endpoint, home: HOME, atlas: ATLAS },
      );
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/`);
      // This Mac's page: its list has the older folder, so it starts there.
      await page.locator(".nt-location").getByText("atlas").waitFor();
      // The pane's next New Tab is another machine's: no home, no folder of its own.
      await page.evaluate(() => {
        (window as unknown as { __remote?: boolean }).__remote = true;
        window.dispatchEvent(
          new CustomEvent("acpmux-newtab-adopt", {
            detail: { kind: "agent", hotkeys: {}, projects: [], host: "devbox" },
          }),
        );
      });
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.locator(".nt-location").getByText("api").waitFor({ timeout: 10_000 });
      const strip = (await page.locator(".nt-location").textContent()) ?? "";
      await context.close();
      expect(strip).toContain("api");
      expect(strip).not.toContain("atlas");
    },
  );

  // Codex review of #24274: the store answered `project.list` with no project (every entry removed
  // or missing). The page must not fall back to "not loaded" and start in a chat's folder.
  test.each(engines.map(([name]) => name))(
    "%s: a New Tab whose project list answered empty starts in no chat folder",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.addInitScript(
        ({ endpoint, home }) => {
          const newTab = { kind: "agent", hotkeys: {}, home, cwd: home, projects: [], host: "cosmic-gray" };
          (window as unknown as Record<string, unknown>).__cmuxNewTabContext = newTab;
          const w = window as unknown as { __listed?: boolean };
          const answer = (request: { method: string }): unknown => {
            switch (request.method) {
              case "ready":
                return Promise.resolve({
                  ok: true,
                  value: {
                    protocolVersion: 1,
                    transport: "acpmux-websocket",
                    endpoint,
                    token: "t",
                    newSession: true,
                    newTab,
                    machineName: "cosmic-gray",
                  },
                });
              case "newTab.context":
                return Promise.resolve({ ok: true, value: { newTab } });
              case "project.list":
                w.__listed = true;
                return Promise.resolve({ ok: true, value: { projects: [] } });
              default:
                return Promise.resolve({ ok: true, value: null });
            }
          };
          (window as unknown as { webkit: unknown }).webkit = {
            messageHandlers: {
              agentSession: { postMessage: (request: { method: string }) => answer(request) },
            },
          };
        },
        { endpoint, home: HOME },
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
      await listed;
      await page.waitForFunction(() => (window as unknown as { __listed?: boolean }).__listed === true);
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.evaluate(() => window.cmuxPaintFrame());
      const strip = (await page.locator(".nt-location").textContent()) ?? "";
      await context.close();
      // The environment picker names this Mac "This Mac" (#28999).
      expect(strip).toContain("This Mac");
      expect(strip).not.toContain("atlas");
      expect(strip).not.toContain("api");
    },
  );
});
