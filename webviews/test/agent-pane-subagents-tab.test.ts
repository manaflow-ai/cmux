// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The summary card's Subagents tab (cx-x62ev, after the ChatGPT desktop app's right pane): the
// Subagents section's title opens a "Subagents" tab beside the card's Summary tab, listing the
// chat's subagents under "Active · N" and "Done · N" with the transcript's own subagent row
// (subagents/SubagentGroup.tsx SubagentListRow); a row shows that subagent, and the tab's close
// button goes back to the summary.
// A running subagent's Stop goes by the chat's summary (`backgroundsWork`: acpmux runs it as Claude
// Code, which stops its own agents), not the harness's name: the model router's `cmux` chat has it,
// an ACP agent a user's config named `claude-acp` has none.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-subagents-tab.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-subagents-tab: skipping (run `bunx playwright install chromium`)");
    describe.skip("subagents tab", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e3";
  const ROUTER = "0190a000-0000-7000-8000-0000000000e4";
  const CLAUDE_ACP = "0190a000-0000-7000-8000-0000000000e5";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Tidy the release notes" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "subagent_spawned",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "subagent_spawned" },
          _meta: {
            acpmux: {
              subagents: [
                { id: "sub-explore", name: "Explore docs", task: "Read the release docs", state: "running" },
                { id: "sub-links", name: "Check links", task: "Check every link", state: "running" },
                { id: "sub-lint", name: "Lint notes", task: "Lint the notes", state: "running" },
              ],
            },
          },
        },
      },
    ],
    [
      "in",
      "subagent_state_update",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "subagent_state_update" },
          _meta: {
            acpmux: {
              subagents: [
                { id: "sub-links", state: "completed" },
                { id: "sub-lint", state: "failed" },
              ],
            },
          },
        },
      },
    ],
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
  const eventsOf = (sessionId: string) =>
    steps.map(([dir, kind, msg], index) => ({
      sessionId,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
  /// Each chat's harness and whether acpmux runs it as Claude Code (`backgroundsWork`).
  const chats: Record<string, { harness: string; claudeCode: boolean }> = {
    [CHAT]: { harness: "claude", claudeCode: true },
    // The model router's profile: Claude Code under acpmux, named `cmux`.
    [ROUTER]: { harness: "cmux", claudeCode: true },
    // A user's config named an ACP agent after Claude: acpmux cannot stop its subagents.
    [CLAUDE_ACP]: { harness: "claude-acp", claudeCode: false },
  };
  const sessionOf = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/notes",
    title: "Release notes",
    harness: chats[sessionId]!.harness,
    family: chats[sessionId]!.harness,
    backgroundsWork: chats[sessionId]!.claudeCode,
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  });

  function answer(method: string, params: Record<string, unknown> | undefined): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: Object.keys(chats).map(sessionOf) };
      case "_acpmux/attach": {
        const id = String(params?.sessionId);
        const events = eventsOf(id);
        return { session: sessionOf(id), lastSeq: events.length, events };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: steps.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session = CHAT) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
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
    // again if it stalls, so the tests time only the panel.
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

  // 1600px leaves the default chat width room for the inline summary column (summary/cardState.ts);
  // narrower, the card is a popover behind the header's summary button.
  const open = async (page: Page, session = CHAT) => {
    await page.goto(url(session));
    await page.getByText("The notes are tidy.").waitFor();
  };
  const panel = (page: Page) => page.getByRole("complementary", { name: "Chat summary" });

  test("the Subagents title opens a tab of active and done subagents, and its rows open them", async () => {
    const context = await browser!.newContext({ viewport: { width: 1600, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).waitFor({ timeout: 5_000 });
    // The section's title, with its live count, opens the tab.
    await panel(page).getByRole("heading", { name: "Subagents · 1 running" }).waitFor({ timeout: 5_000 });
    await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
    const tabs = panel(page).locator(".acpmux-summary-tabs");
    const tab = (name: string) => tabs.getByRole("button", { name, exact: true });
    await tabs.waitFor({ timeout: 5_000 });
    expect(await tab("Subagents").getAttribute("aria-pressed")).toBe("true");
    expect(await tab("Summary").getAttribute("aria-pressed")).toBe("false");
    // The tabs take the head's row: its counts (the tab lists them) leave room for them.
    expect(await panel(page).locator(".acpmux-summary-card__counts").count()).toBe(0);
    // Its own list in the card's place: no summary sections under it (the summary's Subagents
    // section is the one this chat has; an empty section is not drawn).
    expect(await panel(page).getByRole("region", { name: "Subagents", exact: true }).count()).toBe(0);
    const active = panel(page).getByRole("region", { name: "Active · 1" });
    const done = panel(page).getByRole("region", { name: "Done · 2" });
    await active.waitFor({ timeout: 5_000 });
    expect(await active.getByRole("button", { name: "Open Explore docs" }).count()).toBe(1);
    expect(await done.getByRole("button", { name: "Open Check links" }).count()).toBe(1);
    expect(await done.getByRole("button", { name: "Open Lint notes" }).count()).toBe(1);
    // The transcript's subagent row, avatar and all, not a second kind of row.
    expect(await active.locator(".cv-subagent .cv-subagent-avatar").count()).toBe(1);
    // Compact rows.
    const row = (await active.getByRole("button", { name: "Open Explore docs" }).boundingBox())?.height ?? 0;
    expect(row).toBeGreaterThan(0);
    expect(row).toBeLessThanOrEqual(40);
    // A row shows that subagent (here, where the browser host opens no pane of its own).
    await active.getByRole("button", { name: "Open Explore docs" }).click();
    await page.getByText("Subagent of").waitFor({ timeout: 5_000 });
    // The tab's close button goes back to the summary.
    await panel(page).getByRole("button", { name: "Close Subagents" }).click();
    await panel(page).getByRole("region", { name: "Subagents", exact: true }).waitFor({ timeout: 5_000 });
    expect(await tabs.count()).toBe(0);
    await context.close();
  });

  test("the Summary tab goes back without closing the Subagents tab", async () => {
    const context = await browser!.newContext({ viewport: { width: 1600, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).waitFor({ timeout: 5_000 });
    await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
    const tab = (name: string) =>
      panel(page).locator(".acpmux-summary-tabs").getByRole("button", { name, exact: true });
    await tab("Summary").click();
    await panel(page).getByRole("region", { name: "Subagents", exact: true }).waitFor({ timeout: 5_000 });
    expect(await tab("Summary").getAttribute("aria-pressed")).toBe("true");
    await tab("Subagents").click();
    await panel(page).getByRole("region", { name: "Active · 1" }).waitFor({ timeout: 5_000 });
    await context.close();
  });

  test("a running subagent in the tab has the transcript row's stop button", async () => {
    const context = await browser!.newContext({ viewport: { width: 1600, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
    const active = panel(page).getByRole("region", { name: "Active · 1" });
    await active.waitFor({ timeout: 5_000 });
    // Claude's subagents stop on their own (acpmux `_acpmux/subagent_stop`), so its running row can.
    await active.getByRole("button", { name: "Stop Explore docs" }).waitFor({ timeout: 5_000 });
    // A subagent that ended has none.
    const done = panel(page).getByRole("region", { name: "Done · 2" });
    expect(await done.getByRole("button", { name: /^Stop / }).count()).toBe(0);
    await context.close();
  });

  for (const [name, session, stops] of [
    ["the model router's chat, Claude Code named `cmux`, has", ROUTER, true],
    ["an ACP agent named claude-acp has no", CLAUDE_ACP, false],
  ] as const) {
    test(`${name} stop button on a running subagent`, async () => {
      const context = await browser!.newContext({ viewport: { width: 1600, height: 800 } });
      const page = await context.newPage();
      await open(page, session);
      await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
      const active = panel(page).getByRole("region", { name: "Active · 1" });
      await active.getByRole("button", { name: "Open Explore docs" }).waitFor({ timeout: 5_000 });
      expect(await active.getByRole("button", { name: "Stop Explore docs" }).count()).toBe(stops ? 1 : 0);
      await context.close();
    });
  }

  // Narrow: the card is a popover behind the header's summary button.
  const openPopoverTab = async (page: Page) => {
    await open(page);
    await page.click(".acpmux-summary-button");
    await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
    await panel(page).locator(".acpmux-summary-tabs").waitFor({ timeout: 5_000 });
  };

  test("closing the Subagents tab of a folded popover focuses its fold button", async () => {
    const context = await browser!.newContext({ viewport: { width: 900, height: 800 } });
    const page = await context.newPage();
    await openPopoverTab(page);
    const fold = panel(page).getByRole("button", { name: "Collapse summary" });
    // Folded, the Subagents title that opened the tab is gone: closing the tab focuses the fold button.
    await fold.click();
    await panel(page).getByRole("button", { name: "Close Subagents" }).click();
    await page.waitForFunction(() => document.activeElement?.classList.contains("acpmux-summary-card__fold"), null, {
      timeout: 5_000,
    });
    await context.close();
  });

  test("a tab picked on a folded popover unfolds it to that tab", async () => {
    const context = await browser!.newContext({ viewport: { width: 900, height: 800 } });
    const page = await context.newPage();
    await openPopoverTab(page);
    const tab = (name: string) =>
      panel(page).locator(".acpmux-summary-tabs").getByRole("button", { name, exact: true });
    await panel(page).getByRole("button", { name: "Collapse summary" }).click();
    await panel(page).getByRole("button", { name: "Expand summary" }).waitFor({ timeout: 5_000 });
    expect(await panel(page).getByRole("region", { name: "Active · 1" }).count()).toBe(0);
    // The Summary tab shows the summary, not a folded header.
    await tab("Summary").click();
    await panel(page).getByRole("region", { name: "Subagents", exact: true }).waitFor({ timeout: 5_000 });
    expect(await tab("Summary").getAttribute("aria-pressed")).toBe("true");
    // Folded again, the Subagents tab shows its list.
    await panel(page).getByRole("button", { name: "Collapse summary" }).click();
    await panel(page).getByRole("button", { name: "Expand summary" }).waitFor({ timeout: 5_000 });
    await tab("Subagents").click();
    await panel(page).getByRole("region", { name: "Active · 1" }).waitFor({ timeout: 5_000 });
    expect(await tab("Subagents").getAttribute("aria-pressed")).toBe("true");
    await context.close();
  });

  test("a popover keeps a compact fold button beside its tabs", async () => {
    // 1280px: no room for the inline column, so the summary is a popover.
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    if (!(await panel(page).isVisible())) await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ timeout: 5_000 });
    expect(await panel(page).getAttribute("data-placement")).toBe("popover");
    await panel(page).getByRole("button", { name: "Subagents · 1 running" }).click();
    const tabs = panel(page).locator(".acpmux-summary-tabs");
    await tabs.waitFor({ timeout: 5_000 });
    const fold = panel(page).getByRole("button", { name: "Collapse summary" });
    const foldBox = await fold.boundingBox();
    const tabsBox = await tabs.boundingBox();
    // An icon-sized control right before the tabs, not a bar spanning the empty head.
    expect(foldBox!.width).toBeLessThanOrEqual(32);
    expect(tabsBox!.x).toBeGreaterThanOrEqual(foldBox!.x + foldBox!.width);
    expect(tabsBox!.x - (foldBox!.x + foldBox!.width)).toBeLessThanOrEqual(8);
    await context.close();
  });
});
