// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// The permission mode menu's number keys (cx-ncc.83, Claude parity): while the menu is open, 1 to 9
// pick the mode in that place, each row shows its number, and the pick goes to acpmux as
// `session/set_mode`. The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-mode-keys.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-mode-keys: skipping (run `bunx playwright install chromium`)");
    describe.skip("mode keys", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000d1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Add retry to the uploader" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Retry added.")],
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
    cwd: "/home/dev/uploader",
    title: "Uploader retry",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    modes: {
      currentModeId: "default",
      // As acpmux reports a Claude chat (claude_stdio MODES): Claude Code's own five.
      availableModes: [
        { id: "auto", name: "Auto", description: "Claude handles permission decisions" },
        { id: "default", name: "Manual", description: "Always ask before making changes" },
        { id: "acceptEdits", name: "Accept edits", description: "Automatically accept all file edits" },
        { id: "plan", name: "Plan", description: "Create a plan before making changes" },
        { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
      ],
    },
  };
  const calls: { method: string; params: Record<string, any> }[] = [];
  const sockets = new Set<{ send(text: string): void }>();
  /// When set, the stand-in acpmux takes `session/set_mode` and tells the pane the new mode.
  let followModes = false;

  /// Resolves once `ready()` holds after a call; checked on every call the stand-in takes.
  const waiters = new Set<() => void>();
  const until = (ready: () => boolean) =>
    new Promise<void>((resolve, reject) => {
      if (ready()) return resolve();
      const timer = setTimeout(() => {
        waiters.delete(check);
        reject(new Error(`timed out: ${JSON.stringify(calls.map((call) => call.method))}`));
      }, 10_000);
      const check = () => {
        if (!ready()) return;
        clearTimeout(timer);
        waiters.delete(check);
        resolve();
      };
      waiters.add(check);
    });

  function answer(method: string, params: Record<string, any>): unknown {
    calls.push({ method, params });
    queueMicrotask(() => waiters.forEach((check) => check()));
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "session/set_mode":
        if (followModes) {
          session.modes = { ...session.modes, currentModeId: String(params.modeId) };
          const text = JSON.stringify({
            jsonrpc: "2.0",
            method: "_acpmux/session_changed",
            params: { sessionId: CHAT, session, kind: "mode" },
          });
          setTimeout(() => sockets.forEach((socket) => socket.send(text)), 0);
        }
        return {};
      default:
        return null;
    }
  }
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
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
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the menu.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Retry added.").waitFor({ timeout: 25_000 });
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

  test("number keys pick a mode while the menu is open", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url(CHAT));
    await page.getByText("Retry added.").waitFor();
    await page.locator(".acpmux-access-trigger").click();
    const menu = page.locator(".acpmux-access-menu");
    await menu.waitFor();
    // Claude Code's Mode menu: its five modes, Plan among them, numbered in its order.
    const rows = await menu
      .locator(".acpmux-access-item")
      .evaluateAll((items) =>
        items.map((item) => [
          item.querySelector(".acpmux-menu-label")?.textContent,
          item.querySelector(".ui-menu-shortcut")?.textContent,
        ]),
      );
    expect(rows).toEqual([
      ["Auto", "1"],
      ["Manual", "2"],
      ["Accept edits", "3"],
      ["Plan", "4"],
      ["Bypass permissions", "5"],
    ]);
    await page.keyboard.press("3");
    await page.waitForFunction(() => document.querySelector(".acpmux-access-menu") === null, undefined, {
      timeout: 5_000,
    });
    expect(calls.filter((call) => call.method === "session/set_mode").map((call) => call.params.modeId)).toEqual([
      "acceptEdits",
    ]);
    // A number with no mode in its place does nothing.
    await page.locator(".acpmux-access-trigger").click();
    await menu.waitFor();
    await page.keyboard.press("7");
    // The page has taken the key once a frame after it has painted.
    await page.evaluate(() => window.cmuxPaintFrame());
    // The current mode's number closes the menu without sending it again.
    expect(await menu.isVisible()).toBe(true);
    await page.keyboard.press("3");
    await page.waitForFunction(() => document.querySelector(".acpmux-access-menu") === null, undefined, {
      timeout: 5_000,
    });
    expect(calls.filter((call) => call.method === "session/set_mode")).toHaveLength(1);
    await page.close();
  });

  test("the trigger draws the mode's own shield; Claude Code's menu rows draw none", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added.").waitFor();
    const trigger = () =>
      page.locator(".acpmux-access-trigger [data-shield]").evaluate((node) => node.getAttribute("data-shield"));
    // The chat starts in Claude's default mode: it asks first, so the shield carries a check.
    expect(await trigger()).toBe("check");
    expect(await page.locator(".acpmux-access-trigger svg[data-shield]").count()).toBe(1);
    await page.locator(".acpmux-access-trigger").click();
    const menu = page.locator(".acpmux-access-menu");
    await menu.waitFor();
    const rows = await menu
      .locator(".acpmux-access-item")
      .evaluateAll((items) =>
        items.map((item) => [
          item.querySelector(".acpmux-menu-label")?.textContent,
          item.querySelector("[data-shield]")?.getAttribute("data-shield"),
        ]),
      );
    // As Claude Code's own Mode menu: the name and description, no icon column.
    expect(rows).toEqual([
      ["Auto", undefined],
      ["Manual", undefined],
      ["Accept edits", undefined],
      ["Plan", undefined],
      ["Bypass permissions", undefined],
    ]);
    // Picking full access puts the warning shield on the trigger.
    await page.keyboard.press("5");
    await page.waitForFunction(() => document.querySelector(".acpmux-access-menu") === null, undefined, {
      timeout: 5_000,
    });
    await page.waitForFunction(
      () => document.querySelector(".acpmux-access-trigger [data-shield]")?.getAttribute("data-shield") === "alert",
      undefined,
      { timeout: 5_000 },
    );
    // The shield draws like the lock it replaced: in the trigger's own ink
    // and at its own size, never styled as the trailing chevron. The plain
    // footer (the default, #22050) hides the lock beside a shown label, so
    // the host's `composer` event turns that look off to draw it.
    await page.evaluate(() =>
      (window as unknown as { cmuxAcpmuxComposer?: (value: unknown) => void }).cmuxAcpmuxComposer?.({
        plainFooter: false,
      }),
    );
    await page.waitForFunction(() => !document.querySelector('[data-footer-look="plain"]'), undefined, {
      timeout: 5_000,
    });
    const look = await page.locator(".acpmux-access-trigger").evaluate((button) => {
      // The drawn glyph: the svg that carries data-shield, or the one inside it.
      const marked = button.querySelector("[data-shield]")!;
      const shield = marked.matches("svg") ? marked : marked.querySelector("svg")!;
      const chevron = button.lastElementChild!;
      return {
        shieldColor: getComputedStyle(shield).color,
        buttonColor: getComputedStyle(button).color,
        shieldWidth: shield.getBoundingClientRect().width,
        chevronWidth: chevron.getBoundingClientRect().width,
      };
    });
    expect(look.shieldColor).toBe(look.buttonColor);
    expect(look.shieldWidth).toBeGreaterThan(look.chevronWidth);
    await page.close();
  });
  test("/plan toggles Plan and, leaving it, returns to the mode the chat had before", async () => {
    const before = session.modes.currentModeId;
    session.modes = { ...session.modes, currentModeId: "acceptEdits" };
    followModes = true;
    calls.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      await page.goto(url(CHAT));
      await page.getByText("Retry added.").waitFor();
      const modesSent = () =>
        calls.filter((call) => call.method === "session/set_mode").map((call) => call.params.modeId);
      const slashPlan = async () => {
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("/plan");
        await page.keyboard.press("Enter");
      };
      await slashPlan();
      await until(() => modesSent().length >= 1);
      expect(modesSent()).toEqual(["plan"]);
      // The pane has heard the chat is in Plan before the second /plan.
      await page.waitForFunction(
        () => document.querySelector(".acpmux-access")?.getAttribute("data-fit-title") === "Plan",
        undefined,
        { timeout: 5_000 },
      );
      await slashPlan();
      await until(() => modesSent().length >= 2);
      // Not the first non-plan mode (Auto): the Accept edits it left.
      expect(modesSent()).toEqual(["plan", "acceptEdits"]);
      // Neither /plan went to the agent as a prompt.
      expect(calls.filter((call) => call.method === "session/prompt")).toHaveLength(0);
    } finally {
      await page.close();
      followModes = false;
      session.modes = { ...session.modes, currentModeId: before };
    }
  });
});
