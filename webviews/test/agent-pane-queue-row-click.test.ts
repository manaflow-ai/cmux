// l10n-allow-file: test fixture prompts, not shipped UI.
// A queued prompt's buttons, clicked as a person clicks them (Leo on nightly 331e2e9, 2026-10-21:
// "WHY CAN'T I CLICK THESE BUTTONS"). Each action is pressed by real pointer events at the point
// where it draws on screen, never element.click(): the pointer rests on the row, the action shows,
// `document.elementFromPoint` at its centre is the action itself (nothing covers it), and the
// press and release there do what it says:
//
// - Steer asks acpmux to send the prompt now (`_acpmux/queue_edit` op send_now);
// - the trash can withdraws it (`_acpmux/queue_remove`) and the row leaves;
// - ⋯ opens the row's menu, and its Edit message opens the prompt's text for editing in place.
//
// The row rests as one muted line, as ChatGPT's and Codex's queues do: no "Queued / Sends after
// this turn" header and no number, and the actions show only while the pointer is on the row or
// focus is in it (keyboard reach), not at rest.
//
// The page is the pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking
// JSON-RPC over a WebSocket to a stand-in acpmux (agent-pane-queue-steer.test.ts's): a turn still
// writing its reply, with two prompts queued behind it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-queue-row-click.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-queue-row-click: skipping (run `bunx playwright install chromium webkit`)");
    describe.skip("queued row clicks", () => test("chromium and webkit", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 13, 18, 50, 0);
  const LONG =
    "the pr thing blocks + the lower area being colored like that looks weird :( and the scrolling/streaming " +
    "text looks off when it reaches the bottom, also check that the queued prompts show in full when I open " +
    "them because right now I can only read the first line of what I asked";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string, messageId: string) =>
    update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// The recorded chat up to the moment the page opens: the turn opened a pull request and is
  /// writing its reply (message m1); two prompts wait behind it.
  const opening: Step[] = [
    ["mux", "user_message", { text: "Open the PR for the remapped cwd fix", promptId: "p-turn", turnId: "turn-1" }],
    ["mux", "turn_started", { turnId: "turn-1" }],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "gh pr create",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: 'gh pr create --title "Adopt a moved Claude chat" --body x' },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "https://github.com/acme/cmux/pull/20308\n" } }],
        rawOutput: { exit_code: 0 },
      }),
    ],
    ["in", "agent_message_chunk", say("Opened #20308. Now checking the ", "m1")],
    ["mux", "queued", { text: LONG, promptId: "q-1", turnId: "turn-2", position: 1 }],
    ["mux", "queued", { text: "also man what happened with the space thing", promptId: "q-2", turnId: "turn-3" }],
  ];
  /// acpmux's mux records in the `transcript` kind (paging.rs `TRANSCRIPT_MUX_KINDS`).
  const TRANSCRIPT_MUX_KINDS = new Set([
    "user_message",
    "queued",
    "dequeued",
    "queue_removed",
    "prompt_retracted",
    "turn_started",
    "turn_result",
    "permission_request",
    "permission_auto",
    "permission_decision",
    "permission_group",
    "permission_chat_allowance",
    "message_superseded",
    "failover",
    "forked",
    "imported",
    "session_offer",
    "session_offer_decision",
    "mode",
    "model",
    "stopped",
    "exited",
  ]);
  /// acpmux's `EventFilter::matches`: a category or an exact record kind; none passes everything.
  let kinds: string[] | undefined;
  const passes = (rec: { dir: string; kind: string }) =>
    !kinds ||
    kinds.some(
      (kind) =>
        kind === "all" ||
        (kind === "transcript" && (rec.dir === "in" || TRANSCRIPT_MUX_KINDS.has(rec.kind))) ||
        (kind === "mux" && rec.dir === "mux") ||
        kind === rec.kind,
    );
  let steering = true;
  /// What the page asked acpmux to do to its queue.
  const calls: { method: string; params: { promptId?: string; op?: string } }[] = [];
  let heard: { method: string; resolve(): void }[] = [];
  const hear = (method: string, params: unknown) => {
    calls.push({ method, params: params as never });
    heard = heard.filter((waiter) => (waiter.method === method ? (waiter.resolve(), false) : true));
  };
  let seq = 0;
  let history: Record<string, unknown>[] = [];
  let queue: { promptId: string; prompt: string }[] = [];
  const record = ([dir, kind, msg]: Step) => ({
    sessionId: SESSION,
    seq: ++seq,
    at: START + seq * 1000,
    dir,
    kind,
    msg,
  });
  /// acpmux lists a queued prompt's preview: its first 200 characters on one line.
  const preview = (text: string) => {
    const line = text.split(/\s+/).filter(Boolean).join(" ");
    return line.length > 200 ? `${line.slice(0, 200)}…` : line;
  };
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/cmux",
    title: "Open the PR for the remapped cwd fix",
    harness: "claude",
    status: "running",
    steering,
    queued: queue.length,
    queue: queue.map((q) => ({ promptId: q.promptId, prompt: preview(q.prompt) })),
    turn: { turnId: "turn-1", promptId: "p-turn", startedAt: START },
    updatedAt: START,
    // The access chip lists the agent's modes (acpmux's claude_stdio MODES).
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Manual", description: "Always ask before making changes" },
        { id: "acceptEdits", name: "Accept edits", description: "Automatically accept all file edits" },
        { id: "plan", name: "Plan", description: "Create a plan before making changes" },
      ],
    },
  });

  type Socket = { send(data: string): void };
  let socket: Socket | undefined;
  const send = (step: Step) => {
    const rec = record(step);
    history.push(rec);
    if (step[0] === "mux") {
      if (step[1] === "queued") queue.push({ promptId: String(step[2].promptId), prompt: String(step[2].text) });
      if (step[1] === "dequeued") queue = queue.filter((q) => q.promptId !== step[2].promptId);
    }
    if (passes(rec)) socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
  };
  function answer(ws: Socket, method: string, params: { kinds?: string[]; promptId?: string } = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        socket = ws;
        kinds = params.kinds;
        return { session: summary(), lastSeq: seq, events: history.filter((rec) => passes(rec as never)) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      case "_acpmux/queue_edit":
        hear(method, params);
        // The test checks only what the page asked acpmux for.
        return { ok: true };
      case "_acpmux/queue_remove":
        hear(method, params);
        send(["mux", "queue_removed", { promptId: params.promptId, _meta: { acpmux: { withdrawn: true } } }]);
        return { removed: true };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let wkBrowser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { kinds?: string[] } };
          const result = answer(ws, message.method, message.params);
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    wkBrowser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await wkBrowser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(
    agentSteers: boolean,
    viewport = { width: 900, height: 760 },
    more: Step[] = [],
    engine: "chromium" | "webkit" = "chromium",
  ): Promise<Page> {
    steering = agentSteers;
    seq = 0;
    history = [];
    queue = [];
    socket = undefined;
    kinds = undefined;
    for (const step of [...opening, ...more]) send(step);
    const page = await (engine === "webkit" ? wkBrowser! : browser!).newPage({ viewport });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // A cold dev server's first load can stall in CI: the first page waits longer.
    await page.locator(".acpmux-queued", { hasText: "space thing" }).waitFor({ timeout: 60_000 });
    await installPaintedFrames(page);
    return page;
  }
  /// Streams `text` onto the reply (message m1) and waits for it to draw: the page has handled
  /// every record sent before it.
  const caughtUp = async (page: Page, text: string) => {
    send(["in", "agent_message_chunk", say(text, "m1")]);
    await page.locator(".acpmux-scroll", { hasText: text }).waitFor({ timeout: 10_000 });
  };

  /// The centre of `selector`'s box and what the page hits there.
  const hitAt = async (page: Page, selector: string) => {
    const box = await page.locator(selector).boundingBox();
    if (!box) throw new Error(`${selector} draws nowhere`);
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    const covered = await page.evaluate(
      ([sel, px, py]) => {
        const target = document.querySelector(sel as string);
        const hit = document.elementFromPoint(px as number, py as number);
        return target && hit && (target === hit || target.contains(hit))
          ? null
          : (hit?.outerHTML.slice(0, 160) ?? "nothing");
      },
      [selector, x, y] as const,
    );
    return { x, y, covered };
  };
  /// A real press and release at the action's on-screen centre, the pointer coming from the row.
  const press = async (page: Page, selector: string) => {
    const { x, y, covered } = await hitAt(page, selector);
    expect(covered).toBeNull();
    await page.mouse.move(x, y, { steps: 4 });
    await page.mouse.down();
    await page.mouse.up();
  };
  const opacity = (page: Page, selector: string) =>
    page.locator(selector).evaluate((el) => Number(getComputedStyle(el).opacity));
  /// Rests the pointer on the row's text, away from its actions.
  const hoverRow = async (page: Page, row: string) => {
    const box = await page.locator(`${row} .acpmux-queued-text`).boundingBox();
    await page.mouse.move(box!.x + 12, box!.y + box!.height / 2, { steps: 4 });
    await page.waitForFunction(
      (sel) => Number(getComputedStyle(document.querySelector(sel)!).opacity) === 1,
      `${row} .acpmux-queued-actions`,
    );
  };
  /// The stand-in acpmux's next `method` request from the page.
  const sent = (method: string) =>
    new Promise<void>((resolve) => {
      if (calls.some((call) => call.method === method)) resolve();
      else heard.push({ method, resolve });
    });
  const ROW = '.acpmux-queued[data-prompt-id="q-2"]';

  for (const engine of ["chromium", "webkit"] as const) {
    describe(`queued row (${engine})`, () => {
      test("rests as one muted line: no header, no number, actions hidden until the row is hovered or focused", async () => {
        const page = await openChat(true, undefined, [], engine);
        await caughtUp(page, "the cwd fix.");
        // The pointer starts off the queue.
        await page.mouse.move(4, 4);
        expect(await page.locator(".acpmux-queue-header").count()).toBe(0);
        expect(await page.locator(".acpmux-queued-mark").count()).toBe(0);
        expect(await page.locator(".acpmux-composer-queue").getAttribute("aria-label")).toBe("Queued prompts (2)");
        const text = page.locator(`${ROW} .acpmux-queued-text`);
        const line = await text.evaluate((el) => {
          const clamp = el.querySelector(".acpmux-queued-clamp") as HTMLElement;
          const style = getComputedStyle(clamp);
          return { nowrap: style.whiteSpace, overflow: style.textOverflow, height: el.getBoundingClientRect().height };
        });
        expect(line.nowrap).toBe("nowrap");
        expect(line.overflow).toBe("ellipsis");
        expect(await opacity(page, `${ROW} .acpmux-queued-actions`)).toBe(0);
        await hoverRow(page, ROW);
        expect(await opacity(page, `${ROW} .acpmux-queued-actions`)).toBe(1);
        // Focus in the row shows them too, with the pointer elsewhere.
        await page.mouse.move(4, 4);
        await page.waitForFunction(
          (sel) => Number(getComputedStyle(document.querySelector(sel)!).opacity) === 0,
          `${ROW} .acpmux-queued-actions`,
        );
        await page.locator(ROW).focus();
        expect(await opacity(page, `${ROW} .acpmux-queued-actions`)).toBe(1);
        await page.close();
      });

      test("Steer, pressed where it draws, sends the prompt now", async () => {
        const page = await openChat(true, undefined, [], engine);
        await caughtUp(page, "the cwd fix.");
        calls.length = 0;
        await hoverRow(page, ROW);
        await press(page, `${ROW} [data-action="steer"]`);
        await sent("_acpmux/queue_edit");
        expect(calls.filter((call) => call.method === "_acpmux/queue_edit").map((call) => call.params)).toEqual([
          expect.objectContaining({ promptId: "q-2", op: "send_now" }),
        ]);
        await page.close();
      });

      test("the trash can, pressed where it draws, withdraws the prompt and its row leaves", async () => {
        const page = await openChat(true, undefined, [], engine);
        await caughtUp(page, "the cwd fix.");
        calls.length = 0;
        await hoverRow(page, ROW);
        await press(page, `${ROW} [data-action="delete"]`);
        await page.locator(ROW).waitFor({ state: "detached", timeout: 5_000 });
        expect(
          calls.filter((call) => call.method === "_acpmux/queue_remove").map((call) => call.params.promptId),
        ).toEqual(["q-2"]);
        await page.close();
      });

      test("⋯, pressed where it draws, opens the row's menu, and Edit message opens the prompt in place", async () => {
        const page = await openChat(true, undefined, [], engine);
        await caughtUp(page, "the cwd fix.");
        await hoverRow(page, ROW);
        await press(page, `${ROW} [data-menu="queued-more"]`);
        const edit = page.getByRole("menuitem", { name: /Edit message/ });
        await edit.waitFor({ timeout: 5_000 });
        // The menu stays open past the press (a menu that closes a frame later reads as a dead click).
        await page.evaluate(async () => {
          for (let frame = 0; frame < 3; frame++) await window.cmuxPaintFrame();
        });
        expect(await edit.isVisible()).toBe(true);
        await press(page, ".acpmux-queued-more [role=menuitem]:first-child");
        const field = page.locator(`${ROW} .acpmux-queued-edit`);
        await field.waitFor({ timeout: 5_000 });
        expect(await field.inputValue()).toBe("also man what happened with the space thing");
        await page.close();
      });
    });
  }

  // With a composer chip's menu open, one press on a queued row's control both closes the menu and
  // does what the control says (the dead click on nightly 331e2e9: menuPressGuard.ts swallowed every
  // press outside the open menu that was not on a menu button, so Steer and the trash can only closed
  // the chip). The chips are the access (Mode) menu and the model menu; each action is pressed only
  // where the open menu leaves it uncovered (the model menu's Effort row sits over Steer, and the
  // context card over all three, so a press there is the menu's own).
  const CHIPS = {
    access: 'button[aria-haspopup][aria-label="Mode"]',
    model: 'button[aria-haspopup][aria-label="Model"]',
  } as const;
  const chipOpen = (page: Page, chip: string) =>
    page
      .locator(chip)
      .evaluate((button) => button.getAttribute("aria-expanded") === "true" || button.hasAttribute("data-popup-open"));
  /// Opens `chip`'s menu with a real press. The pointer then goes straight to the action, as a
  /// person's does: the access menu opens over the row's text, so the row's hover comes from the
  /// action itself.
  const openChip = async (page: Page, chip: string) => {
    await press(page, chip);
    await page.waitForFunction(
      (sel) => {
        const button = document.querySelector(sel)!;
        return button.getAttribute("aria-expanded") === "true" || button.hasAttribute("data-popup-open");
      },
      chip,
      { timeout: 5_000 },
    );
  };
  const chipClosed = (page: Page, chip: string) =>
    page.waitForFunction(
      (sel) => {
        const button = document.querySelector(sel)!;
        return button.getAttribute("aria-expanded") !== "true" && !button.hasAttribute("data-popup-open");
      },
      chip,
      { timeout: 5_000 },
    );
  const ACTIONS = {
    steer: async (page: Page) => {
      await press(page, `${ROW} [data-action="steer"]`);
      await sent("_acpmux/queue_edit");
      expect(calls.filter((call) => call.method === "_acpmux/queue_edit").map((call) => call.params)).toEqual([
        expect.objectContaining({ promptId: "q-2", op: "send_now" }),
      ]);
    },
    trash: async (page: Page) => {
      await press(page, `${ROW} [data-action="delete"]`);
      await page.locator(ROW).waitFor({ state: "detached", timeout: 5_000 });
      expect(
        calls.filter((call) => call.method === "_acpmux/queue_remove").map((call) => call.params.promptId),
      ).toEqual(["q-2"]);
    },
    more: async (page: Page) => {
      await press(page, `${ROW} [data-menu="queued-more"]`);
      await page.getByRole("menuitem", { name: /Edit message/ }).waitFor({ timeout: 5_000 });
    },
  } as const;
  const OPEN_CHIP_CASES: [keyof typeof CHIPS, keyof typeof ACTIONS][] = [
    ["access", "steer"],
    ["access", "trash"],
    ["access", "more"],
    // The model chip opens the combined picker, 480px wide and centred on the chip (#25796,
    // #26071), so it covers all three actions, as the context card does: see the test below.
  ];
  for (const engine of ["chromium", "webkit"] as const) {
    describe(`queued row with a chip's menu open (${engine})`, () => {
      for (const [chip, action] of OPEN_CHIP_CASES)
        test(`one press on ${action} closes the ${chip} menu and does what it says`, async () => {
          const page = await openChat(true, undefined, [], engine);
          await caughtUp(page, "the cwd fix.");
          calls.length = 0;
          await openChip(page, CHIPS[chip]);
          await ACTIONS[action](page);
          await chipClosed(page, CHIPS[chip]);
          expect(await chipOpen(page, CHIPS[chip])).toBe(false);
          await page.close();
        });
      // The model picker lies over every one of the row's actions, so a press where ⋯ draws is the
      // picker's own: it must not reach the row (no row menu, no queue edit or removal).
      test("the model picker covers the row's actions, and a press there stays in the picker", async () => {
        const page = await openChat(true, undefined, [], engine);
        await caughtUp(page, "the cwd fix.");
        calls.length = 0;
        await openChip(page, CHIPS.model);
        for (const action of ['[data-action="steer"]', '[data-action="delete"]', '[data-menu="queued-more"]']) {
          const { covered } = await hitAt(page, `${ROW} ${action}`);
          expect({ action, inPicker: covered !== null && /acpmux-quick|role="menu/.test(covered) }).toEqual({
            action,
            inPicker: true,
          });
        }
        const { x, y } = await hitAt(page, `${ROW} [data-menu="queued-more"]`);
        await page.mouse.move(x, y, { steps: 4 });
        await page.mouse.down();
        await page.mouse.up();
        // Two painted frames: a press that reached the row has opened its menu and sent its edit.
        for (let frame = 0; frame < 2; frame++)
          await page.evaluate(() => (window as unknown as { cmuxPaintFrame(): Promise<number> }).cmuxPaintFrame());
        expect({
          rowMenu: await page.getByRole("menuitem", { name: /Edit message/ }).count(),
          queueCalls: calls.filter((call) => call.method.startsWith("_acpmux/queue")).length,
        }).toEqual({ rowMenu: 0, queueCalls: 0 });
        await page.close();
      });
    });
  }
});
