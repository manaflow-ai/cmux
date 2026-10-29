// l10n-allow-file: synthetic prompts and replies used by a behavioral regression.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { agentPaneTheme } from "../src/gallery/theme/web";
import { deriveTokens, GHOSTTY_DEFAULT, rgbHex } from "../src/gallery/theme/tokens";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("queued-user-footer.test.ts", async () => {
  setDefaultTimeout(90_000);
  const { createServer } = await import("vite");
  const SESSION = "0190a000-0000-7000-8000-0000000000f1";
  const PROMPT = "p-waiting-footer";
  const TEXT = "Please use the cache directory";
  const start = Date.UTC(2026, 9, 26, 20);
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  let seq = 0;
  let socket: { send(data: string): void } | undefined;
  let accept = true;
  let resolveEdit: ((value: unknown) => void) | undefined;
  let hold = false;
  const record = (kind: string, msg: unknown, dir = "mux") => ({
    sessionId: SESSION,
    seq: ++seq,
    at: start + seq,
    dir,
    kind,
    msg,
  });
  const event = (kind: string, msg: unknown, dir = "mux") =>
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(kind, msg, dir) }));
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/cmux",
    title: "Queue footer",
    harness: "claude-sr2",
    family: "claude-sr2",
    backgroundsWork: true,
    steering: true,
    status: "running",
    queued: 0,
    queue: [],
    turn: { turnId: "turn-1", promptId: "p-turn", startedAt: start },
    updatedAt: start,
  });
  const opening = (text = TEXT) => {
    seq = 0;
    return [
      record("user_message", { text: "Check the cache", promptId: "p-turn", turnId: "turn-1" }),
      record("turn_started", { turnId: "turn-1" }),
      record(
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: {
              sessionUpdate: "agent_message_chunk",
              messageId: "m1",
              content: { type: "text", text: "Checking the cache." },
            },
          },
        },
        "in",
      ),
      record("user_message", { text, promptId: PROMPT, turnId: "turn-1", steer: true }),
    ];
  };
  let history = opening();
  const answer = async (method: string, params: Record<string, unknown>) => {
    calls.push({ method, params });
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: seq, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      case "_acpmux/queue_edit":
        if (hold)
          return new Promise((resolve) => {
            resolveEdit = resolve;
          });
        return { ok: accept, sent: accept ? "now" : null };
      default:
        return null;
    }
  };
  let daemon: ReturnType<typeof Bun.serve>;
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        async message(ws, raw) {
          socket = ws;
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          const result = await answer(message.method, message.params ?? {});
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        },
      },
    });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });
  const open = async (text = TEXT) => {
    calls.length = 0;
    accept = true;
    hold = false;
    resolveEdit = undefined;
    history = opening(text);
    const evidence = process.env.CMUX_QUEUE_FOOTER_EVIDENCE;
    const context = await browser.newContext({
      viewport: { width: 880, height: 650 },
      ...(evidence ? { recordVideo: { dir: evidence, size: { width: 880, height: 650 } } } : {}),
    });
    const page = await context.newPage();
    const address = vite.httpServer!.address() as { port: number };
    const endpoint = encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`);
    await page.goto(`http://127.0.0.1:${address.port}/#endpoint=${endpoint}&token=t&session=${SESSION}`);
    await page.locator(".cv-user__bubble", { hasText: text }).waitFor();
    await page.locator(".cv-user__bubble", { hasText: text }).hover();
    await page.waitForFunction(() => {
      const actions = [...document.querySelectorAll(".cv-user__actions")].at(-1);
      return actions && getComputedStyle(actions).opacity === "1";
    });
    return page;
  };
  const footer = (page: Page) => page.locator(".cv-user", { has: page.locator(".cv-user__bubble", { hasText: TEXT }) });
  const capture = async (page: Page, name: string) => {
    const evidence = process.env.CMUX_QUEUE_FOOTER_EVIDENCE;
    if (evidence) {
      await page.locator(".cv-user__bubble", { hasText: TEXT }).hover();
      await page.waitForFunction(() => {
        const actions = [...document.querySelectorAll(".cv-user__actions")].at(-1);
        return actions && getComputedStyle(actions).opacity === "1";
      });
      await page.screenshot({ path: path.join(evidence, `${name}.png`) });
    }
  };
  for (const width of [880, 360]) {
    test(`waiting steer actions stay beside a short bubble at ${width}px`, async () => {
      const page = await open("helo");
      try {
        await page.setViewportSize({ width, height: 650 });
        const row = page.locator(".cv-user", { has: page.locator(".cv-user__pending") });
        const bubble = row.locator(".cv-user__bubble");
        await bubble.hover();
        const evidence = process.env.CMUX_QUEUE_FOOTER_EVIDENCE;
        if (evidence) {
          for (const isDark of [true, false]) {
            const theme = agentPaneTheme(
              deriveTokens({
                ...GHOSTTY_DEFAULT,
                background: rgbHex(isDark ? 0x1e1e1e : 0xffffff),
                foreground: rgbHex(isDark ? 0xe5e5e5 : 0x1c1c1c),
              }),
              true,
            );
            await page.evaluate((theme) => window.cmuxAcpmuxBridge!.applyTheme(theme), theme);
            await page.screenshot({
              path: path.join(evidence, `attached-${width}-${isDark ? "dark" : "light"}.png`),
            });
          }
        }
        const geometry = await row.evaluate((element) => {
          const bubble = element.querySelector(".cv-user__bubble")!.getBoundingClientRect();
          const actions = element.querySelector(".cv-user__pending")!.getBoundingClientRect();
          const buttons = [...element.querySelectorAll(".cv-user__pending button")].map((button) =>
            button.getBoundingClientRect(),
          );
          return {
            gap: actions.left - bubble.right,
            centerOffset: Math.abs((actions.top + actions.bottom - bubble.top - bubble.bottom) / 2),
            overflow: actions.right - element.getBoundingClientRect().right,
            controlGap: buttons[1]!.left - buttons[0]!.right,
          };
        });
        expect(geometry.gap).toBeGreaterThanOrEqual(4);
        expect(geometry.gap).toBeLessThanOrEqual(8);
        expect(geometry.centerOffset).toBeLessThanOrEqual(1);
        expect(geometry.overflow).toBeLessThanOrEqual(1);
        expect(geometry.controlGap).toBeGreaterThanOrEqual(4);
      } finally {
        await page.context().close();
      }
    });
  }
  test("a waiting steer's Copy writes its text without sending or withdrawing the steer", async () => {
    const page = await open();
    try {
      await page.context().grantPermissions(["clipboard-read", "clipboard-write"]);
      const row = footer(page);
      expect(await row.getByRole("button", { name: "Copy", exact: true }).count()).toBe(1);
      await row.getByRole("button", { name: "Copy", exact: true }).click();
      await row.getByRole("button", { name: "Copied", exact: true }).waitFor();
      expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(TEXT);
      expect(
        calls.filter((call) => call.method === "_acpmux/queue_edit" || call.method === "_acpmux/steer_withdraw"),
      ).toHaveLength(0);
      expect(await row.locator(".cv-user__send-now").count()).toBe(1);
      expect(await row.locator(".cv-user__take-back").count()).toBe(1);
      expect(await row.locator(".cv-user__time, .cv-user__read, .cv-user__dot, .cv-message-retry").count()).toBe(0);
    } finally {
      await page.context().close();
    }
  });
  test("an unread steer shows only queue controls; pointer Send now reaches its prompt and accepted delivery shows only hover actions", async () => {
    const page = await open();
    try {
      const row = footer(page);
      await capture(page, "unread");
      expect(await row.locator(".cv-user__send-now").count()).toBe(1);
      expect(await row.locator(".cv-user__take-back").count()).toBe(1);
      expect(
        await row
          .locator(".cv-user__read, .cv-user__dot, .cv-user__time, button[aria-label='Copy'], .cv-message-retry")
          .count(),
      ).toBe(0);
      hold = true;
      await row.locator(".cv-user__send-now").click();
      await page.waitForFunction(
        () => document.querySelector<HTMLButtonElement>(".cv-user__send-now")?.disabled === true,
      );
      expect(calls.filter((call) => call.method === "_acpmux/queue_edit")).toEqual([
        {
          method: "_acpmux/queue_edit",
          params: { sessionId: SESSION, promptId: PROMPT, op: "send_now" },
        },
      ]);
      expect(await row.locator(".cv-user__pending").count()).toBe(1);
      resolveEdit!({ ok: true, sent: "now" });
      await row.locator(".cv-user__pending").waitFor({ state: "detached" });
      expect(await row.locator(".cv-user__time").count()).toBe(1);
      expect(await row.getByRole("button", { name: "Copy", exact: true }).count()).toBe(1);
      expect(await row.locator(".cv-user__read, .cv-user__dot").count()).toBe(0);
      await capture(page, "accepted");
      // The daemon still reports waiting until its next agent message: controls stay gone.
      event(
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: {
              sessionUpdate: "agent_message_chunk",
              messageId: "m2",
              content: { type: "text", text: "Using the cache directory." },
            },
          },
        },
        "in",
      );
      await page.getByText("Using the cache directory.", { exact: true }).waitFor();
      expect(await row.locator(".cv-user__pending").count()).toBe(0);
      await capture(page, "read");
    } finally {
      await page.context().close();
    }
  });
  test("a refused Send now keeps queue controls and permits a real retry", async () => {
    const page = await open();
    try {
      accept = false;
      const row = footer(page);
      await row.locator(".cv-user__send-now").click();
      await page.waitForFunction(
        () => document.querySelector<HTMLButtonElement>(".cv-user__send-now")?.disabled === false,
      );
      expect(await row.locator(".cv-user__pending").count()).toBe(1);
      expect(await row.locator(".cv-user__time, .cv-user__read, .cv-user__dot").count()).toBe(0);
      accept = true;
      await row.locator(".cv-user__send-now").click();
      await row.locator(".cv-user__pending").waitFor({ state: "detached" });
      expect(calls.filter((call) => call.method === "_acpmux/queue_edit")).toHaveLength(2);
    } finally {
      await page.context().close();
    }
  });
});
