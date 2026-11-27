// cmux-web-test-timeout: 300
// A prewarmed spare page asks the host for `project.list` before Cmd-T wires it, and the host refuses
// it then. An adopt whose screen is the one the spare shows does not remount the page, so it never
// asked again: its folder menu listed only its chats' folders, by their folder's name and with no
// repository (a clone of GitHub's cmux-workspace in ~/cmux read "cmux"), and the folders only the
// project list holds were gone. The page asks again on the adopt, and keeps the answer for the next
// page's first frame (newtab/projectListStore.ts).
//
// The real agent pane (the dev entry) in Chromium and WebKit, a stand-in host and a stand-in acpmux
// daemon.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-adopted-project-list.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-adopted-project-list.test.ts", async () => {
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
      console.warn(`new-tab-adopted-project-list: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab adopted project list", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const CMUX = `${HOME}/cmux`;
  const now = Date.now();
  const sessions = [
    { sessionId: "s-cmux", cwd: CMUX, harness: "claude", status: "idle", turnCount: 1, updatedAt: now - 1_000 },
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

  /// A page with a stand-in host. `listing`: how `project.list` answers, by the ask's number
  /// (`refuse` as an unwired spare's host does, `answer` with the repository, `never`).
  async function openPage(page: Page, listing: ("refuse" | "answer" | "never")[]) {
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, home, cmux, listing }) => {
        const newTab = { kind: "agent", hotkeys: {}, home, cwd: cmux, projects: [] };
        const w = window as unknown as Record<string, unknown> & { __asks?: number };
        w.__cmuxNewTabContext = newTab;
        w.__asks = 0;
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
                },
              });
            case "newTab.context":
              return Promise.resolve({ ok: true, value: { newTab } });
            case "project.list": {
              const how = listing[w.__asks!] ?? listing[listing.length - 1];
              w.__asks! += 1;
              if (how === "never") return new Promise(() => undefined);
              if (how === "refuse")
                return Promise.resolve({ ok: false, error: { code: "unsupported", message: "project.list" } });
              return Promise.resolve({
                ok: true,
                value: {
                  projects: [cmux, `${home}/site`],
                  repos: { [cmux]: { root: cmux, top: cmux, name: "cmux-workspace", github: "you/cmux-workspace" } },
                },
              });
            }
            default:
              return Promise.resolve({ ok: true, value: null });
          }
        };
        (window as unknown as { webkit: unknown }).webkit = {
          messageHandlers: { agentSession: { postMessage: (request: { method: string }) => answer(request) } },
        };
      },
      { endpoint, home: HOME, cmux: CMUX, listing },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
  }

  test.each(engines.map(([name]) => name))(
    "%s: a spare adopted for the screen it shows asks for the project list again and names the repository",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      const page = await context.newPage();
      await openPage(page, ["refuse", "answer"]);
      await page.waitForFunction(() => (window as unknown as { __asks?: number }).__asks === 1);
      await page.locator(".nt-location").getByText("cmux").first().waitFor();
      // Cmd-T adopts the spare with the context it already shows: no remount.
      await page.evaluate(() =>
        window.dispatchEvent(
          new CustomEvent("acpmux-newtab-adopt", {
            detail: (window as unknown as { __cmuxNewTabContext: unknown }).__cmuxNewTabContext,
          }),
        ),
      );
      await page.locator(".nt-location").getByText("cmux-workspace").waitFor({ timeout: 10_000 });
      const asks = await page.evaluate(() => (window as unknown as { __asks?: number }).__asks);
      // The next page of this Mac names it from its first frame, while its own list is out.
      const next = await context.newPage();
      await openPage(next, ["never"]);
      await next.locator(".nt-location").getByText("cmux-workspace").waitFor({ timeout: 10_000 });
      await context.close();
      expect(asks).toBe(2);
    },
  );

  // The host names only its newest 40 folders (AgentPaneOmnibar.maximumEntries), and the page dropped a default
  // folder the list did not name: a default older than the newest 40 read No folder. The page asks for it by path.
  test.each(engines.map(([name]) => name))(
    "%s: a default folder older than the host's newest 40 stays the New Tab's folder",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      const OLD = `${HOME}/src/old-repo`;
      await page.addInitScript(
        ({ endpoint, home, old }) => {
          // No folder of its own (the home folder): the page starts on the default folder.
          const newTab = { kind: "agent", hotkeys: {}, home, cwd: home, projects: [], startedProject: old };
          const w = window as unknown as Record<string, unknown> & { __queried?: string };
          w.__cmuxNewTabContext = newTab;
          const newest = Array.from({ length: 40 }, (_, index) => `${home}/src/recent-${index}`);
          const answer = (request: { method: string; params?: { query?: string } }): unknown => {
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
                  },
                });
              case "newTab.context":
                return Promise.resolve({ ok: true, value: { newTab } });
              case "project.list":
                if (request.params?.query) {
                  w.__queried = request.params.query;
                  return Promise.resolve({ ok: true, value: { projects: request.params.query === old ? [old] : [] } });
                }
                return Promise.resolve({ ok: true, value: { projects: newest } });
              default:
                return Promise.resolve({ ok: true, value: null });
            }
          };
          (window as unknown as { webkit: unknown }).webkit = {
            messageHandlers: {
              agentSession: {
                postMessage: (request: { method: string; params?: { query?: string } }) => answer(request),
              },
            },
          };
        },
        { endpoint, home: HOME, old: OLD },
      );
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/`);
      await page.waitForFunction((old) => (window as unknown as { __queried?: string }).__queried === old, OLD);
      await page.evaluate(() => window.cmuxPaintFrame());
      await page.locator(".nt-location").getByText("old-repo").waitFor({ timeout: 10_000 });
      const strip = (await page.locator(".nt-location").textContent()) ?? "";
      await context.close();
      expect(strip).toContain("old-repo");
      expect(strip).not.toContain("No folder");
    },
  );
});
