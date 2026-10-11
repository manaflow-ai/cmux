// Agent history (cx-zlnl, Leo 2026-10-10): the page the sidebar's History dot opens, in the real
// agent pane (vite.config.acpmux-pane.mjs) as the host opens it (handshake `newTab.history`).
// The host's bridge methods are stubbed on `window.cmuxAcpmuxActions`: `chats.page` answers one
// page of the device's chat index and `chats.open` records what the page asked to open.
//
// - The page is titled History and lists every chat the index pages, newest first.
// - A plain click opens that chat; Cmd-click toggles rows into a selection and Shift-click
//   selects the range from the last clicked row.
// - Right-click > Bring into active sessions opens every selected chat; Enter does too.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-history.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-history: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent history", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const shots = process.env.CMUX_HISTORY_SHOTS;

  /// Five chats, newest first, as `chats.page` answers them.
  const chats = ["Fix the build", "Port the sidebar", "Review the docs", "Profile startup", "Trim the bundle"].map(
    (title, index) => ({
      key: `claude-code:s${index + 1}`,
      harness: "claude-code",
      title,
      cwd: "/Users/dev/code/cmux",
      updatedAt: Date.now() - (index + 1) * 3_600_000,
    }),
  );

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function openHistory(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(
      ({ rows }) => {
        const opened: string[] = [];
        // The host's side of the bridge (AgentPaneRequest): one page of the index, and Open Chat.
        const host = (method: string, params: Record<string, unknown>) => {
          if (method === "chats.page") return { chats: rows, ready: true };
          if (method === "chats.open") opened.push(String(params.key));
          return null;
        };
        Object.assign(window, {
          openedChats: opened,
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: async ({ method, params }: { method: string; params: Record<string, unknown> }) => ({
                  ok: true,
                  value: host(method, params),
                }),
              },
            },
          },
          cmuxAcpmuxActions: {
            ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab: { history: true } }),
          },
        });
      },
      { rows: chats },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page
      .locator(".nt-all-row")
      .nth(chats.length - 1)
      .waitFor();
    return page;
  }

  const opened = (page: Page) =>
    page.evaluate(() => (window as unknown as { openedChats: string[] }).openedChats.splice(0));
  const selected = (page: Page) =>
    page.locator(".nt-all-row[data-selected] .nt-all-title").evaluateAll((rows) => rows.map((row) => row.textContent));
  const row = (page: Page, title: string) => page.locator(".nt-all-row", { hasText: title });

  describe("agent history", () => {
    test("lists every chat, multi-selects, and brings the selection into active sessions", async () => {
      const page = await openHistory();
      const title = await page.locator(".nt-history-title").textContent();
      const titles = await page
        .locator(".nt-all-row .nt-all-title")
        .evaluateAll((rows) => rows.map((r) => r.textContent));

      // A plain click opens that one chat and selects nothing.
      await row(page, "Fix the build").click();
      const plain = await opened(page);

      // Cmd-click toggles; Shift-click selects the range from the last clicked row.
      await row(page, "Port the sidebar").click({ modifiers: ["Meta"] });
      await row(page, "Review the docs").click({ modifiers: ["Meta"] });
      await row(page, "Port the sidebar").click({ modifiers: ["Meta"] });
      await row(page, "Trim the bundle").click({ modifiers: ["Shift"] });
      const range = await selected(page);
      const openedBySelecting = await opened(page);
      if (shots) await page.screenshot({ path: path.join(shots, "history-selected.png") });

      // Right-click a selected row: Bring into active sessions opens the whole selection.
      await row(page, "Profile startup").click({ button: "right" });
      const bring = page.getByRole("menuitem", { name: "Bring into active sessions" });
      await bring.waitFor();
      if (shots) await page.screenshot({ path: path.join(shots, "history-menu.png") });
      await bring.click();
      const brought = await opened(page);
      const afterBring = await selected(page);

      // Enter on a row opens the selection too.
      await row(page, "Fix the build").click({ modifiers: ["Meta"] });
      await row(page, "Port the sidebar").click({ modifiers: ["Meta"] });
      // WebKit leaves no row focused after a click; Enter still reaches the selection.
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press("Enter");
      const entered = await opened(page);

      expect({ title, titles, plain, range, openedBySelecting, brought, afterBring, entered }).toEqual({
        title: "History",
        titles: chats.map((chat) => chat.title),
        plain: ["claude-code:s1"],
        range: ["Port the sidebar", "Review the docs", "Profile startup", "Trim the bundle"],
        openedBySelecting: [],
        brought: ["claude-code:s2", "claude-code:s3", "claude-code:s4", "claude-code:s5"],
        afterBring: [],
        entered: ["claude-code:s1", "claude-code:s2"],
      });
      await page.close();
    });
  });
});
