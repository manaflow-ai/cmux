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
// show on every DOM change and every frame; a warm open must paint one state only. The host's
// handshake and the daemon's chat list are held until the page has painted without them.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-warm-first-frame.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserContext, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
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
  // Hours old, so no age label turns over while a test runs. Two sessions and one device chat fill
  // the three cards of the Cards template (templates.ts), so the device chat is on the page.
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
  ];
  // The chat index's device chats the host pushes after the handshake (AgentPaneDeviceChat).
  const device = [{ key: "codex:d-old", harness: "codex", title: "Older device chat", updatedAt: hours(30) }];
  /// The daemon's chat list: answered once `held` settles; `asked` runs as a page asks for it.
  let list = { held: Promise.resolve(), asked: () => {} };
  /// Holds the daemon's chat list from now until `open()`; `asked` settles once a page asked for it.
  function holdList() {
    let open!: () => void;
    let asked!: () => void;
    const held = new Promise<void>((resolve) => (open = resolve));
    const wasAsked = new Promise<void>((resolve) => (asked = resolve));
    list = { held, asked };
    return { open, asked: wasAsked };
  }
  type ListHold = ReturnType<typeof holdList>;

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
            list.asked();
            await list.held;
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
  /// records each distinct Chats list and location strip it paints. A held host answers the
  /// handshake and the project list once the test calls the page's `__openHost()`.
  async function load(browserContext: BrowserContext, context: Context, holdHost = true): Promise<Page> {
    const page = await browserContext.newPage();
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.addInitScript(
      ({ endpoint, context, holdHost, device }) => {
        const w = window as unknown as Record<string, unknown> & {
          cmuxAcpmuxBridge?: { applyDeviceChats?(chats: unknown): void };
        };
        w.__cmuxNewTabContext = context;
        let openHost!: () => void;
        const host = holdHost ? new Promise<void>((resolve) => (openHost = resolve)) : Promise.resolve();
        w.__openHost = () => openHost?.();
        const later = (value: unknown) => Promise.resolve({ ok: true, value });
        const held = (value: unknown) => host.then(() => ({ ok: true, value }));
        // Each `newTab.warm` the page posted, as JSON text.
        const posts: string[] = [];
        w.__posts = posts;
        w.__projectsListed = false;
        const answer = (request: { method: string; params?: { warm?: unknown } }): unknown => {
          switch (request.method) {
            case "ready":
              // The host pushes the device chats as it accepts the handshake (AgentPaneBridge).
              void host.then(() => setTimeout(() => w.cmuxAcpmuxBridge?.applyDeviceChats?.(device), 0));
              return held({
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
              return later({ newTab: context });
            case "newTab.warm":
              posts.push(JSON.stringify(request.params?.warm));
              return later(null);
            case "project.list":
              return held({
                projects: [`${String(context.home)}/src/atlas`, `${String(context.home)}/src/billing`],
              }).then((answer) => {
                w.__projectsListed = true;
                return answer;
              });
            case "transport.gesture":
              return later({ ticket: "gesture" });
            default:
              return later(null);
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
        window.cmuxAfterPaint(read);
      },
      { endpoint, context, holdHost, device },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    return page;
  }

  /// Two frames painted from now on.
  const twoFrames = (page: Page) => page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));

  /// What `page` painted from now until its handshake, chats and projects have all answered: the
  /// host answers once the page has painted its New Tab screen, the daemon lists the chats once the
  /// page has painted the handshake, and the page has posted the listed chats with the device chats.
  async function settle(page: Page, chats: ListHold): Promise<string[]> {
    await page.locator(".nt-screen").waitFor({ timeout: 30_000 });
    await twoFrames(page);
    await page.evaluate(() => (window as unknown as { __openHost(): void }).__openHost());
    await chats.asked;
    await twoFrames(page);
    chats.open();
    await page.waitForFunction(
      () => {
        const w = window as unknown as { __posts: string[]; __projectsListed: boolean };
        return w.__projectsListed && w.__posts.some((post) => post.includes("s-atlas") && post.includes("d-old"));
      },
      null,
      { timeout: 30_000 },
    );
    await page.locator(".nt-card", { hasText: "Fix the atlas build" }).waitFor({ timeout: 30_000 });
    await twoFrames(page);
    const painted = await page.evaluate(() => (window as unknown as { __painted: string[] }).__painted);
    return painted;
  }

  // Cards, the template these frames were drawn on (an unset one is Minimal, which has no cards).
  const base = {
    kind: "agent",
    hotkeys: {},
    home: HOME,
    projects: [ATLAS, BILLING],
    host: "cosmic-gray",
    template: "cards",
  };
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
    holdList().open();
    const source = await load(browserContext, { ...base }, false);
    await source.locator(".nt-card", { hasText: "Fix the atlas build" }).waitFor({ timeout: 30_000 });
    // The post after the host's device chats push carries them too.
    const posted = () =>
      (window as unknown as { __posts: string[] }).__posts.filter((post) => post.includes("d-old")).at(-1);
    await source.waitForFunction(posted, null, { timeout: 5_000 }).catch(() => {});
    warmed = await source.evaluate(posted);
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
        const chats = holdList();
        const page = await load(browserContext, { ...context, warm: warmed });
        const painted = await settle(page, chats);
        await page.close();
        await browserContext.close();
        console.info(`${name} ${entry} warm: ${painted.length} state(s) ${JSON.stringify(painted)}`);
        counts[`${name} ${entry} warm`] = painted.length - 1;
        expect(warmed).toBeDefined();
        // One state from the first frame on: the final list and the recent project, never empty first.
        expect(painted).toHaveLength(1);
        expect(painted[0]).toContain("Fix the atlas build");
        expect(painted[0]).toContain("Older device chat");
        // The bar names the folder and the machine (this Mac reads "This Mac", #28999); New Worktree is in the folder menu only.
        expect(painted[0]).toStartWith("atlas This Mac ::");
      },
    );
  }

  test.each(engines.map(([name]) => name))(
    "%s: an adopted spare paints its final chats from the adoption on",
    async (name) => {
      const browserContext = await browsers.get(name)!.newContext({ viewport: { width: 1000, height: 900 } });
      await warmUp(browserContext);
      // A spare made before any page listed chats, whose own list has not come yet.
      const chats = holdList();
      const spare = await load(browserContext, { ...base });
      await spare.locator(".nt-field").waitFor();
      await spare.evaluate(() => (window as unknown as { __openHost(): void }).__openHost());
      await chats.asked;
      await twoFrames(spare);
      // Cmd-T adopts it: the host dispatches the opening's context (AgentPaneView.adoptNewTab).
      await spare.evaluate(
        (detail) => {
          (window as unknown as { __painted: string[] }).__painted.length = 0;
          window.dispatchEvent(new CustomEvent("acpmux-newtab-adopt", { detail }));
        },
        { ...base, cwd: ATLAS, warm: warmed },
      );
      const painted = await settle(spare, chats);
      await spare.close();
      await browserContext.close();
      console.info(`${name} adopted spare warm: ${painted.length} state(s) ${JSON.stringify(painted)}`);
      counts[`${name} adopted spare warm`] = painted.length - 1;
      expect(warmed).toBeDefined();
      expect(painted).toHaveLength(1);
      expect(painted[0]).toContain("Fix the atlas build");
      // The adopting tab's project, not the spare's "Choose folder"; this Mac reads "This Mac" (#28999).
      expect(painted[0]).toStartWith("atlas This Mac ::");
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a cold launch with nothing listed yet fills the list once",
    async (name) => {
      const browserContext = await browsers.get(name)!.newContext({ viewport: { width: 1000, height: 900 } });
      const chats = holdList();
      const page = await load(browserContext, { ...base });
      const painted = await settle(page, chats);
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
