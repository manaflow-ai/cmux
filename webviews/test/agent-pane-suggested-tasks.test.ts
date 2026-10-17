// l10n-allow-file: test fixtures.
// Suggested tasks and the chats they start, in the real agent pane (cx-lo9yf). The page is the
// pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a
// WebSocket to a stand-in acpmux daemon that answers the way `hub/offers.rs` does.
//
// - Offers that share a `groupId` draw as one card: "3 suggested tasks" with Start all. Start all
//   starts a chat per open task, in order, and answers each offer with its chat; once every task
//   is answered the card reads "3 started" over one row per started chat.
// - An offer without a group is the single card. Do it here answers it `here` and sends its
//   prompt to this chat; nothing new starts.
// - A started chat's row shows its latest tool call, read through a hidden attach to that chat,
//   which ends when the chat's turn ends.
// - The parent's prompt that carries a task's result (`_meta.provenance.kind: "offer_result"`)
//   draws as "Received message from <title>", not as the person's bubble.
// - Off (no Debug toggle, no experiment) nothing draws; the `agent.suggestedTasks` Debug toggle
//   (`applySuggestedTasks`) alone draws the card; `applyPreview` does not.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-suggested-tasks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-suggested-tasks: skipping (run `bunx playwright install chromium`)");
    describe.skip("suggested tasks", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "tasks-session";
  const RUNNING_CHILD = "running-child";
  type Summary = { sessionId: string; cwd: string; title: string; harness: string; status: string; updatedAt: number };
  const summary = (sessionId = SESSION, status = "running"): Summary => ({
    sessionId,
    cwd: "/home/dev/shop",
    title: "Fix the product grid layout shift",
    harness: "claude",
    status,
    updatedAt: Date.now(),
  });
  type Record_ = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
  const task = (n: number, title: string, prompt: string, groupId?: string) => ({
    offerId: `offer-${n}`,
    title,
    prompt,
    cwd: "/home/dev/shop",
    worktree: false,
    ...(groupId ? { groupId } : {}),
  });
  const group = [
    task(1, "Cart: add width and height to thumbnails", "Give the cart thumbnails a width and height.", "g-1"),
    task(2, "Images: lazy-load below the fold", "Add loading=lazy to images below the fold.", "g-1"),
    task(3, "Checkout: label the form fields", "Give every checkout input a visible label.", "g-1"),
  ];
  const single = task(9, "Add width and height to cart thumbnail images", "CartLineItem renders images unsized.");

  let seq = 0;
  let history: Record_[] = [];
  let sessions: Summary[] = [];
  let childPages = new Map<string, Record_[]>();
  let calls: { method: string; params: Record<string, any> }[] = [];
  let wanted: string[] | undefined;
  let children = 0;
  let socket: { send(data: string): void } | undefined;
  let offers: Record<string, unknown>[] = [];

  const record = (kind: string, msg: Record<string, unknown>, sessionId = SESSION, dir = "mux"): Record_ => ({
    sessionId,
    seq: ++seq,
    at: Date.now(),
    dir,
    kind,
    msg,
  });
  /// acpmux's EventFilter::matches for the attach's kinds.
  const passes = (kinds: string[] | undefined, rec: Record_) =>
    !kinds ||
    kinds.some((k) =>
      k === "all" || k === "mux"
        ? rec.dir === "mux"
        : k === "transcript"
          ? rec.dir === "in" ||
            (rec.dir === "mux" &&
              [
                "user_message",
                "queued",
                "dequeued",
                "session_offer",
                "session_offer_decision",
                "turn_end",
                "turn_result",
              ].includes(rec.kind))
          : k === rec.kind,
    );

  type Socket = { send(data: string): void };
  const emit = (ws: Socket, rec: Record_) => {
    if (rec.sessionId !== SESSION || passes(wanted, rec))
      ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
  };

  function answer(ws: Socket, method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    calls.push({ method, params: { ...params } });
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions } };
      case "_acpmux/attach": {
        if (params.sessionId !== SESSION) {
          const kinds = Array.isArray(params.kinds) ? params.kinds : undefined;
          const page = (childPages.get(params.sessionId) ?? []).filter((rec) => passes(kinds, rec));
          const limited = typeof params.limit === "number" ? page.slice(-params.limit || page.length) : page;
          return {
            result: {
              session: summary(params.sessionId),
              lastSeq: seq,
              events: params.limit === 0 ? [] : limited,
            },
          };
        }
        wanted = Array.isArray(params.kinds) ? params.kinds : undefined;
        return { result: { session: summary(), lastSeq: seq, events: history.filter((rec) => passes(wanted, rec)) } };
      }
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: seq } };
      case "session/new":
        return { result: { sessionId: `child-${++children}` } };
      case "session/prompt":
        return { result: { stopReason: "end_turn" } };
      case "_acpmux/offer_respond": {
        const offer = offers.find((item) => item.offerId === params.offerId);
        if (params.sessionId !== SESSION || !offer)
          return { error: { code: -32602, message: "no open offer has that offerId" } };
        const decision: Record<string, unknown> = { offerId: params.offerId, outcome: params.outcome };
        if (params.childSessionId) decision.childSessionId = params.childSessionId;
        emit(ws, record("session_offer_decision", decision));
        return { result: decision };
      }
      default:
        return { result: null };
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          socket = ws;
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          const reply = answer(ws, message.method, message.params ?? {});
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }));
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

  type Setup = {
    offered: Record<string, unknown>[];
    experiment?: "on" | "off";
    extra?: () => Record_[];
    width?: number;
  };
  async function openChat({ offered, experiment = "on", extra, width = 900 }: Setup): Promise<Page> {
    calls = [];
    seq = 0;
    children = 0;
    wanted = undefined;
    offers = offered;
    sessions = [summary()];
    childPages = new Map();
    history = [
      record("user_message", { text: "Fix the product grid layout shift" }),
      ...offered.map((offer) => record("session_offer", offer)),
      ...(extra?.() ?? []),
    ];
    const page = await browser!.newPage({ viewport: { width, height: 760 } });
    await page.addInitScript(
      (arm) => localStorage.setItem("cmux.experiments", JSON.stringify({ "session-offer": arm })),
      experiment,
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // The file's first page loads the pane's modules cold; on a busy runner that took over 10 s.
    await page.getByText("Fix the product grid layout shift").first().waitFor({ timeout: 60_000 });
    return page;
  }
  async function waitUntil(done: () => boolean) {
    for (let tries = 0; !done() && tries < 100; tries++) await Bun.sleep(50);
    expect(done()).toBe(true);
  }
  const card = (page: Page) => page.locator(".acpmux-tasks");

  describe("suggested tasks", () => {
    test("with neither the Debug toggle nor the experiment, the tasks draw nothing", async () => {
      const page = await openChat({ offered: group, experiment: "off" });
      await page.waitForTimeout(500);
      expect(await card(page).count()).toBe(0);
      expect(await page.locator("body").innerText()).not.toContain(group[0]!.title);
      await page.close();
    });

    test("the Debug toggle alone draws the card; preview features do not", async () => {
      const page = await openChat({ offered: group, experiment: "off" });
      await page.waitForFunction(() => typeof window.cmuxAcpmuxBridge?.applySuggestedTasks === "function");
      await page.evaluate(() => window.cmuxAcpmuxBridge?.applyPreview?.(true));
      await page.waitForTimeout(500);
      expect(await card(page).count()).toBe(0);
      await page.evaluate(() => window.cmuxAcpmuxBridge?.applySuggestedTasks?.(true));
      await card(page).getByText(group[0]!.title).waitFor({ timeout: 10_000 });
      await page.close();
    });

    test("tasks that share a group draw as one card, and Start all starts each in order", async () => {
      const page = await openChat({ offered: group });
      await card(page).getByText("3 suggested tasks").waitFor({ timeout: 10_000 });
      for (const offer of group) await card(page).getByText(offer.title).waitFor({ timeout: 5_000 });
      expect(await card(page).count()).toBe(1);
      expect(await card(page).getByText(group[1]!.prompt).isVisible()).toBe(true);

      await card(page).getByRole("button", { name: "Start all" }).click();
      await card(page).getByText("3 started").waitFor({ timeout: 10_000 });

      const created = calls.filter((c) => c.method === "session/new");
      expect(created.map((c) => c.params.cwd)).toEqual(group.map((offer) => offer.cwd));
      const respond = calls.filter((c) => c.method === "_acpmux/offer_respond").map((c) => c.params);
      expect(respond).toEqual(
        group.map((offer, index) => ({
          sessionId: SESSION,
          offerId: offer.offerId,
          outcome: "accepted",
          childSessionId: `child-${index + 1}`,
        })),
      );
      // Each new chat gets its task's prompt, sent while attached hidden.
      await waitUntil(() => calls.filter((c) => c.method === "session/prompt").length === 3);
      for (const [index, offer] of group.entries()) {
        const prompt = calls.find((c) => c.method === "session/prompt" && c.params.sessionId === `child-${index + 1}`);
        expect(JSON.stringify(prompt?.params.prompt)).toContain(offer.prompt);
        const attach = calls.find((c) => c.method === "_acpmux/attach" && c.params.sessionId === `child-${index + 1}`);
        expect(attach?.params.visible).toBe(false);
      }
      // Answered, the card is its count and a row per started chat; no task's Start is left.
      expect(await card(page).getByRole("button", { name: "Start", exact: true }).count()).toBe(0);
      expect(await card(page).getByRole("button", { name: "Start all" }).count()).toBe(0);
      expect(await card(page).locator(".acpmux-task-started").count()).toBe(3);
      await page.close();
    });

    test("a task's dismiss answers it dismissed and leaves the others", async () => {
      const page = await openChat({ offered: group });
      await card(page).getByText(group[1]!.title).waitFor({ timeout: 10_000 });
      await card(page)
        .locator(".acpmux-task")
        .filter({ hasText: group[1]!.title })
        .getByRole("button", { name: "Dismiss" })
        .click();
      await waitUntil(() => calls.some((c) => c.method === "_acpmux/offer_respond"));
      await card(page).getByText(group[1]!.title).waitFor({ state: "detached", timeout: 10_000 });
      expect(calls.filter((c) => c.method === "_acpmux/offer_respond").map((c) => c.params)).toEqual([
        { sessionId: SESSION, offerId: group[1]!.offerId, outcome: "dismissed" },
      ]);
      expect(await card(page).getByText(group[0]!.title).isVisible()).toBe(true);
      expect(calls.some((c) => c.method === "session/new")).toBe(false);
      await page.close();
    });

    test("Do it here answers the offer here and sends its prompt to this chat", async () => {
      const page = await openChat({ offered: [single] });
      await card(page).getByText(single.title).waitFor({ timeout: 10_000 });
      // A lone offer's card is headed with the list's own word, no noun (cg-ui-coord, 10-15).
      expect(await card(page).getByText("Suggested", { exact: true }).count()).toBe(1);
      await card(page).getByRole("button", { name: "Do it here" }).click();
      await waitUntil(() => calls.some((c) => c.method === "session/prompt"));
      const respondAt = calls.findIndex((c) => c.method === "_acpmux/offer_respond");
      const promptAt = calls.findIndex((c) => c.method === "session/prompt");
      expect(calls[respondAt]?.params).toEqual({ sessionId: SESSION, offerId: single.offerId, outcome: "here" });
      expect(promptAt).toBeGreaterThan(respondAt);
      expect(calls[promptAt]?.params.sessionId).toBe(SESSION);
      expect(JSON.stringify(calls[promptAt]?.params.prompt)).toContain(single.prompt);
      expect(calls.some((c) => c.method === "session/new")).toBe(false);
      await card(page).getByText(single.title).waitFor({ state: "detached", timeout: 10_000 });
      await page.close();
    });

    test("a started chat's row shows its latest tool call, and the hidden attach ends with its turn", async () => {
      const accepted = { ...single, offerId: "offer-live" };
      // The chat was started before this page opened, and is still running. A narrow pane.
      const page = await openChat({
        width: 360,
        offered: [accepted],
        extra: () => {
          sessions = [summary(), summary(RUNNING_CHILD, "running")];
          const update = {
            sessionUpdate: "tool_call",
            toolCallId: "call-1",
            title: "Reading CartLineItem.tsx",
            kind: "read",
            status: "in_progress",
          };
          childPages.set(RUNNING_CHILD, [
            record(
              "tool_call",
              { method: "session/update", params: { sessionId: RUNNING_CHILD, update } },
              RUNNING_CHILD,
              "in",
            ),
          ]);
          return [
            record("session_offer_decision", {
              offerId: accepted.offerId,
              outcome: "accepted",
              childSessionId: RUNNING_CHILD,
            }),
          ];
        },
      });
      const row = page.locator(".acpmux-task-started");
      await row.getByText(accepted.title).waitFor({ timeout: 10_000 });
      await row.getByText("Reading CartLineItem.tsx").waitFor({ timeout: 10_000 });
      const attach = calls.find((c) => c.method === "_acpmux/attach" && c.params.sessionId === RUNNING_CHILD);
      expect(attach?.params.visible).toBe(false);
      expect(attach?.params.kinds).toContain("tool_call");
      expect(calls.some((c) => c.method === "_acpmux/detach" && c.params.sessionId === RUNNING_CHILD)).toBe(false);
      // One line inside the pane: the title and subtitle give way, the state dot and chevron stay.
      expect(await row.locator(".acpmux-task-dot").isVisible()).toBe(true);
      const fits = await row.evaluate((node) => {
        const line = node.querySelector<HTMLElement>(".acpmux-task-row")!;
        const chevron = line.lastElementChild!.getBoundingClientRect();
        return {
          overflow: line.scrollWidth - line.clientWidth,
          chevronInside: chevron.right <= line.getBoundingClientRect().right + 0.5 && chevron.width > 0,
          inPane: node.getBoundingClientRect().right <= document.documentElement.clientWidth + 0.5,
          height: line.getBoundingClientRect().height,
        };
      });
      expect(fits).toEqual({ overflow: 0, chevronInside: true, inPane: true, height: 28 });
      // The title may be cut; the row's tooltip carries it whole.
      expect(await row.locator(".acpmux-task-row").getAttribute("title")).toBe(accepted.title);

      // The chat's turn ends: its attach ends, and the row says it is done.
      socket!.send(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/event",
          params: record("turn_result", { status: "completed", stopReason: "end_turn" }, RUNNING_CHILD),
        }),
      );
      socket!.send(
        JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/session_changed",
          params: { kind: "updated", session: summary(RUNNING_CHILD, "idle") },
        }),
      );
      await waitUntil(() => calls.some((c) => c.method === "_acpmux/detach" && c.params.sessionId === RUNNING_CHILD));
      await row.getByText("Reading CartLineItem.tsx").waitFor({ state: "detached", timeout: 10_000 });
      // The row opens the chat.
      expect(await row.getByRole("button", { name: `Open ${accepted.title}` }).count()).toBe(1);
      await page.close();
    });

    test("a task's result draws as a received line, not as the person's prompt", async () => {
      const accepted = { ...single, offerId: "offer-done" };
      const text = `Result from the suggested task "${accepted.title}" (chat child-7):\nAdded width and height.`;
      const page = await openChat({
        offered: [accepted],
        extra: () => [
          record("session_offer_decision", {
            offerId: accepted.offerId,
            outcome: "accepted",
            childSessionId: "child-7",
          }),
          record("turn_result", { status: "completed", stopReason: "end_turn" }),
          record("user_message", {
            text,
            _meta: {
              provenance: {
                kind: "offer_result",
                offerId: accepted.offerId,
                childSessionId: "child-7",
                title: accepted.title,
              },
            },
          }),
        ],
      });
      const line = page.locator(".acpmux-task-received");
      await line.waitFor({ timeout: 10_000 });
      expect(await line.innerText()).toContain("Received message from");
      expect(await line.innerText()).toContain(accepted.title);
      expect(await page.locator(".cv-user__bubble").filter({ hasText: "Result from the suggested task" }).count()).toBe(
        0,
      );
      await page.close();
    });

    test("a result queued behind a busy turn draws its received line once, before and after it lands", async () => {
      const accepted = { ...single, offerId: "offer-queued" };
      const text = `Result from the suggested task "${accepted.title}" (chat child-8):\nAdded width and height.`;
      const provenance = {
        kind: "offer_result",
        offerId: accepted.offerId,
        childSessionId: "child-8",
        title: accepted.title,
      };
      const promptId = `offer-result-${accepted.offerId}`;
      const page = await openChat({
        offered: [accepted],
        extra: () => [
          record("session_offer_decision", {
            offerId: accepted.offerId,
            outcome: "accepted",
            childSessionId: "child-8",
          }),
          // This chat's turn still runs: the result waits in its queue.
          record("queued", { promptId, text, client: "acpmux", _meta: { provenance } }),
        ],
      });
      const line = page.locator(".acpmux-task-received");
      await line.waitFor({ timeout: 10_000 });
      expect(await line.count()).toBe(1);
      expect(await line.innerText()).toContain(accepted.title);
      // Not a queued prompt: the result's text shows nowhere on the page.
      expect(await page.locator("body").innerText()).not.toContain("Result from the suggested task");

      // The turn ends and the result lands as this chat's prompt: still one line.
      emit(socket!, record("turn_result", { status: "completed", stopReason: "end_turn" }));
      emit(socket!, record("dequeued", { promptId }));
      emit(socket!, record("user_message", { text, client: "acpmux", promptId, _meta: { provenance } }));
      await page.waitForTimeout(500);
      expect(await line.count()).toBe(1);
      expect(await page.locator("body").innerText()).not.toContain("Result from the suggested task");
      await page.close();
    });
  });
});
