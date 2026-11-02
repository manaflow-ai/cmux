// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The recap card in the real agent pane (Claude desktop parity, its 10-14 release): with the
// agent.sessionStatus Debug toggle on, a turn that completed by asking "Should I open a PR for
// this?" shows a card above the composer whose Yes, open PR sends that reply (a click, or ⌘Return
// on the empty composer), and whose Not now hides it for that turn, across a reload. With the
// toggle off nothing shows. The page is the pane's
// dev entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { restRoom } from "../src/agent-session/acpmux/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-recap-card.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-recap-card: skipping (run `bunx playwright install chromium`)");
    describe.skip("recap card", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const SUMMARY =
    "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass, including the new layout shift test.";
  const QUESTION = "Should I open a PR for this?";
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Fix the layout shift on the product grid" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say(`${SUMMARY}\n\n${QUESTION}`)],
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
    cwd: "/home/dev/shop",
    title: "Product grid layout shift",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  /// The text of each prompt the pane sent.
  const prompts: string[] = [];
  /// `_acpmux/events` reads: a lag resync's refetch.
  let eventReads = 0;
  /// The socket of the page that last spoke to the daemon.
  let socket: { send(data: string): void } | undefined;

  /// The waits on what the daemon heard: each message it takes wakes them.
  const waiting = new Set<() => void>();
  /// Resolves once `condition` holds, checked as the daemon hears each message; fails naming `what`.
  const until = (condition: () => boolean, what: string, timeout = 10_000) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!condition()) return;
        waiting.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        waiting.delete(check);
        reject(new Error(`the daemon never saw ${what} within ${timeout} ms`));
      }, timeout);
      waiting.add(check);
      check();
    });

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        eventReads += 1;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          socket = ws;
          // A prompt is recorded and left running: the card's part ends once it is sent.
          if (message.method === "session/prompt")
            prompts.push((message.params?.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join(""));
          else if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
          for (const wake of waiting) wake();
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The chat, its turn ended on the question; the toggle on unless `on` is false (the app's push).
  async function openChat(on = true): Promise<Page> {
    prompts.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.getByText(QUESTION).first().waitFor();
    await setSessionStatus(page, on);
    return page;
  }
  /// The in-session status toggle, as the app's `agent.sessionStatus` push sets it.
  const setSessionStatus = (page: Page, on = true) =>
    page.evaluate((value) => window.cmuxAcpmuxBridge?.applySessionStatus?.(value), on);
  const card = (page: Page) => page.locator(".acpmux-recap");
  /// Waits for the page to come to rest: its finite animations and transitions have finished, then
  /// two frames have painted, so what is read next is laid out as drawn.
  const atRest = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
  /// Returns once the page has answered a lag notice sent now (its refetch reached the daemon), so it
  /// has handled what came before, and a prompt it sent before has reached the daemon.
  async function settled(): Promise<void> {
    const before = eventReads;
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [CHAT] } }));
    await until(() => eventReads > before, "the lag resync's refetch");
  }
  /// Waits for the daemon to get a prompt, and for any second one to have come.
  async function sent(): Promise<void> {
    await until(() => prompts.length > 0, "a prompt");
    await settled();
  }

  test("a turn that ended on a question shows the card; its yes sends Yes, open PR", async () => {
    const page = await openChat();
    await card(page).waitFor();
    expect(await card(page).locator(".acpmux-recap__question").innerText()).toBe(QUESTION);
    expect(await card(page).locator(".acpmux-recap__summary").innerText()).toBe(SUMMARY);
    const yes = card(page).getByRole("button", { name: "Yes, open PR" });
    expect(await yes.getAttribute("aria-keyshortcuts")).toBe("Meta+Enter");
    await card(page).getByRole("button", { name: "Not now" }).waitFor();
    await card(page).getByRole("button", { name: "Dismiss" }).waitFor();
    await yes.click();
    await card(page).waitFor({ state: "detached" });
    await sent();
    expect(prompts).toEqual(["Yes, open PR"]);
    await page.close();
  });

  test("⌘Return on the empty composer answers the card", async () => {
    const page = await openChat();
    await card(page).waitFor();
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.press("Meta+Enter");
    await card(page).waitFor({ state: "detached" });
    await sent();
    expect(prompts).toEqual(["Yes, open PR"]);
    await page.close();
  });

  test("in shell mode ⌘Return sends no yes, and the card shows no ⌘Return key", async () => {
    const page = await openChat();
    await card(page).waitFor();
    const yes = card(page).getByRole("button", { name: "Yes, open PR" });
    expect(await yes.getAttribute("aria-keyshortcuts")).toBe("Meta+Enter");
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("!");
    await page.locator(".acpmux-shell-field").waitFor();
    expect(await yes.getAttribute("aria-keyshortcuts")).toBeNull();
    expect(await yes.locator(".acpmux-keycap").count()).toBe(0);
    await page.keyboard.press("Meta+Enter");
    await settled();
    expect(prompts).toEqual([]);
    expect(await card(page).count()).toBe(1);
    await page.close();
  });

  test("a yes that cannot be sent brings the card back with a note", async () => {
    const page = await openChat();
    await card(page).waitFor();
    // The host loses its send action: the yes has nowhere to go.
    await page.evaluate(() => {
      delete (window.cmuxAcpmuxActions as Record<string, unknown> | undefined)?.["chat.send"];
    });
    await card(page).getByRole("button", { name: "Yes, open PR" }).click();
    const note = card(page).getByRole("alert");
    await note.waitFor();
    expect(await note.innerText()).toBe("Your reply wasn’t sent. Try again.");
    expect(prompts).toEqual([]);
    await page.close();
  });

  test("Not now hides the card for the turn, across a reload, and sends nothing", async () => {
    const page = await openChat();
    await card(page).waitFor();
    await card(page).getByRole("button", { name: "Not now" }).click();
    await card(page).waitFor({ state: "detached" });
    // The keyboard is back in the composer.
    expect(await page.evaluate(() => Boolean(document.activeElement?.closest(".acpmux-composer")))).toBe(true);
    await page.reload();
    await page.getByText(QUESTION).first().waitFor();
    await setSessionStatus(page);
    // The page has drawn past the toggle's push when it answers a lag notice sent after it.
    await settled();
    expect(await card(page).count()).toBe(0);
    expect(prompts).toEqual([]);
    await page.close();
  });

  test("the card leaves the turn's footer in view above it", async () => {
    // A pane where the chat just fits until the card takes its height: the transcript then
    // overflows, and its end, the turn's footer (its time, Copy and Retry), stays in view.
    const page = await openChat(false);
    const view = () =>
      page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
        const last = Math.max(...rows.map((row) => row.getBoundingClientRect().bottom));
        // The view's foot: the bottom stack lies over the transcript's foot (bottomStack.css).
        const stack = document.querySelector(".acpmux-main[data-dock=float] > .acpmux-dock");
        const foot = stack ? stack.getBoundingClientRect().top : scroller.getBoundingClientRect().bottom;
        return {
          overflows: scroller.scrollHeight > scroller.clientHeight,
          below: Math.max(0, Math.round(last - foot)),
          spare: Math.floor(foot - last),
        };
      });
    await atRest(page);
    // Font metrics differ between hosts: the pane is sized from the chat as drawn, with 4px of
    // spare room under its last row beyond the rest room the transcript keeps under it over the
    // floating stack (model.ts restRoom, #30297), which is part of the chat's height.
    const { spare } = await view();
    await page.setViewportSize({ width: 900, height: 760 - spare + restRoom() + 4 });
    await atRest(page);
    expect(await view()).toMatchObject({ overflows: false, below: 0 });
    await setSessionStatus(page);
    await card(page).waitFor();
    await atRest(page);
    expect(await view()).toMatchObject({ overflows: true, below: 0 });
    await page.close();
  });

  test("with the toggle off nothing shows", async () => {
    const page = await openChat(false);
    await settled();
    expect(await card(page).count()).toBe(0);
    await page.close();
  });
});
