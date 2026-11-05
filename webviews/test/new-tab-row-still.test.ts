// l10n-allow-file: test fixtures (mode and model names as the harnesses name them).
// The New Tab composer's row holds still from its first frame (Leo 2026-10-23, cx-ncc.113.116:
// "why is this thing still not showing on the very beginning? ... the composer is just, it's messy
// when you get it. It keeps switching around"). The permission control is in the row on the first
// frame, in both looks, naming the harness's highest permission level until acpmux answers
// ("if you don't know what to switch to, typically just switch to the highest permission level"),
// and no control in the row moves or resizes while the harness list, its models and acpmux's start
// mode arrive. A saved choice that is not the highest level (acpmux's late answer names it) replaces
// the highest level in the control's own slot, and nothing else in the row moves.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host and a stand-in
// acpmux daemon that answers late. The page is a later New Tab of a launch (the harness catalog
// kept from an earlier one), with no start mode kept: the first New Tab on a harness, or Codex's
// after acpmux restarted, which names no mode until a Codex chat has run. A script from the
// document's start records the boxes of the row's controls on every DOM change and every painted
// frame; every record must be the first one.
//
// The first New Tab page of a launch has no kept catalog (the page's store ends with the launch, and
// each engine keeps its own): its row draws from the app's copy of the last pick (`lastPicks`) and the
// bundled model catalog, and holds still all the same (Lucas 2026-10-24: the harness at the left and
// the effort at the right popped in a moment after the page showed).
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
    {
      id: "claude",
      name: "Claude Code",
      family: "claude",
      models: claudeModels,
      start: { effort: "high" },
    },
    { id: "codex", name: "Codex", family: "codex", models: codexModels },
  ];
  // The answers come late, one after another: the harness list, then the models, then the start mode.
  const DELAYS: Record<string, number> = {
    "_acpmux/harnesses": 500,
    "_acpmux/models": 800,
    "_acpmux/start_mode": 1_100,
    "_acpmux/route/list": 1_100,
  };
  /// Each page's start-mode answer having been sent, by daemon connection.
  const answered = new Map<string, () => void>();
  /// A saved choice acpmux answers with (the person's setting or pick), by harness.
  const SAVED: Record<string, { modeId: string; name: string; level: string }> = {
    claude: { modeId: "default", name: "Manual", level: "standard" },
    codex: { modeId: "agent", name: "Ask for approval", level: "standard" },
  };

  /// `start`: the effort acpmux starts Claude Code on. `codexStart`: Codex's, none when empty (acpmux
  /// names one from its curated catalog's default for the model, hub/start_defaults.rs).
  function answer(
    method: string,
    params: Record<string, unknown>,
    saved: boolean,
    start: string,
    codexStart: string,
  ): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [] };
      case "_acpmux/harnesses":
        return {
          harnesses: {
            claude: { kind: "claude-stdio", family: "claude", start: { effort: start } },
            codex: {
              kind: "acp",
              family: "codex",
              ...(codexStart ? { start: { effort: codexStart } } : {}),
            },
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
        if (saved) {
          const choice = SAVED[String(params.harness)]!;
          return { harness: params.harness, ...choice, source: "settings" };
        }
        return params.harness === "claude"
          ? {
              harness: "claude",
              modeId: "bypassPermissions",
              name: "Bypass permissions",
              level: "fullAccess",
              source: "default",
            }
          : {
              harness: params.harness,
              modeId: null,
              name: null,
              level: "fullAccess",
              source: "default",
            };
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
        const query = new URL(request.url).searchParams;
        const data = {
          page: query.get("page") ?? "",
          saved: query.get("saved") === "1",
          start: query.get("start") ?? "high",
          codexStart: query.get("codexStart") ?? "",
        };
        return server.upgrade(request, { data }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          if (message.id === undefined) return;
          const delay = DELAYS[message.method];
          // fixed-wait: acpmux answering late is the state under test, not a wait for one
          if (delay) await Bun.sleep(delay);
          const data = ws.data as {
            page: string;
            saved: boolean;
            start: string;
            codexStart: string;
          };
          const result = answer(message.method, message.params ?? {}, data.saved, data.start, data.codexStart);
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          if (message.method === "_acpmux/start_mode") answered.get(data.page)?.();
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
  /// the boxes and text of the row's controls; resolves with the page once acpmux has answered its
  /// start mode (`saved`: with the person's saved choice, SAVED). `kept`: an earlier page of the launch
  /// kept the harness catalog; without it the page is the launch's first. `start` and `codexStart`:
  /// the efforts acpmux starts Claude Code and Codex on (`answer`).
  async function load(
    name: string,
    look: string,
    harness: string,
    saved = false,
    { kept = true, start = "high", codexStart = "" }: { kept?: boolean; start?: string; codexStart?: string } = {},
  ): Promise<{ page: Page; ready: Promise<void> }> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1000, height: 760 } });
    await installPaintedFrames(page);
    const id = `p${(pages += 1)}`;
    const ready = new Promise<void>((resolve) => answered.set(id, resolve));
    const endpoint = `ws://127.0.0.1:${daemon!.port}/?page=${id}${saved ? "&saved=1" : ""}&start=${start}&codexStart=${codexStart}`;
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
      ({ endpoint, context, look, catalog, kept }) => {
        const w = window as unknown as Record<string, unknown>;
        w.__cmuxNewTabContext = context;
        // An earlier page of this launch kept the harness catalog and the look; no start mode.
        localStorage.setItem("cmux.composer.look", look);
        if (kept)
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
        w.__authNotes = 0;
        const read = () => {
          const composer = document.querySelector(".nt-composer");
          if (!composer?.querySelector(".nt-field")) return;
          // Even an older daemon settles the initial auth preflight asynchronously. Never
          // insert a transient checking note while that result is pending.
          if (composer.querySelector(".acpmux-composer-remote-note")) w.__authNotes = Number(w.__authNotes) + 1;
          // The row's controls: the folder and machine, the access, model and other chips, the mic
          // and Send. Each is named by its kind and its text, so one that appears, goes, swaps or
          // renames shows.
          const controls = [
            ...composer.querySelectorAll(".acpmux-location-picker, .acpmux-chips > *, .acpmux-composer-actions button"),
          ].map((node) => {
            const box = node.getBoundingClientRect();
            const kind = node.classList.contains("acpmux-mode")
              ? "mode"
              : node.classList.contains("acpmux-model")
                ? "model"
                : (node.getAttribute("data-kind") ?? node.classList[0]);
            return `${kind} ${box.left},${box.top} ${box.width}x${box.height} ${JSON.stringify(node.textContent?.trim() ?? "")}`;
          });
          const record = controls.join(" | ");
          if (records.at(-1) !== record) records.push(record);
        };
        const observer = new MutationObserver(read);
        observer.observe(document, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        const stopPaint = window.cmuxAfterPaint(read);
        // The test stops both in its `finally` (close), so a failed assertion leaves no frame loop.
        w.__stopRecording = () => {
          observer.disconnect();
          stopPaint();
        };
      },
      { endpoint, context, look, catalog, kept },
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
      observer.observe(document, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
      });
      for (let held = 0, frames = 0; held < 10 && frames < 120; frames += 1) {
        await window.cmuxPaintFrame();
        held = changed ? 0 : held + 1;
        changed = false;
      }
      observer.disconnect();
    });

  /// Stops the page's recording (its observer and frame loop), then closes it.
  const close = async (page: Page) => {
    await page
      .evaluate(() => (window as unknown as { __stopRecording?: () => void }).__stopRecording?.())
      .catch(() => undefined);
    await page.close();
  };
  const records = (page: Page) => page.evaluate(() => (window as unknown as { __records: string[] }).__records);

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
        try {
          await page.locator(".nt-field").waitFor({ timeout: 30_000 });
          const first = (await records(page))[0] ?? "";
          // The mode control is in the row on the first frame, naming the harness's highest level.
          expect(first).toContain("mode ");
          expect(await modeName(page)).toBe(highest);
          // The harness list, its models and acpmux's start mode arrive.
          await ready;
          await settled(page);
          expect(await page.evaluate(() => (window as unknown as { __authNotes: number }).__authNotes)).toBe(0);
          expect(await modeName(page)).toBe(highest);
          const seen = await records(page);
          console.info(`${name} ${look} ${harness}: ${seen.length} record(s)\n  ${seen.join("\n  ")}`);
          // One record from the first frame on: no control in the row moved, resized, came or went.
          expect(seen).toHaveLength(1);
        } finally {
          await close(page);
        }
      },
    );
    const saved = SAVED[harness]!;
    test.each(engines.map(([name]) => name))(
      `%s: the ${look} look on ${harness}: a saved ${saved.modeId} replaces the highest level in its own slot`,
      async (name) => {
        const { page, ready } = await load(name, look, harness, true);
        try {
          await page.locator(".nt-field").waitFor({ timeout: 30_000 });
          // Before acpmux answers: the highest level, in the control's slot.
          expect((await records(page))[0] ?? "").toContain("mode ");
          expect(await modeName(page)).toBe(highest);
          // acpmux answers with the saved choice: it replaces the highest level.
          await ready;
          await page.waitForFunction(
            (name) => document.querySelector(".nt-composer .acpmux-mode")?.textContent?.trim() === name,
            saved.name,
            { timeout: 10_000 },
          );
          await settled(page);
          expect(await modeName(page)).toBe(saved.name);
          // The control keeps its place (its label's width is its own); no other control moves.
          const seen = (await records(page)).map((record) =>
            record.replace(/mode ([\d.]+,[\d.]+) [\d.]+x[\d.]+ "[^"]*"/, "mode $1"),
          );
          console.info(`${name} ${look} ${harness} saved: ${seen.length} record(s)\n  ${seen.join("\n  ")}`);
          expect(new Set(seen).size).toBe(1);
        } finally {
          await close(page);
        }
      },
    );
  }

  // The launch's first New Tab page: no kept catalog; acpmux starts each harness on its model's own
  // default effort from its curated catalog (hub/start_defaults.rs; Opus 5.5 and GPT-5.5: Medium).
  for (const [look, harness, highest] of cases) {
    test.each(engines.map(([name]) => name))(
      `%s: the launch's first page, the ${look} look on ${harness}: its row holds still from the first frame`,
      async (name) => {
        const { page, ready } = await load(name, look, harness, false, {
          kept: false,
          start: "medium",
          codexStart: "medium",
        });
        try {
          await page.locator(".nt-field").waitFor({ timeout: 30_000 });
          // The last pick's harness on the first frame: its highest level names the mode control.
          expect(await modeName(page)).toBe(highest);
          await ready;
          await settled(page);
          const seen = await records(page);
          console.info(`${name} ${look} ${harness} first page: ${seen.length} record(s)\n  ${seen.join("\n  ")}`);
          // No control in the row moved, resized, renamed, came or went: the harness and the
          // effort were named on the first frame.
          expect(seen).toHaveLength(1);
        } finally {
          await close(page);
        }
      },
    );
  }
});
