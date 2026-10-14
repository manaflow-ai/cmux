// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The chat's summary is a pinned card under its header button, as in the ChatGPT desktop app (Leo
// 2026-10-14, "you guys misunderstood"):
// - shown from the start; a click in the transcript or the composer leaves it; only its button,
//   its close button or Escape closes it; its first row opens a terminal or a browser beside the chat;
// - a wide pane makes room: the chat and its composer end left of the card; a narrow pane lays the
//   card over the transcript and the chat keeps its width; resizing moves the chat, not the card;
// - closing it is one choice, kept for the next page, until the header's summary button opens it;
// - the chat menu offers New terminal and New browser beside New side chat, and all of it fits a
//   window with room for it.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-summary-panel.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-summary-panel: skipping (run `bunx playwright install chromium`)");
    describe.skip("summary panel", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e2";
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
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/notes",
    title: "Release notes",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
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

  const open = async (page: Page) => {
    await page.goto(url());
    await page.getByText("The notes are tidy.").waitFor();
  };
  const panel = (page: Page) => page.getByRole("complementary", { name: "Chat summary" });
  const box = async (page: Page, selector: string) =>
    (await page.locator(selector).first().boundingBox()) ?? { x: 0, y: 0, width: 0, height: 0 };

  // The chat's column: the composer's card, which the transcript's column matches.
  const column = (page: Page) => box(page, ".acpmux-composer-box");
  // Lets the chat column's move (a short transition) finish.
  const settle = (page: Page) => page.waitForTimeout(400);

  test("a wide pane pins the summary under its button and the chat makes room beside it", async () => {
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).waitFor({ timeout: 5_000 });
    await settle(page);
    const card = await box(page, ".acpmux-summary-card");
    const button = await box(page, ".acpmux-summary-button");
    // A card under the button at the pane's right edge, not a full-height column.
    expect(card.y).toBeGreaterThanOrEqual(button.y + button.height);
    expect(1280 - (card.x + card.width)).toBeLessThan(24);
    expect(card.height).toBeLessThan(800 - 60);
    // The chat ends left of it.
    const chat = await column(page);
    expect(chat.x + chat.width).toBeLessThanOrEqual(card.x);
    await page.getByText("The notes are tidy.").click();
    await page.locator(".acpmux-composer").click();
    expect(await panel(page).isVisible()).toBe(true);
    // New terminal and New browser lead it, as buttons with their names written out.
    for (const name of ["New terminal", "New browser"]) {
      const button = panel(page).getByRole("button", { name });
      expect(await button.isVisible()).toBe(true);
      expect((await button.boundingBox())?.height ?? 0).toBeGreaterThanOrEqual(28);
    }
    await context.close();
  });

  test("the chat menu offers New terminal and New browser beside New side chat", async () => {
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await page.getByRole("button", { name: "Chat actions" }).click();
    const items = page.getByRole("menuitem");
    await items.first().waitFor({ timeout: 5_000 });
    const names = (await items.allInnerTexts()).map((text) => text.split("\n")[0]!.trim());
    const at = names.indexOf("New terminal");
    expect(at).toBeGreaterThan(-1);
    expect(names[at + 1]).toBe("New browser");
    await context.close();
  });

  test("the chat menu shows its last group without scrolling when the window has room", async () => {
    // A short window: the menu is taller than 70% of it, and the window still holds all of it.
    const context = await browser!.newContext({ viewport: { width: 1280, height: 640 } });
    const page = await context.newPage();
    await open(page);
    await page.getByRole("button", { name: "Chat actions" }).click();
    const items = page.getByRole("menuitem");
    await items.first().waitFor({ timeout: 5_000 });
    const popup = await box(page, ".acpmux-chat-menu-popover");
    const last = (await items.last().boundingBox()) ?? { y: 0, height: 0 };
    expect(last.y + last.height).toBeLessThanOrEqual(popup.y + popup.height);
    // A taller menu than 70% of the window, so the check is a real one.
    expect(popup.height).toBeGreaterThan(640 * 0.7);
    await context.close();
  });

  test("hiding the docked summary is kept until the summary button shows it again", async () => {
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).getByRole("button", { name: "Close summary" }).click();
    await panel(page).waitFor({ state: "detached", timeout: 5_000 });
    await open(page);
    await page.waitForTimeout(500);
    expect(await panel(page).count()).toBe(0);
    await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ timeout: 5_000 });
    await open(page);
    await panel(page).waitFor({ timeout: 5_000 });
    await context.close();
  });

  test("a narrow pane lays the card over the chat, and only Escape or its button closes it", async () => {
    const context = await browser!.newContext({ viewport: { width: 760, height: 800 } });
    const page = await context.newPage();
    await open(page);
    // A pane that starts narrow starts with it closed: it would cover the transcript's right side.
    await page.waitForTimeout(300);
    expect(await panel(page).count()).toBe(0);
    await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ timeout: 5_000 });
    await settle(page);
    // Over the chat's column, which keeps the pane's width.
    const card = await box(page, ".acpmux-summary-card");
    const chat = await column(page);
    expect(card.width).toBeLessThan(760 / 2);
    expect(chat.x + chat.width).toBeGreaterThan(card.x);
    // A click in the transcript or the composer leaves it.
    await page.getByText("The notes are tidy.").click();
    await page.locator(".acpmux-composer").click();
    await page.waitForTimeout(300);
    expect(await panel(page).isVisible()).toBe(true);
    await page.keyboard.press("Escape");
    await panel(page).waitFor({ state: "detached", timeout: 5_000 });
    await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ timeout: 5_000 });
    await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ state: "detached", timeout: 5_000 });
    // Opened again for the next test's page: closing is kept.
    await page.getByRole("button", { name: "Chat summary" }).click();
    await panel(page).waitFor({ timeout: 5_000 });
    await context.close();
  });

  test("resizing moves the chat, not the card: room beside it when wide, over it when narrow", async () => {
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await panel(page).waitFor({ timeout: 5_000 });
    await settle(page);
    const wide = await box(page, ".acpmux-summary-card");
    expect((await column(page)).x + (await column(page)).width).toBeLessThanOrEqual(wide.x);
    await page.setViewportSize({ width: 760, height: 800 });
    await settle(page);
    // Still open, at the same place from the pane's right edge and top.
    const narrow = await box(page, ".acpmux-summary-card");
    expect(await panel(page).isVisible()).toBe(true);
    expect(Math.abs(760 - (narrow.x + narrow.width) - (1280 - (wide.x + wide.width)))).toBeLessThan(2);
    expect(Math.abs(narrow.y - wide.y)).toBeLessThan(2);
    const chat = await column(page);
    expect(chat.x + chat.width).toBeGreaterThan(narrow.x);
    await page.setViewportSize({ width: 1280, height: 800 });
    await settle(page);
    const back = await box(page, ".acpmux-summary-card");
    expect((await column(page)).x + (await column(page)).width).toBeLessThanOrEqual(back.x);
    await context.close();
  });
});
