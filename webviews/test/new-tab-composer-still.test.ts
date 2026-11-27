// cmux-web-test-timeout: 420
// The New Tab composer stays where it first painted (Leo 2026-10-19 on nightly-next: the composer
// keeps "going to places"). From the first frame through the handshake, the chats and device
// chats arriving, typing (the suggestions popover), a pasted image (the attachment chips), the
// Now Playing player appearing and the page outgrowing its window, the composer's card keeps its
// top, left edge and width, and the field (where the text is typed) keeps its top and left edge.
// The Default template's stage layout docks the composer at the page's foot instead: there the
// card keeps its bottom edge, left edge and width while it grows upward.
//
// The real agent pane (the dev entry) in Chromium and WebKit, with a stand-in host and a stand-in
// acpmux daemon whose chat list comes late. A script from the document's start records the card's
// rect on every DOM change and every frame; every recorded rect must be the first one.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-composer-still.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-composer-still.test.ts", async () => {
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
      console.warn(`new-tab-composer-still: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab composer still", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const ATLAS = `${HOME}/src/atlas`;
  const now = Date.now();
  const hours = (count: number) => now - count * 3_600_000 - 600_000;
  const sessions = Array.from({ length: 8 }, (_, index) => ({
    sessionId: `s-${index}`,
    cwd: ATLAS,
    harness: index % 2 ? "codex" : "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: hours(index + 1),
    title: `Chat number ${index + 1}`,
  }));
  const device = [{ key: "codex:d-old", harness: "codex", title: "Older device chat", updatedAt: hours(30) }];
  const LIST_DELAY = 1_200;

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
            await Bun.sleep(LIST_DELAY);
            result = { sessions };
          } else if (message.method === "_acpmux/sessions") result = { sessions: [] };
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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

  /// Each page's chat list arriving (see load).
  const listed = new WeakMap<Page, Promise<void>>();

  /// A New Tab page as a new workspace opens one (no folder of its own), recording the composer
  /// card's rect and the field's top and left edge, labelled with the step that was running.
  async function load(name: string, template: string, height: number): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1000, height } });
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const context = { kind: "agent", hotkeys: {}, home: HOME, projects: [ATLAS], host: "cosmic-gray", template };
    await page.addInitScript(
      ({ endpoint, context, device }) => {
        const w = window as unknown as Record<string, unknown> & {
          cmuxAcpmuxBridge?: { applyDeviceChats?(chats: unknown): void };
        };
        w.__cmuxNewTabContext = context;
        const later = (ms: number, value: unknown) =>
          // fixed-wait: the stand-in host answers late on purpose; the composer must hold through it
          new Promise((resolve) => setTimeout(() => resolve({ ok: true, value }), ms));
        const answer = (request: { method: string }): unknown => {
          switch (request.method) {
            case "ready":
              setTimeout(() => {
                w.cmuxAcpmuxBridge?.applyDeviceChats?.(device);
                w.__deviceChats = true;
              }, 350);
              return later(300, {
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
              return later(300, { projects: [`${String(context.home)}/src/atlas`] });
            case "transport.gesture":
              return later(0, { ticket: "gesture" });
            default:
              return later(0, null);
          }
        };
        w.webkit = { messageHandlers: { agentSession: { postMessage: answer } } };
        const rects: string[] = [];
        w.__rects = rects;
        w.__step = "first frame";
        const read = () => {
          const box = document.querySelector(".nt-box");
          const field = document.querySelector(".nt-field");
          if (!box || !field) return;
          const at = box.getBoundingClientRect();
          const text = field.getBoundingClientRect();
          // The stage layout (Default, #22119) docks the composer at the page's foot, as Claude Code
          // desktop does: its bottom edge holds and it grows upward, as the chat composer does, so
          // there the card keeps its bottom, left edge and width, and the field its left edge.
          const docked = document.querySelector(".nt-screen")?.getAttribute("data-layout") === "stage";
          const rect = docked
            ? `bottom ${at.bottom} left ${at.left} width ${at.width} field left ${text.left}`
            : `top ${at.top} left ${at.left} width ${at.width} field ${text.top},${text.left}`;
          if (rects.at(-1)?.startsWith(`${rect} @`)) return;
          rects.push(`${rect} @ ${String(w.__step)}`);
        };
        new MutationObserver(read).observe(document, {
          subtree: true,
          childList: true,
          characterData: true,
          attributes: true,
        });
        window.cmuxAfterPaint(read);
      },
      { endpoint, context, device },
    );
    // The page has the chat list once the daemon's watch answer (the list of sessions) reaches it.
    listed.set(
      page,
      new Promise((resolve) =>
        page.on("websocket", (socket) =>
          socket.on("framereceived", (frame) => {
            if (String(frame.payload).includes('"sessions":[{')) resolve();
          }),
        ),
      ),
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    return page;
  }

  /// Resolves once the page holds still: 10 painted frames with no DOM change and nothing animating,
  /// the Now Playing player's ticking progress aside (120 frames at most).
  const settled = (page: Page) =>
    page.evaluate(async () => {
      const ticking = (node: Node | null | undefined) =>
        (node instanceof Element ? node : node?.parentElement)?.closest(".nt-player") != null;
      let changed = true;
      const observer = new MutationObserver((records) => {
        if (records.some((record) => !ticking(record.target))) changed = true;
      });
      observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
      for (let held = 0, frames = 0; held < 10 && frames < 120; frames += 1) {
        await window.cmuxPaintFrame();
        const moving = document
          .getAnimations()
          .some(
            (animation) =>
              animation.playState === "running" &&
              Number.isFinite(animation.effect?.getComputedTiming().endTime) &&
              !(animation.effect instanceof KeyframeEffect && ticking(animation.effect.target)),
          );
        held = changed || moving ? 0 : held + 1;
        changed = false;
      }
      observer.disconnect();
    });

  const step = (page: Page, name: string) => page.evaluate((name) => Object.assign(window, { __step: name }), name);

  /// Every state the page goes through after it opens, as a user meets them.
  async function walk(page: Page) {
    await step(page, "loading");
    await page.locator(".nt-field").waitFor({ timeout: 30_000 });
    // The chats and the device chats arrive.
    await listed.get(page);
    await page.waitForFunction(() => (window as unknown as { __deviceChats?: boolean }).__deviceChats === true);
    await step(page, "typing");
    await page.locator(".nt-field .ProseMirror").click();
    await page.keyboard.type("how do I fix the build");
    await page.locator(".nt-popover .nt-row").first().waitFor({ timeout: 10_000 });
    await settled(page);
    await step(page, "attachment");
    const data = await page.evaluateHandle(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 320;
      canvas.height = 200;
      canvas.getContext("2d")!.fillRect(0, 0, 320, 200);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const transfer = new DataTransfer();
      transfer.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      return transfer;
    });
    // The field is the composer's Markdown prompt: the paste goes to its editable element, where it
    // went to the textarea, and the image is a chip at the caret in the text (the default inline view).
    await page
      .locator(".nt-field .ProseMirror")
      .evaluate(
        (node, data) =>
          node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
        data,
      );
    await page.locator(".nt-box .nt-field [data-inline-attachment] img").waitFor({ timeout: 10_000 });
    await settled(page);
    await step(page, "now playing");
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyNowPlaying(track: unknown): void } }
      ).cmuxAcpmuxBridge.applyNowPlaying({
        title: "Song",
        artist: "Band",
        playing: true,
        rate: 1,
        positionDate: Date.now(),
        position: 10,
        duration: 200,
        canPrevious: true,
        canNext: true,
        labels: { play: "Play", pause: "Pause", previous: "Previous", next: "Next" },
      }),
    );
    await page.locator(".nt-player").waitFor({ timeout: 10_000 });
    await settled(page);
    await step(page, "long draft");
    await page.keyboard.type(" and then".repeat(30));
    await settled(page);
    return page.evaluate(() => (window as unknown as { __rects: string[] }).__rects);
  }

  const cases: [string, number][] = [
    ["cards", 900],
    ["cards", 560],
    ["default", 900],
    ["default", 560],
    ["composer", 900],
  ];
  for (const [template, height] of cases) {
    test.each(engines.map(([name]) => name))(
      `%s: the ${template} page's composer stays put in a ${height}px window`,
      async (name) => {
        const page = await load(name, template, height);
        const rects = await walk(page);
        await page.close();
        console.info(`${name} ${template} ${height}: ${rects.length} rect(s)\n  ${rects.join("\n  ")}`);
        // One rect from the first frame on: no state moved the card or the field's text.
        expect(rects).toHaveLength(1);
      },
    );
  }
});
