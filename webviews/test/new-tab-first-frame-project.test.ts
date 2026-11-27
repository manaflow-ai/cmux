// cmux-web-test-timeout: 300
// A New Tab page names its project and machine on its first frame, and keeps them (Leo 2026-10-19:
// "new tab still paints first frame as unexplored ... it's indecisive between 'defaults' and
// 'recently used'"). The page drew "Choose folder" until the host's handshake or the daemon's chat
// list answered, then flipped to the project the tab inherited or the one used last.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host (its handshake
// late, as a cold page's is) and a stand-in acpmux daemon (its chat list late). A script from the
// document's start records the location strip's visible text on every DOM change and every frame.
// Cached-content raster cases hold every host response until the full App's first content PNG,
// then compare it with the hydrated PNG. The 450px case is split-sized browser UI; native split
// adoption and the cover over a delayed lazy chunk are verified by native composer/split tests.
// Leo 2026-11-27: "oh but then it just flickers afterwards it seems which defeats the purpose".
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-first-frame-project.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdirSync, writeFileSync } from "node:fs";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
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
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
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
    {
      sessionId: "s-billing",
      cwd: BILLING,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: now - 60_000,
    },
    {
      sessionId: "s-atlas",
      cwd: ATLAS,
      harness: "claude",
      status: "idle",
      turnCount: 1,
      updatedAt: now - 1_000,
    },
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
            result = {
              protocolVersion: 1,
              _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
            };
          else if (message.method === "_acpmux/harnesses") {
            result = {
              harnesses: {
                claude: {
                  name: "Claude Code",
                  kind: "acp",
                  start: {
                    model: "claude-opus-5-5",
                    effort: "medium",
                    modelSource: "saved",
                    effortSource: "saved",
                  },
                },
              },
              defaultHarness: "claude",
            };
          } else if (message.method === "_acpmux/models") {
            result = {
              harnesses: [
                {
                  harness: "claude",
                  models: [
                    {
                      id: "claude-opus-5-5",
                      name: "Opus 5.5",
                      efforts: ["low", "medium", "high", "xhigh", "max"],
                    },
                  ],
                },
              ],
            };
          } else if (message.method === "_acpmux/watch") {
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
    const warmStart = performance.now();
    await warmViteServer(vite, "/");
    console.info(`new-tab setup warm: ${Math.round(performance.now() - warmStart)}ms`);
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Host = { cwd?: string; handshakeDelay: number; raster?: string };
  /// Opens a New Tab page in `context` with the host's context injected as the document commits
  /// (AgentPaneNavigation), and returns every distinct location text it painted, in order.
  async function newTab(context: BrowserContext, { cwd, handshakeDelay, raster }: Host, settle: string) {
    const rasterStart = performance.now();
    const page = await context.newPage();
    const observed: string[] = [];
    page.on("pageerror", (error) => observed.push(`pageerror: ${error.message}`));
    page.on("console", (message) => {
      if (message.type() === "error" || message.text().startsWith("fixture host:"))
        observed.push(message.text().slice(0, 500));
    });
    page.on("websocket", (socket) => {
      socket.on("framesent", (frame) => observed.push(`sent: ${String(frame.payload).slice(0, 200)}`));
      socket.on("framereceived", (frame) => observed.push(`received: ${String(frame.payload).slice(0, 200)}`));
    });
    const stage = async <T>(name: string, work: Promise<T>): Promise<T> => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        return await Promise.race([
          work,
          new Promise<never>((_, reject) => {
            timer = setTimeout(() => reject(new Error(`${name} timed out: ${observed.join("\n")}`)), 30_000);
          }),
        ]);
      } catch (error) {
        console.error(`stage ${name}: ${await page.locator("body").innerText()}`);
        const wire = await page.evaluate(async (modulePath) => {
          const { acpWire } = await import(modulePath);
          return acpWire.exportJsonl();
        }, "/src/agent-session/acpmux/wire.ts");
        console.error(`stage ${name} wire: ${wire}`);
        throw error;
      } finally {
        clearTimeout(timer);
      }
    };
    await installPaintedFrames(page);
    if (raster) await page.clock.setFixedTime(new Date(now));
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, cwd, home, handshakeDelay, raster }) => {
        const newTab = {
          kind: "agent",
          hotkeys: {},
          home,
          projects: raster ? [`${home}/src/billing`, `${home}/src/atlas`] : [],
          ...(raster
            ? {
                projectRows: JSON.stringify(
                  ["billing", "atlas"].map((name) => {
                    const cwd = `${home}/src/${name}`;
                    return {
                      cwd,
                      label: name,
                      displayGroup: { key: cwd, name, lead: cwd, mainLead: cwd, hidden: false },
                    };
                  }),
                ),
              }
            : {}),
          host: "cosmic-gray",
          ...(cwd ? { cwd } : {}),
        };
        (window as unknown as Record<string, unknown>).__cmuxNewTabContext = newTab;
        // The host's answers still on their way; each comes `ms` late.
        const w = window as unknown as { __hostPending: number; __releaseHydration: () => void };
        const hydration = raster
          ? new Promise<void>((resolve) => {
              w.__releaseHydration = resolve;
            })
          : Promise.resolve();
        w.__hostPending = 0;
        const later = (ms: number, value: unknown) => {
          w.__hostPending += 1;
          // fixed-wait: the stand-in host answers late on purpose; the label must hold through it
          return hydration
            .then(() => new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms)))
            .then((answer) => {
              w.__hostPending -= 1;
              return answer;
            });
        };
        const answer = (method: string): unknown => {
          console.info(`fixture host: ${method}`);
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
              return later(handshakeDelay, {
                projects: [`${home}/src/atlas`, `${home}/src/billing`],
              });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        (window as unknown as { webkit: unknown }).webkit = {
          messageHandlers: {
            agentSession: { postMessage: (request: { method: string }) => answer(request.method) },
          },
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
      { endpoint, cwd, home: HOME, handshakeDelay, raster },
    );
    // The daemon's chat list reaching the page.
    const listed = new Promise<void>((resolve) =>
      page.on("websocket", (socket) =>
        socket.on("framereceived", (frame) => {
          if (String(frame.payload).includes('"sessions":[{')) resolve();
        }),
      ),
    );
    const catalogDelivered = new Promise<void>((resolve) => {
      const kinds = new Set<string>();
      page.on("websocket", (socket) =>
        socket.on("framereceived", (frame) => {
          const reply = JSON.parse(String(frame.payload)) as { result?: { harnesses?: unknown } };
          if (!reply.result?.harnesses) return;
          kinds.add(Array.isArray(reply.result.harnesses) ? "models" : "harnesses");
          if (kinds.size === 2) resolve();
        }),
      );
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    let firstPixels: Buffer | undefined;
    if (raster) {
      // The document-start cache supplies the first content frame. Hold every host reply until
      // that frame is captured; a fast machine cannot accidentally capture settled hydration.
      await page.locator(".nt-location").waitFor();
      await page.evaluate(() => window.cmuxPaintFrame());
      expect(await page.evaluate(() => (window as unknown as { __hostPending: number }).__hostPending)).toBeGreaterThan(
        0,
      );
      firstPixels = await page.screenshot({ caret: "hide" });
      await page.evaluate(() => (window as unknown as { __releaseHydration: () => void }).__releaseHydration());
    }
    await page.locator(".nt-location").getByText(settle).waitFor();
    // Past the handshake, the daemon's list and the projects list (the second one goes out before
    // the daemon is asked for its chats), and a painted frame after them.
    await stage("session list", listed);
    await stage("model catalog", catalogDelivered);
    await page.waitForFunction(() => (window as unknown as { __hostPending: number }).__hostPending === 0);
    await stage(
      "settled paint",
      page.evaluate(() => window.cmuxPaintFrame()),
    );
    const painted = await page.evaluate(() => (window as unknown as { __painted: string[] }).__painted);
    if (raster && firstPixels) {
      const settledPixels = await page.screenshot({ caret: "hide" });
      const first = PNG.sync.read(firstPixels);
      const settled = PNG.sync.read(settledPixels);
      const diff = new PNG({ width: first.width, height: first.height });
      const changed = pixelmatch(first.data, settled.data, diff.data, first.width, first.height, {
        threshold: 0.1,
      });
      const artifacts = process.env.CMUX_FLICKER_ARTIFACT_DIR ?? path.join(webviews, "test-results/new-tab-flicker");
      mkdirSync(artifacts, { recursive: true });
      writeFileSync(path.join(artifacts, `${raster}-first.png`), firstPixels);
      writeFileSync(path.join(artifacts, `${raster}-settled.png`), settledPixels);
      writeFileSync(path.join(artifacts, `${raster}-diff.png`), PNG.sync.write(diff));
      console.info(`raster: ${raster}: ${changed} changed pixels in ${Math.round(performance.now() - rasterStart)}ms`);
      expect(changed, `${raster}: cached first content frame must equal hydrated frame; see ${artifacts}`).toBe(0);
    }
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
      // The empty face (No folder, before it Choose folder) never paints before the project.
      expect(painted.every((text) => !/Choose folder|No folder/.test(text))).toBe(true);
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
      // The empty face (No folder, before it Choose folder) never paints before the project.
      expect(painted.every((text) => !/Choose folder|No folder/.test(text))).toBe(true);
      expect(painted.every((text) => text.includes("atlas"))).toBe(true);
      expect(new Set(painted).size).toBe(1);
    },
  );

  test.each(engines.flatMap(([name]) => [900, 450].map((width) => [name, width] as const)))(
    "%s: cached first content frame stays final at %ipx (full pane / split-sized UI)",
    async (name, width) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width, height: 640 } });
      try {
        await context.addInitScript(() => {
          localStorage.setItem("cmux.acpmux.lastChips", JSON.stringify({ claude: { effort: "Medium" } }));
          localStorage.setItem(
            "cmux.acpmux.lastPick",
            JSON.stringify({
              global: { harness: "claude", model: "claude-opus-5-5" },
              folders: {},
            }),
          );
        });
        listDelay = 0;
        // An earlier mounted App populated the same store that native New Tab pages share.
        await newTab(context, { cwd: ATLAS, handshakeDelay: 0 }, "atlas");
        await newTab(context, { cwd: ATLAS, handshakeDelay: 0, raster: `${name}-${width}` }, "atlas");
      } finally {
        await context.close();
      }
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a cold New Tab with nothing heard yet paints no default before the recent project",
    async (name) => {
      const context = await browsers.get(name)!.newContext({ viewport: { width: 900, height: 640 } });
      listDelay = 700;
      const painted = await newTab(context, { cwd: HOME, handshakeDelay: 300 }, "atlas");
      await context.close();
      // The empty face (No folder, before it Choose folder) never paints before the project.
      expect(painted.every((text) => !/Choose folder|No folder/.test(text))).toBe(true);
      // The machine shows at once; the folder's place stays empty until the chats answer.
      expect(painted.filter((text) => text.includes("atlas")).length).toBe(1);
      expect(painted.at(-1)).toContain("atlas");
    },
  );
});
