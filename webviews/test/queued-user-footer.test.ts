// l10n-allow-file: synthetic prompts and replies used by a behavioral regression.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { agentPaneTheme } from "../src/gallery/theme/web";
import { deriveTokens, GHOSTTY_DEFAULT, rgbHex } from "../src/gallery/theme/tokens";
import { gridLength } from "../src/agent-session/acpmux/transcriptGrid";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("queued-user-footer.test.ts", async () => {
  setDefaultTimeout(90_000);
  const { createServer } = await import("vite");
  const SESSION = "0190a000-0000-7000-8000-0000000000f1";
  const PROMPT = "p-waiting-footer";
  const TEXT = "Please use the cache directory";
  const WRAPPING_TEXT = "Keep the queued prompt in the same place when it sends. ".repeat(8).trim();
  const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
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
  const opening = (text = TEXT, withAttachment = false) => {
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
      record("user_message", {
        text,
        promptId: PROMPT,
        turnId: "turn-1",
        steer: true,
        ...(withAttachment
          ? {
              images: [{ id: "queued-image", mimeType: "image/png", name: "queued.png", width: 1, height: 1 }],
              inlineParts: [
                { kind: "text", text },
                { kind: "image", id: "queued-image", mimeType: "image/png", name: "queued.png" },
              ],
            }
          : {}),
      }),
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
        if (params.op === "withdraw" && accept) event("steer_withdrawn", { promptId: PROMPT, turnId: "turn-1" });
        return { ok: accept, sent: accept ? "now" : null };
      case "_acpmux/attachment":
        return { mimeType: "image/png", data: PNG };
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
  const waitForFooter = (page: Page) =>
    page.waitForFunction(() => {
      const actions = [...document.querySelectorAll(".cv-user__actions")].at(-1);
      return actions && getComputedStyle(actions).opacity === "1";
    });
  const open = async (text = TEXT, withAttachment = false) => {
    calls.length = 0;
    accept = true;
    hold = false;
    resolveEdit = undefined;
    history = opening(text, withAttachment);
    const context = await browser.newContext({
      viewport: { width: 880, height: 650 },
    });
    const page = await context.newPage();
    await page.clock.setFixedTime(start + 120_000);
    const address = vite.httpServer!.address() as { port: number };
    const endpoint = encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`);
    await page.goto(`http://127.0.0.1:${address.port}/#endpoint=${endpoint}&token=t&session=${SESSION}`);
    await page.locator(".cv-user__bubble", { hasText: text }).waitFor();
    await page.locator(".cv-user__bubble", { hasText: text }).hover();
    await waitForFooter(page);
    return page;
  };
  const footer = (page: Page) => page.locator(".cv-user", { has: page.locator(".cv-user__bubble", { hasText: TEXT }) });
  const capture = async (page: Page, name: string) => {
    const evidence = process.env.CMUX_QUEUE_FOOTER_EVIDENCE;
    if (evidence) {
      await page.locator(".cv-user__bubble", { hasText: TEXT }).hover();
      await waitForFooter(page);
      await page.screenshot({ path: path.join(evidence, `${name}.png`) });
    }
  };
  for (const width of [880, 360]) {
    for (const [length, text] of [
      ["short", "helo"],
      ["wrapping", WRAPPING_TEXT],
    ] as const) {
      for (const dark of [true, false]) {
        const themeName = dark ? "dark" : "light";
        test(`queued and sent bubble and footer keep their position at ${width}px, ${length}, ${themeName}`, async () => {
          const page = await open(text);
          try {
            await page.setViewportSize({ width, height: 650 });
            const theme = agentPaneTheme(
              deriveTokens({
                ...GHOSTTY_DEFAULT,
                background: rgbHex(dark ? 0x1e1e1e : 0xffffff),
                foreground: rgbHex(dark ? 0xe5e5e5 : 0x1c1c1c),
              }),
              true,
            );
            await page.evaluate((theme) => window.cmuxAcpmuxBridge!.applyTheme(theme), theme);
            const row = page.locator(".cv-user", { has: page.locator(".cv-user__pending") });
            const stableRow = page.locator(".cv-user", { has: page.locator(".cv-user__bubble", { hasText: text }) });
            const bubble = row.locator(".cv-user__bubble");
            await bubble.hover();
            await waitForFooter(page);
            const measure = () =>
              stableRow.evaluate((element) => {
                const bubble = element.querySelector(".cv-user__bubble")!.getBoundingClientRect();
                const footer = element.querySelector(".cv-user__actions")!.getBoundingClientRect();
                const row = element.getBoundingClientRect();
                return {
                  bubbleLeft: bubble.left,
                  bubbleRight: bubble.right,
                  bubbleWidth: bubble.width,
                  footerTop: footer.top,
                  footerRight: footer.right,
                  footerGap: footer.top - bubble.bottom,
                  footerHeight: footer.height,
                  rowRight: row.right,
                };
              });
            const evidence = process.env.CMUX_QUEUE_FOOTER_EVIDENCE;
            const stem = `${width}-${length}-${themeName}`;
            const before = await measure();
            if (evidence) await page.screenshot({ path: path.join(evidence, `${stem}-queued.png`) });
            await row.locator(".cv-user__send-now").click();
            await stableRow.locator(".cv-user__pending").waitFor({ state: "detached" });
            await stableRow.locator(".cv-user__bubble").hover();
            await waitForFooter(page);
            const after = await measure();
            if (evidence) await page.screenshot({ path: path.join(evidence, `${stem}-sent.png`) });
            console.log("QUEUE_FOOTER_GEOMETRY", JSON.stringify({ width, length, themeName, before, after }));
            expect(before.footerGap).toBeGreaterThanOrEqual(0);
            expect(Math.abs(before.bubbleRight - before.rowRight)).toBeLessThanOrEqual(1);
            // The row's 28 controls overhang the bubble's edge by their glyph inset, so their glyphs
            // end on it (design/grid.md 5.5).
            const overhang = (gridLength("transcript-action-control") - gridLength("transcript-icon-box")) / 2;
            expect(Math.abs(before.footerRight - overhang - before.bubbleRight)).toBeLessThanOrEqual(1);
            for (const key of [
              "bubbleLeft",
              "bubbleRight",
              "bubbleWidth",
              "footerTop",
              "footerRight",
              "footerGap",
              "footerHeight",
            ] as const)
              expect(Math.abs(after[key] - before[key])).toBeLessThanOrEqual(1);
          } finally {
            await page.context().close();
          }
        });
      }
    }
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
  test("an unread steer keeps queue controls and Copy; Send now reaches its prompt and accepted delivery shows hover actions", async () => {
    const page = await open();
    try {
      const row = footer(page);
      await capture(page, "unread");
      expect(await row.locator(".cv-user__send-now").count()).toBe(1);
      expect(await row.locator(".cv-user__take-back").count()).toBe(1);
      expect(await row.locator(".cv-user__read, .cv-user__dot, .cv-user__time, .cv-message-retry").count()).toBe(0);
      expect(await row.getByRole("button", { name: "Copy", exact: true }).count()).toBe(1);
      const before = await row.evaluate((element) => {
        const bubble = element.querySelector(".cv-user__bubble")!.getBoundingClientRect();
        const footer = element.querySelector(".cv-user__actions")!.getBoundingClientRect();
        return { left: bubble.left, right: bubble.right, footerRight: footer.right };
      });
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
      const after = await row.evaluate((element) => {
        const bubble = element.querySelector(".cv-user__bubble")!.getBoundingClientRect();
        const footer = element.querySelector(".cv-user__actions")!.getBoundingClientRect();
        return { left: bubble.left, right: bubble.right, footerRight: footer.right };
      });
      expect(Math.abs(after.left - before.left)).toBeLessThanOrEqual(1);
      expect(Math.abs(after.right - before.right)).toBeLessThanOrEqual(1);
      expect(Math.abs(after.footerRight - before.footerRight)).toBeLessThanOrEqual(1);
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
  test("taking a waiting steer back restores its draft and image attachment", async () => {
    const page = await open(TEXT, true);
    try {
      const row = footer(page);
      await row.locator(".cv-user__take-back").click();
      await page.waitForFunction((text) => {
        const field = document.querySelector<HTMLElement>(".acpmux-md-field");
        return field?.textContent?.includes(text) === true;
      }, TEXT);
      const restoredImage = page.locator('.acpmux-composer img[alt="queued.png"]');
      await restoredImage.waitFor();
      await page.waitForFunction(
        () =>
          (document.querySelector<HTMLImageElement>('.acpmux-composer img[alt="queued.png"]')?.naturalWidth ?? 0) > 0,
      );
      expect(await restoredImage.count()).toBe(1);
      expect(await restoredImage.evaluate((image: HTMLImageElement) => image.naturalWidth)).toBeGreaterThan(0);
      expect(calls.some((call) => call.method === "_acpmux/attachment" && call.params.id === "queued-image")).toBe(
        true,
      );
      expect(calls.filter((call) => call.method === "_acpmux/queue_edit")).toEqual([
        { method: "_acpmux/queue_edit", params: { sessionId: SESSION, promptId: PROMPT, op: "withdraw" } },
      ]);
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
