// l10n-allow-file: test fixture prompts, replies, titles and summaries, not shipped UI.
// An added item never displaces the chat header's fixed controls. Leo, 2026-11-22, on the header's tools pushed to a
// second row after a summary line was added: "like from the getgo it's just weird here. this doesn't seem like correct
// behaviour. the icons on the top right have gotten displaced due to putting things on a line. this is not how we
// should do ui. we need to have a proper way to do ui so that when anybody wants to adjust or customize things like
// this, it is done easily properly."
//
// The header is named slots (header/headerSlots.ts): `title`, `accessory`, `trailing`. The trailing tools (the panel
// toggle, the quick actions, "...") are fixed; every optional item is registered in the title or accessory slot with
// its overflow rule and takes only the room the trailing slot leaves. This mounts the header with each optional item
// on, all of them on, and none: the rolling summary, the live tree pill, presence faces, a warning status, the
// worktree pill, the pull request chip, a Needs You ask and a long title; in the header's own row and in the pane's
// tab row; at 320px and a quarter, a third, a half and all of a 1512px window. At each width the trailing tools sit at
// the same place on screen whatever is on, and nothing intersects: no tool, item, title, tab or transcript.
//
// The App's side of the tab row is modeled as Swift does it (PaneContentView.layout, AgentPaneTabRow), as in
// test/chat-header-summary-row-fit-browser.test.ts: the row is offered while the tools' need <= half the row, the strip
// gives up min(width, row / 2), and a chat out of the row is laid under the strip (one strip lower).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane). With
// CHAT_HEADER_SHOTS=<dir> it also writes each case's header, cropped, with the strip's tabs drawn in.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-header-slots-browser.test.ts", async () => {
  setDefaultTimeout(600_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const shots = process.env.CHAT_HEADER_SHOTS;
  if (shots) mkdirSync(shots, { recursive: true });

  const START = Date.UTC(2026, 10, 22, 5, 0, 0);
  const REPLY = "Posted the stall history.";
  const WINDOW = 1512;
  // Widest first: each page opens wide and is split narrower, as a person splits a pane.
  const WIDTHS: [string, number][] = [
    ["full", WINDOW],
    ["half", WINDOW / 2],
    ["third", Math.round(WINDOW / 3)],
    ["quarter", Math.round(WINDOW / 4)],
    ["narrow", 320],
  ];
  const INSET = 40;
  const STRIP = 28;

  const ITEMS = [
    "summary",
    "liveTree",
    "presence",
    "warning",
    "worktree",
    "pullRequest",
    "needsYou",
    "longTitle",
  ] as const;
  type Item = (typeof ITEMS)[number];
  const COMBOS: Item[][] = [[], ...ITEMS.map((item) => [item]), [...ITEMS]];
  const comboName = (items: readonly Item[]) =>
    items.length === 0 ? "none" : items.length === ITEMS.length ? "all" : items.join("+");

  // One chat per combination, its items read from the id (the daemon and the host stand-ins answer by it).
  const chats = new Map<string, readonly Item[]>();
  const chatFor = (items: readonly Item[]) => {
    const id = `0190a000-0000-7000-8000-${(0xe00 + chats.size).toString(16).padStart(12, "0")}`;
    chats.set(id, items);
    return id;
  };
  const has = (sessionId: unknown, item: Item) => chats.get(String(sessionId))?.includes(item) === true;

  const eventsFor = (sessionId: string) =>
    (
      [
        ["mux", "user_message", { text: "Post the stall history" }],
        ["mux", "turn_started", {}],
        [
          "in",
          "agent_message_chunk",
          {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
            },
          },
        ],
        ["mux", "turn_result", { status: "completed" }],
      ] as [string, string, Record<string, unknown>][]
    ).map(([dir, kind, msg], index) => ({ sessionId, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
  const sessionFor = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: has(sessionId, "longTitle")
      ? "Investigate why the uploader's retry loop stalls on the second permission prompt after a reconnect"
      : "release-coordinator",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    ...(has(sessionId, "summary")
      ? {
          rollingSummary: {
            text: "I posted the build host's 14-day permission-stall history on the tracking issue (https://example.com/issues/7645)",
            next: "Wait for the owner's read",
          },
        }
      : {}),
  });

  function answer(method: string, params: { sessionId?: unknown } | undefined): { result?: unknown; error?: unknown } {
    const id = String(params?.sessionId ?? "");
    switch (method) {
      case "initialize":
        return {
          result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
        };
      case "_acpmux/watch":
        return { result: { sessions: [...chats.keys()].map(sessionFor) } };
      case "_acpmux/attach":
        return {
          result: {
            session: sessionFor(id),
            lastSeq: 4,
            events: eventsFor(id),
            ...(has(id, "presence")
              ? { presence: { participants: [{ id: "avery", name: "Avery Lee", viewing: true }] } }
              : {}),
          },
        };
      case "_acpmux/events":
        // A warning chat: acpmux dropped its events (`_acpmux/lagged`, sent after its attach) and every read of them
        // fails, so once the page's retries run out (direct.ts readMissedAfterLag, ~16 s) the chat's connection is
        // "failed" and the header says so (model.ts paneHeader), and stays so.
        if (has(id, "warning")) return { error: { code: -32000, message: "events unavailable" } };
        return { result: { events: [], hasMore: false, lastSeq: 4 } };
      case "_acpmux/info":
        return { result: { liveTree: { available: true, lanes: [{ name: "unit", verdict: "passed" }] } } };
      default:
        return { result: null };
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (chat: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat}`;
  };
  const warmChat = chatFor([]);
  const combos = COMBOS.map((items) => ({ items, chat: chatFor(items) }));

  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { sessionId?: unknown } };
          if (message.id === undefined) return;
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, message.params) }));
          const id = String(message.params?.sessionId ?? "");
          if (message.method === "_acpmux/attach" && has(id, "warning"))
            setTimeout(
              () =>
                ws.send(
                  JSON.stringify({
                    jsonrpc: "2.0",
                    method: "_acpmux/lagged",
                    params: { sessionIds: [id], dropped: 3 },
                  }),
                ),
              200,
            );
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
    browser = await chromium.launch({ headless: true });
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(warmChat));
        await warm.getByText(REPLY).waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  type Layout = {
    shared: boolean;
    reported: number;
    pane: number;
    strip: Box;
    /// The fixed tools: the panel toggle, the quick actions and "...", by name.
    trailing: [string, Box][];
    /// Everything else drawn in the header, by name.
    items: [string, Box][];
    under?: Box;
  };

  /// Opens `chat` in a full-window pane with its items on, in its own row (`tabRow` false) or with the App's tab row
  /// modeled (above).
  async function open(chat: string, items: readonly Item[], tabRow: boolean): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: WINDOW, height: 640 } });
    await installPaintedFrames(page);
    // The app's side: the page's dev host (dev-host/host.ts, installed for `#endpoint=`) answers the page's calls;
    // this wraps it so the worktree pill reads the folder's git status (`git.status`).
    await page.addInitScript(
      ({ worktree }) => {
        const posts: string[] = [];
        (window as unknown as { __posts: string[] }).__posts = posts;
        type Handler = { postMessage(message: unknown): Promise<unknown> };
        const own = (method: string): { value: unknown } | undefined => {
          if (method === "git.status" && worktree)
            return {
              value: {
                branch: "feat/stall-history",
                base: "main",
                detached: false,
                worktree: { main_root: "/home/dev/uploader-main" },
              },
            };
          return undefined;
        };
        const wrap = (inner: Handler, envelope: (message: unknown) => { id?: unknown; method?: string }): Handler => ({
          postMessage: async (message) => {
            const { id, method } = envelope(message);
            if (method) posts.push(method);
            const answer = method ? own(method) : undefined;
            if (!answer) return inner.postMessage(message);
            return id === undefined ? { ok: true, value: answer.value } : { t: "ok", id, value: answer.value };
          },
        });
        const handlers: Record<string, Handler | undefined> = {};
        const slot = (name: string, envelope: (message: unknown) => { id?: unknown; method?: string }) => {
          let inner: Handler | undefined;
          Object.defineProperty(handlers, name, {
            enumerable: true,
            get: () => (inner ? wrap(inner, envelope) : undefined),
            set: (next: Handler) => {
              inner = next;
            },
          });
        };
        // The page host's envelopes (`{t: "call", id, op: "cmux.agent.METHOD"}`) and the older bridge's requests.
        slot("cmuxPage", (message) => {
          const call = message as { t?: string; id?: unknown; op?: string };
          return call?.t === "call" ? { id: call.id, method: String(call.op ?? "").replace(/^cmux\.agent\./, "") } : {};
        });
        slot("agentSession", (message) => ({ method: (message as { method?: string })?.method }));
        (window as unknown as { webkit: unknown }).webkit = { messageHandlers: handlers };
      },
      {
        worktree: items.includes("worktree"),
      },
    );
    await page.goto(url(chat));
    try {
      await page.getByText(REPLY).waitFor();
      if (items.includes("warning"))
        await page.locator(".acpmux-status").first().waitFor({ state: "attached", timeout: 45_000 });
    } catch (error) {
      console.log(
        `chat-header-slots ${comboName(items)}: posts ${await page.evaluate(() => (window as unknown as { __posts: string[] }).__posts.join(","))}`,
      );
      console.log(
        (
          await page
            .locator(".acpmux-header")
            .first()
            .evaluate((node) => node.outerHTML)
            .catch(() => "no header")
        ).slice(0, 4000),
      );
      throw error;
    }
    await page.waitForFunction(
      () =>
        Boolean((window as { cmuxAcpmuxBridge?: { applyTabRow?: unknown } }).cmuxAcpmuxBridge?.applyTabRow) &&
        Boolean(window.cmuxAcpmuxActions),
    );
    await page.evaluate(
      ({ inset, strip, tabRow, items }) => {
        type Bridge = {
          applyTabRow(row: unknown): void;
          applyLiveTree(on: unknown): void;
          applyHeaderState(state: unknown): void;
          applyAttentionTabs(tabs: unknown): void;
        };
        const bridge = (window as unknown as { cmuxAcpmuxBridge: Bridge }).cmuxAcpmuxBridge;
        if (items.includes("liveTree")) bridge.applyLiveTree(true);
        if (items.includes("pullRequest"))
          bridge.applyHeaderState({
            pullRequest: {
              url: "https://example.com/pull/7",
              number: 7645,
              title: "Post the stall history",
              state: "open",
              checks: { state: "passing", passed: 2, total: 2 },
            },
          });
        if (items.includes("needsYou"))
          bridge.applyAttentionTabs([
            {
              kind: "tab",
              tabId: "t1",
              reason: "Approve the deploy",
              workspaceTitle: "uploader",
              tabTitle: "deploy",
              atMs: 1,
            },
          ]);
        const host = {
          need: 0,
          width: 0,
          offered: false,
          changes: 0,
          inset,
          strip,
          tabRow,
          room: () => window.innerWidth - inset,
          /// PaneContentView.layout: the row is offered while the need fits half of it.
          layout() {
            const fits = host.tabRow && host.need <= host.room() / 2;
            if (fits === host.offered) return;
            host.offered = fits;
            host.changes++;
            bridge.applyTabRow(fits ? { height: strip, trailingInset: inset } : { height: 0, trailingInset: 0 });
          },
        };
        (window as unknown as { __host: typeof host }).__host = host;
        window.cmuxAcpmuxActions!["pane.tabRowTools"] = async (params) => {
          const { width, need } = params as { width: number; need?: number };
          if (width > 0) host.need = typeof need === "number" && need > 0 ? Math.min(width, need) : width;
          if (width !== host.width) host.changes++;
          host.width = width;
          host.layout();
          return null;
        };
        host.layout();
      },
      { inset: INSET, strip: STRIP, tabRow, items: [...items] },
    );
    const ready = [
      // A warning takes the summary's place (ChatHeaderStatus): with both on, the warning shows.
      items.includes("summary") && !items.includes("warning") && "[data-chat-summary]",
      items.includes("liveTree") && ".acpmux-header-live-tree",
      items.includes("presence") && ".cv-presence",
      items.includes("worktree") && ".acpmux-header-worktree",
      items.includes("pullRequest") && ".acpmux-header-pr",
      items.includes("needsYou") && ".acpmux-needs-you-button[data-count]",
    ].filter((selector): selector is string => Boolean(selector));
    for (const selector of ready)
      await page
        .locator(selector)
        .first()
        .waitFor({ state: "attached" })
        .catch(async (error: unknown) => {
          console.log(
            `chat-header-slots ${comboName(items)}: no ${selector}; posts ${await page.evaluate(() => (window as unknown as { __posts: string[] }).__posts.join(","))}`,
          );
          console.log(
            (
              await page
                .locator(".acpmux-header")
                .first()
                .evaluate((node) => node.outerHTML)
            ).slice(0, 4000),
          );
          throw error;
        });
    await settle(page);
    return page;
  }

  async function resize(page: Page, width: number) {
    await page.setViewportSize({ width, height: 640 });
    // The pane lays out at its new size before the page measures again (AgentPaneTabRow keeps the need).
    await page.evaluate(() => (window as unknown as { __host: { layout(): void } }).__host.layout());
    await settle(page);
  }

  /// Painted frames until the App's model and the page have stopped answering each other.
  async function settle(page: Page) {
    let last = -1;
    for (let still = 0, frame = 0; still < 4 && frame < 120; frame++) {
      const changes = await page.evaluate(async () => {
        await window.cmuxPaintFrame();
        return (window as unknown as { __host: { changes: number } }).__host.changes;
      });
      still = changes === last ? still + 1 : 0;
      last = changes;
    }
  }

  /// Where things are on screen: the page's boxes, one strip lower while the chat is out of the row.
  const layout = (page: Page) =>
    page.evaluate((): Layout => {
      const host = (
        window as unknown as {
          __host: { offered: boolean; width: number; room(): number; inset: number; strip: number; tabRow: boolean };
        }
      ).__host;
      const shared = host.offered && host.width > 0;
      const dy = shared || !host.tabRow ? 0 : host.strip;
      const box = (element: Element | null | undefined): Box | undefined => {
        // Drawn only: the title slot is under the tabs in the tab row, hidden (header.css).
        if (!element || !element.checkVisibility({ visibilityProperty: true })) return undefined;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return undefined;
        return { left: rect.left, top: rect.top + dy, right: rect.right, bottom: rect.bottom + dy };
      };
      const given = shared ? Math.min(host.width, host.room() / 2) : 0;
      const header = document.querySelector(".acpmux-header")!;
      /// The first of `selector` that is drawn.
      const drawn = (selector: string) =>
        [...header.querySelectorAll(selector)].find((element) => element.checkVisibility({ visibilityProperty: true }));
      const named = (pairs: [string, Element | null | undefined][]) =>
        pairs.flatMap(([name, element]): [string, Box][] => {
          const value = box(element);
          return value ? [[name, value]] : [];
        });
      const trailing = named([
        ["panel", header.querySelector(".acpmux-header-panel-toggle")],
        ...[...header.querySelectorAll("[data-quick-action]")].map((element): [string, Element] => [
          `quick:${element.getAttribute("data-quick-action")}`,
          element,
        ]),
        ["more", header.querySelector(".acpmux-header-more")],
      ]);
      const items = named([
        ["inbox", drawn(".acpmux-needs-you-button")],
        ["title", drawn(".acpmux-thread-title")],
        ["summary", drawn("[data-chat-summary]")],
        ["status", drawn(".acpmux-status")],
        ["liveTree", header.querySelector(".acpmux-header-live-tree")],
        ["presence", header.querySelector(".cv-presence")],
        ["worktree", header.querySelector(".acpmux-header-worktree")],
        ["pullRequest", header.querySelector(".acpmux-header-pr")],
      ]);
      return {
        shared,
        reported: host.width,
        pane: window.innerWidth,
        // The pane's tabs and + button: the strip, from the row's start to where it gave the tools room.
        strip: { left: 0, top: 0, right: window.innerWidth - host.inset - given, bottom: host.tabRow ? host.strip : 0 },
        trailing,
        items,
        under: box(document.querySelector(".acpmux-scroll")),
      };
    });

  const intersects = (a: Box, b: Box) =>
    Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
    Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;
  const area = (a: Box, b: Box) =>
    Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
    Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  const round = (b: Box) => [Math.round(b.left), Math.round(b.top), Math.round(b.right), Math.round(b.bottom)];

  /// Every intersection that must not be, with its area in square CSS pixels. The status label fills the title's slot
  /// and the title is not drawn under it; the summary sits beside the title.
  function overlaps(at: Layout): string[] {
    const found: string[] = [];
    const all = [...at.trailing, ...at.items];
    for (let i = 0; i < all.length; i++) {
      const [name, b] = all[i]!;
      if (at.shared && intersects(b, at.strip)) found.push(`${name} x tabs (${Math.round(area(b, at.strip))}px²)`);
      if (at.under && intersects(b, at.under)) found.push(`${name} x transcript (${Math.round(area(b, at.under))}px²)`);
      if (b.left < -0.5 || b.right > at.pane + 0.5) found.push(`${name} out of the pane`);
      for (let j = i + 1; j < all.length; j++) {
        const [other, c] = all[j]!;
        if (intersects(b, c)) found.push(`${name} x ${other} (${Math.round(area(b, c))}px²)`);
      }
    }
    return found;
  }

  async function shoot(page: Page, name: string, at: Layout, tabRow: boolean) {
    if (!shots) return;
    await page.evaluate(
      ({ at, tabRow }) => {
        document.getElementById("__strip")?.remove();
        document.body.style.transform = "";
        if (!tabRow) return;
        // The strip's tabs and + button, drawn where the App draws them, so a crop shows what the person sees.
        const strip = document.createElement("div");
        strip.id = "__strip";
        strip.style.cssText = `position:fixed;left:0;top:0;width:${at.strip.right}px;height:${at.strip.bottom}px;z-index:99999;display:flex;align-items:center;gap:4px;padding:0 6px;box-sizing:border-box;background:rgba(127,127,127,.12);font:12px system-ui;color:#888;pointer-events:none;overflow:hidden`;
        strip.innerHTML = `<span style="flex:0 1 160px;min-width:40px;height:20px;border-radius:6px;background:rgba(127,127,127,.25);padding:0 8px;line-height:20px;white-space:nowrap;overflow:hidden">release-coordinator</span><span style="flex:0 1 160px;min-width:40px;height:20px;border-radius:6px;background:rgba(127,127,127,.15);padding:0 8px;line-height:20px;white-space:nowrap;overflow:hidden">Terminal</span><span style="flex:none">+</span>`;
        // A chat out of the row is laid under the strip: its page one strip lower.
        if (!at.shared) document.body.style.transform = `translateY(${at.strip.bottom}px)`;
        document.documentElement.append(strip);
      },
      { at, tabRow },
    );
    await page.evaluate(async () => void (await window.cmuxPaintFrame()));
    const width = page.viewportSize()!.width;
    await page.screenshot({ path: path.join(shots, `${name}.png`), clip: { x: 0, y: 0, width, height: 64 } });
    await page.evaluate(() => {
      document.getElementById("__strip")?.remove();
      document.body.style.transform = "";
    });
  }

  for (const tabRow of [false, true]) {
    const mode = tabRow ? "tab-row" : "own-row";
    describe(`the chat header's fixed tools never move for an added item (${mode})`, () => {
      // layouts[width][combo]
      const layouts = new Map<string, Map<string, Layout>>(WIDTHS.map(([split]) => [split, new Map()]));
      for (const { items, chat } of combos) {
        const name = comboName(items);
        test(`${name}: nothing intersects at any width`, async () => {
          const page = await open(chat, items, tabRow);
          const problems: string[] = [];
          for (const [split, width] of WIDTHS) {
            if (width !== WINDOW) await resize(page, width);
            const at = await layout(page);
            layouts.get(split)!.set(name, at);
            if (name === "none" || name === "all") await shoot(page, `${mode}-${split}-${name}`, at, tabRow);
            const found = overlaps(at);
            console.log(
              `chat-header-slots ${mode} ${split} ${width}px ${name}: ${at.shared ? "in the row" : tabRow ? "under the strip" : "own row"}, reported ${at.reported}, tools ${at.trailing.length}, items ${at.items.map(([n]) => n).join(",") || "-"}; overlaps ${JSON.stringify(found)}`,
            );
            if (found.length > 0) problems.push(`${split}: ${found.join("; ")}`);
          }
          await page.close();
          expect(problems).toEqual([]);
        });
      }
      for (const [split, width] of WIDTHS)
        test(`${split} (${width}px): the trailing tools sit where they sit with nothing added`, () => {
          const at = layouts.get(split)!;
          const base = at.get("none");
          expect(base).toBeDefined();
          expect(base!.trailing.length).toBeGreaterThan(0);
          const place = (layout: Layout, panel: boolean) => ({
            shared: layout.shared,
            tools: layout.trailing
              .filter(([name]) => panel || name !== "panel")
              .map(([name, b]) => [name, ...round(b)]),
          });
          const moved: string[] = [];
          for (const [name, layout] of at) {
            if (name === "none") continue;
            // A Needs You ask widens the inbox, a trailing tool just after the panel toggle (its place since 2026-10-21):
            // the toggle gives it room; the quick actions and "..." never move.
            const panel = !name.split("+").includes("needsYou") && name !== "all";
            const want = place(base!, panel);
            const got = place(layout, panel);
            if (JSON.stringify(got) !== JSON.stringify(want))
              moved.push(`${name}: ${JSON.stringify(got)} vs ${JSON.stringify(want)}`);
          }
          console.log(
            `chat-header-slots ${mode} ${split} ${width}px: ${moved.length} of ${at.size - 1} combinations moved the tools`,
          );
          expect(moved).toEqual([]);
        });
    });
  }
});
