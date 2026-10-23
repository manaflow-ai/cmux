// cmux-web-test-timeout: 420
// l10n-allow-file: test fixtures (mode and model names as the harnesses name them).
// The New Tab composer's row holds still from its first frame (Leo 2026-10-23, cx-ncc.113.116:
// "why is this thing still not showing on the very beginning? ... the composer is just, it's messy
// when you get it. It keeps switching around"). The permission control is in the row on the first
// frame, in both looks, naming the harness's highest permission level until acpmux answers
// ("if you don't know what to switch to, typically just switch to the highest permission level"),
// and no control in the row moves or resizes while the harness list, its models and acpmux's start
// mode arrive.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host and a stand-in
// acpmux daemon that answers late. The page is a later New Tab of a launch (the harness catalog
// kept from an earlier one), with no start mode kept: the first New Tab on a harness, or Codex's
// after acpmux restarted, which names no mode until a Codex chat has run. A script from the
// document's start records the boxes of the row's controls on every DOM change and every painted
// frame; every record must be the first one.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-row-still.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-row-still.test.ts", async () => {
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
      console.warn(`new-tab-row-still: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab row still", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  // What acpmux lists on a Mac with Claude Code and Codex, cut down.
  const claudeModels = [
    { id: "default", name: "Default (Claude Code's choice)" },
    { id: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5", family: "Opus" },
  ];
  const codexModels = [{ id: "gpt-5.5", name: "GPT-5.5" }];
  const catalog = [
    { id: "claude", name: "Claude Code", family: "claude", models: claudeModels, start: { effort: "high" } },
    { id: "codex", name: "Codex", family: "codex", models: codexModels },
  ];
  // The answers come late, one after another: the harness list, then the models, then the start mode.
  const DELAYS: Record<string, number> = {
    "_acpmux/harnesses": 500,
    "_acpmux/models": 800,
    "_acpmux/start_mode": 1_100,
    "_acpmux/route/list": 1_100,
  };
  /// The harness each page asks about, by daemon connection: whose start mode acpmux knows.
  const answered = new Map<string, () => void>();

  function answer(method: string, params: Record<string, unknown>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [] };
      case "_acpmux/harnesses":
        return {
          harnesses: {
            claude: { kind: "claude-stdio", family: "claude", start: { effort: "high" } },
            codex: { kind: "acp", family: "codex" },
          },
          families: { claude: ["claude"], codex: ["codex"] },
          defaultHarness: "claude",
        };
      case "_acpmux/models":
        return {
          harnesses: [
            { harness: "claude", kind: "claude-stdio", isDefault: true, models: claudeModels },
            { harness: "codex", kind: "acp", models: codexModels },
          ],
        };
      // Claude Code's modes are acpmux's own (claude_stdio::MODES): it names full access. Codex's
      // are not known until a Codex chat runs: full access, and no mode named (hub/start_mode.rs).
      case "_acpmux/start_mode":
        return params.harness === "claude"
          ? {
              harness: "claude",
              modeId: "bypassPermissions",
              name: "Bypass permissions",
              level: "fullAccess",
              source: "default",
            }
          : { harness: params.harness, modeId: null, name: null, level: "fullAccess", source: "default" };
      case "_acpmux/route/list":
        return { routes: [{ id: "max", name: "Max", serves: true }], active: null };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        const page = new URL(request.url).searchParams.get("page") ?? "";
        return server.upgrade(request, { data: { page } }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id === undefined) return;
          const delay = DELAYS[message.method];
          // fixed-wait: acpmux answering late is the state under test, not a wait for one
          if (delay) await Bun.sleep(delay);
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
          );
          if (message.method === "_acpmux/start_mode") answered.get((ws.data as { page: string }).page)?.();
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
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

  let pages = 0;
  /// A New Tab page (no folder of its own) on `harness` (the app's last pick) in `look`, recording
  /// the boxes of the row's controls; resolves with the page once acpmux has answered its start mode.
  async function load(name: string, look: string, harness: string): Promise<{ page: Page; ready: Promise<void> }> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1000, height: 760 } });
    await installPaintedFrames(page);
    const id = `p${(pages += 1)}`;
    const ready = new Promise<void>((resolve) => answered.set(id, resolve));
    const endpoint = `ws://127.0.0.1:${daemon!.port}/?page=${id}`;
    const model = harness === "claude" ? "claude-opus-5-5" : "gpt-5.5";
    const context = {
      kind: "agent",
      hotkeys: {},
      home: HOME,
      projects: [],
      host: "cosmic-gray",
      template: "minimal",
      lastPicks: { global: { harness, model }, folders: [] },
    };
    await page.addInitScript(
      ({ endpoint, context, look, catalog }) => {
        const w = window as unknown as Record<string, unknown>;
        w.__cmuxNewTabContext = context;
        // An earlier page of this launch kept the harness catalog and the look; no start mode.
        localStorage.setItem("cmux.composer.look", look);
        localStorage.setItem("cmux.acpmux.harnessCatalog.v1", JSON.stringify({ catalog, at: Date.now() - 60_000 }));
        const later = (ms: number, value: unknown) =>
          // fixed-wait: the stand-in host answers late on purpose; the row must hold through it
          new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms));
        const answer = (request: { method: string }): unknown => {
          switch (request.method) {
            case "ready":
              return later(150, {
                protocolVersion: 1,
                transport: "acpmux-websocket",
                endpoint,
                token: "t",
                newSession: true,
                newTab: context,
                machineName: "cosmic-gray",
              });
            case "newTab.context":
              return later(0, { newTab: context });
            case "project.list":
              return later(300, { projects: [] });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        w.webkit = { messageHandlers: { agentSession: { postMessage: answer } } };
        const records: string[] = [];
        w.__records = records;
        const read = () => {
          const composer = document.querySelector(".nt-composer");
          if (!composer?.querySelector(".nt-field")) return;
          // The row's controls: the folder and machine, the access, model and other chips, the mic
          // and Send. Each is named by its kind, so one that appears, goes or swaps shows.
          const controls = [
            ...composer.querySelectorAll(".acpmux-location-picker, .acpmux-chips > *, .acpmux-composer-actions button"),
          ].map((node) => {
            const box = node.getBoundingClientRect();
            const kind = node.classList.contains("acpmux-mode")
              ? "mode"
              : node.classList.contains("acpmux-model")
                ? "model"
                : (node.getAttribute("data-kind") ?? node.classList[0]);
            return `${kind} ${box.left},${box.top} ${box.width}x${box.height}`;
          });
          const record = controls.join(" | ");
          if (records.at(-1) !== record) records.push(record);
        };
        new MutationObserver(read).observe(document, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        window.cmuxAfterPaint(read);
      },
      { endpoint, context, look, catalog },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    return { page, ready };
  }

  /// Resolves once the page holds still: 10 painted frames with no DOM change (120 at most).
  const settled = (page: Page) =>
    page.evaluate(async () => {
      let changed = true;
      const observer = new MutationObserver(() => {
        changed = true;
      });
      observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
      for (let held = 0, frames = 0; held < 10 && frames < 120; frames += 1) {
        await window.cmuxPaintFrame();
        held = changed ? 0 : held + 1;
        changed = false;
      }
      observer.disconnect();
    });

  // The access chip's name: the label in the Claude look, the shield's tooltip in Codex's.
  const modeName = (page: Page) =>
    page.locator(".nt-composer .acpmux-mode").evaluate((node) => node.textContent?.trim() ?? "");

  const cases: [look: string, harness: string, highest: string][] = [
    ["claude", "claude", "Bypass permissions"],
    ["codex", "claude", "Bypass permissions"],
    ["claude", "codex", "Full access"],
    ["codex", "codex", "Full access"],
  ];
  for (const [look, harness, highest] of cases) {
    test.each(engines.map(([name]) => name))(
      `%s: the ${look} look's row on ${harness} holds still, its mode control there from the first frame`,
      async (name) => {
        const { page, ready } = await load(name, look, harness);
        await page.locator(".nt-field").waitFor({ timeout: 30_000 });
        const first = await page.evaluate(() => (window as unknown as { __records: string[] }).__records[0] ?? "");
        // The mode control is in the row on the first frame, naming the harness's highest level.
        expect(first).toContain("mode ");
        expect(await modeName(page)).toBe(highest);
        // The harness list, its models and acpmux's start mode arrive.
        await ready;
        await settled(page);
        expect(await modeName(page)).toBe(highest);
        const records = await page.evaluate(() => (window as unknown as { __records: string[] }).__records);
        await page.close();
        console.info(`${name} ${look} ${harness}: ${records.length} record(s)\n  ${records.join("\n  ")}`);
        // One record from the first frame on: no control in the row moved, resized, came or went.
        expect(records).toHaveLength(1);
      },
    );
  }
});
