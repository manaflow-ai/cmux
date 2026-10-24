// l10n-allow-file: test fixture prompts, replies and tool names, not shipped UI.
// Sources' + in the chat's summary offers Use tools (cx-thur3): the chat's tools as acpmux
// reports them (`tools`, `toolsMutable` on its session), on or off for this chat only:
// - a submenu lists them grouped, cmux's own first, then MCP servers, plugins and skills; each is a
//   check row with its source; a row acpmux cannot change is shown disabled; a long list has a
//   search field;
// - a toggle sends `_acpmux/set_tools {sessionId, id, enabled}`, and the row says when it applies
//   (After this turn, Next time the chat starts); a refusal puts the row back and says why;
// - a chat whose tools are fixed (`toolsMutable: false`), or that has none, has no Use tools: the +
//   attaches files as before.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-use-tools.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-use-tools: skipping (run `bunx playwright install chromium`)");
    describe.skip("use tools", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e3";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Tidy the release notes" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The notes are tidy." } },
        },
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  type Tool = { id: string; name: string; kind: string; source: string; enabled: boolean; canToggle: boolean };
  const row = (id: string, kind: string, source: string, canToggle = true): Tool => ({
    id,
    name: id.split(":").at(-1)!,
    kind,
    source,
    enabled: true,
    canToggle,
  });
  // Not in the page's order: the page groups them, cmux's own first.
  const fixture = (): Tool[] => [
    row("mcp:github", "mcp", "claude"),
    row("mcp:linear", "mcp", "claude"),
    row("mcp:sentry", "mcp", "claude"),
    row("mcp:figma", "mcp", "claude"),
    row("skill:review", "skill", "claude", false),
    row("plugin:superpowers", "plugin", "claude", false),
    row("mcp:cmux", "cmux", "cmux"),
    row("mcp:cmux-cua", "cmux", "cmux"),
    row("skill:cmux:cmux-browser", "cmux", "cmux", false),
    row("skill:release", "skill", "claude", false),
  ];
  let tools = fixture();
  let toolsMutable = true;
  /// The next `_acpmux/set_tools` answer: when it applies, or acpmux's refusal.
  let reply: { applied: string } | { error: { code: number; message: string; data: { reason: string } } } = {
    applied: "afterTurn",
  };
  const sets: unknown[] = [];
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/notes",
    title: "Release notes",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    tools,
    toolsMutable,
  });

  function answer(method: string, params: Record<string, unknown> | undefined): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return {
          result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
        };
      case "_acpmux/watch":
        return { result: { sessions: [session()] } };
      case "_acpmux/attach":
        return { result: { session: session(), lastSeq: events.length, events } };
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: events.length } };
      case "_acpmux/set_tools": {
        sets.push(params);
        if ("error" in reply) return { error: reply.error };
        tools = tools.map((tool) => (tool.id === params?.id ? { ...tool, enabled: params?.enabled === true } : tool));
        return { result: { sessionId: CHAT, tools, toolsMutable, applied: reply.applied } };
      }
      default:
        return { result: null };
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, message.params) }));
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the tests time only the menu.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("The notes are tidy.").waitFor({ timeout: 25_000 });
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

  const open = async () => {
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await page.goto(url());
    await page.getByText("The notes are tidy.").waitFor();
    // A chat with no summary content keeps the card closed until the header's button opens it. At
    // this width the card is a popover: a press or Escape in its menus must not close it.
    await page.getByRole("button", { name: "Chat summary" }).click();
    await page.getByRole("complementary", { name: "Chat summary" }).waitFor({ timeout: 5_000 });
    return { context, page };
  };
  const add = (page: Page) => page.getByRole("button", { name: "Add sources" });
  /// Sources' + menu, then its Use tools submenu.
  const useTools = async (page: Page) => {
    await add(page).click({ timeout: 5_000 });
    await page.getByRole("menuitem", { name: "Use tools" }).click();
    await page.locator(".acpmux-tools-menu").waitFor({ timeout: 5_000 });
  };
  /// A tool's check row, by its name (the row's first text).
  const check = (page: Page, name: string) =>
    page.locator(".acpmux-tools-menu [role=menuitemcheckbox]").filter({
      has: page.locator(".acpmux-tools-name", { hasText: new RegExp(`^${name}$`) }),
    });
  const checked = (page: Page, name: string) => check(page, name).getAttribute("aria-checked");

  test("Use tools lists the chat's tools grouped, cmux's own first, fixed ones disabled", async () => {
    tools = fixture();
    toolsMutable = true;
    const { context, page } = await open();
    // The + keeps Attach files or folders beside Use tools.
    await add(page).click({ timeout: 5_000 });
    await page.getByRole("menuitem", { name: "Attach files or folders" }).waitFor({ timeout: 5_000 });
    await page.keyboard.press("Escape");
    // Escape closed the + menu only: the summary popover stays.
    await page.getByRole("complementary", { name: "Chat summary" }).waitFor({ timeout: 5_000 });
    await useTools(page);
    const groups = await page.locator(".acpmux-tools-menu [role=group]").evaluateAll((nodes) =>
      nodes.map((node) => ({
        label: node.querySelector(".ui-menu-group-label")?.textContent,
        rows: [...node.querySelectorAll(".acpmux-tools-name")].map((name) => name.textContent),
      })),
    );
    expect(groups).toEqual([
      { label: "cmux", rows: ["cmux", "cmux-cua", "cmux-browser"] },
      { label: "MCP servers", rows: ["github", "linear", "sentry", "figma"] },
      { label: "Plugins", rows: ["superpowers"] },
      { label: "Skills", rows: ["review", "release"] },
    ]);
    expect(await checked(page, "github")).toBe("true");
    // Its source as secondary text.
    expect(await check(page, "github").locator(".acpmux-tools-source").textContent()).toBe("Claude Code");
    expect(await check(page, "superpowers").getAttribute("aria-disabled")).toBe("true");
    expect(await check(page, "cmux-browser").getAttribute("aria-disabled")).toBe("true");
    expect(await check(page, "cmux-cua").getAttribute("aria-disabled")).toBeNull();
    // Ten rows: a search field narrows them.
    await page.getByRole("searchbox", { name: "Search tools" }).fill("lin");
    expect(await page.locator(".acpmux-tools-menu .acpmux-tools-name").allTextContents()).toEqual(["linear"]);
    await context.close();
  });

  test("a toggle sends _acpmux/set_tools and says when it applies", async () => {
    tools = fixture();
    toolsMutable = true;
    const { context, page } = await open();
    await useTools(page);
    sets.length = 0;
    reply = { applied: "afterTurn" };
    await check(page, "github").click();
    await check(page, "github").getByText("After this turn").waitFor({ timeout: 5_000 });
    expect(sets).toEqual([{ sessionId: CHAT, id: "mcp:github", enabled: false }]);
    expect(await checked(page, "github")).toBe("false");
    reply = { applied: "nextStart" };
    await check(page, "linear").click();
    await check(page, "linear").getByText("Next time the chat starts").waitFor({ timeout: 5_000 });
    expect(sets.at(-1)).toEqual({ sessionId: CHAT, id: "mcp:linear", enabled: false });
    expect(await checked(page, "linear")).toBe("false");
    // Applied now: the row needs no note.
    reply = { applied: "now" };
    await check(page, "github").click();
    // The row is disabled while acpmux answers; enabled and checked again, the answer is in.
    await check(page, "github")
      .and(page.locator('[aria-checked="true"]:not([aria-disabled="true"])'))
      .waitFor({ timeout: 5_000 });
    expect(sets.at(-1)).toEqual({ sessionId: CHAT, id: "mcp:github", enabled: true });
    expect(await checked(page, "github")).toBe("true");
    expect(await check(page, "github").locator(".acpmux-tools-note").count()).toBe(0);
    await context.close();
  });

  test("a refused toggle puts the row back and says why", async () => {
    tools = fixture();
    toolsMutable = true;
    const { context, page } = await open();
    await useTools(page);
    sets.length = 0;
    reply = {
      error: {
        code: -32000,
        message: "github cannot be turned on or off in this chat",
        data: { reason: "tools.fixed" },
      },
    };
    await check(page, "github").click();
    await check(page, "github").getByText("Can't be changed in this chat").waitFor({ timeout: 5_000 });
    expect(sets).toEqual([{ sessionId: CHAT, id: "mcp:github", enabled: false }]);
    expect(await checked(page, "github")).toBe("true");
    await context.close();
    reply = { applied: "afterTurn" };
  });

  test("a chat whose tools are fixed has no Use tools: the + attaches files", async () => {
    tools = fixture();
    toolsMutable = false;
    const { context, page } = await open();
    await page.getByRole("button", { name: "Attach files or folders" }).waitFor({ timeout: 5_000 });
    expect(await add(page).count()).toBe(0);
    expect(await page.getByRole("menuitem", { name: "Use tools" }).count()).toBe(0);
    await context.close();
    toolsMutable = true;
  });

  test("a chat without tools has no Use tools", async () => {
    tools = [];
    toolsMutable = true;
    const { context, page } = await open();
    await page.getByRole("button", { name: "Attach files or folders" }).waitFor({ timeout: 5_000 });
    expect(await add(page).count()).toBe(0);
    await context.close();
    tools = fixture();
  });
});
