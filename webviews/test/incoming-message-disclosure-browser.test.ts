// l10n-allow-file: test fixtures.
// Another agent's message in the real agent pane is one disclosure line where it arrived
// (conversation/IncomingMessageCard.tsx on the shared DisclosureRow; Leo, 2026-10-29: "why the
// fuck did you guys ffucking ellipsis EVERYTHING WITH NO WAY TO EXPAND WHAT WAS SAID TO SEE"):
//
// - A 40-paragraph message draws as one 26px line, closed. Its toggle opens all of it: the last
//   paragraph is there, nothing in the panel is clipped by an ellipsis, and its text box hides
//   nothing (scrollHeight equals clientHeight).
// - Opening and closing never move the line: mid-view with rows above and below, and as the chat's
//   last row with the view pinned to its end, the toggle's top stays within 1px once the fold ends.
// - Each message is its own row: three from three senders between two replies are three rows in
//   their order, never one card; ones queued behind the running turn draw after that turn, with
//   one "Read after this turn" over the first of them.
//
// The page is the pane's dev entry (vite.config.acpmux-pane.mjs) talking JSON-RPC over a WebSocket
// to a stand-in acpmux daemon (as agent-pane-suggested-tasks.test.ts). Real Chromium from
// Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("incoming-message-disclosure-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("incoming-message-disclosure-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("incoming message disclosure", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "disclosure-session";
  type Record_ = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
  let seq = 0;
  let history: Record_[] = [];
  let status = "idle";
  /// The queue acpmux lists for the chat (session_changed's previews), while a turn runs.
  let queue: { promptId: string; prompt: string }[] = [];
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/shop",
    title: "Coordinate the lanes",
    harness: "claude",
    status,
    ...(status === "running"
      ? { queued: queue.length, queue, turn: { turnId: "turn-run", promptId: "p-run", startedAt: Date.now() - 5_000 } }
      : {}),
    updatedAt: Date.now(),
  });
  const record = (kind: string, msg: Record<string, unknown>, dir = "mux"): Record_ => ({
    sessionId: SESSION,
    seq: ++seq,
    at: Date.now() + seq,
    dir,
    kind,
    msg,
  });
  /// What the person typed, the agent's reply to it, and the turn's end.
  const prompt = (text: string) => record("user_message", { text });
  const reply = (text: string) =>
    record(
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
        },
      },
      "in",
    );
  const ended = () => record("turn_result", { status: "completed", stopReason: "end_turn" });
  const turn = (index: number) => [
    prompt(`Question ${index}`),
    reply(
      Array.from(
        { length: 3 },
        (_, line) =>
          `Answer ${index}.${line}: the keeper climbed to the gallery and wiped the salt from the lantern glass, then watched the light sweep the water.`,
      ).join("\n\n"),
    ),
    ended(),
  ];
  /// Another agent's message as acpmux records it (`agent_message` provenance).
  const fromAgent = (text: string, name: string, child: string, msgId: string) =>
    record("user_message", {
      text,
      _meta: { provenance: { kind: "agent_message", from: `acp:${child}`, fromName: name, msgId, threadId: msgId } },
    });
  const paragraphs = (count: number) =>
    Array.from(
      { length: count },
      (_, index) => `Paragraph ${index + 1} of the landing report: every check on the grid lane passed on this run.`,
    ).join("\n\n");

  const kindsOf = (params: Record<string, any>) =>
    Array.isArray(params.kinds) ? (params.kinds as string[]) : undefined;
  /// acpmux's EventFilter::matches for the attach's kinds.
  const passes = (kinds: string[] | undefined, rec: Record_) =>
    !kinds ||
    kinds.some((k) =>
      k === "all" || k === "mux"
        ? rec.dir === "mux"
        : k === "transcript"
          ? rec.dir === "in" ||
            (rec.dir === "mux" && ["user_message", "queued", "dequeued", "turn_end", "turn_result"].includes(rec.kind))
          : k === rec.kind,
    );
  function answer(method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions: [summary()] } };
      case "_acpmux/attach":
        if (params.sessionId !== SESSION)
          return { result: { session: { ...summary(), sessionId: params.sessionId }, lastSeq: seq, events: [] } };
        return {
          result: { session: summary(), lastSeq: seq, events: history.filter((rec) => passes(kindsOf(params), rec)) },
        };
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: seq } };
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
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          const reply = answer(message.method, message.params ?? {});
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

  /// Opens the chat with `records` as its history, once `waitText` draws.
  async function openChat(
    records: Record_[],
    waitText: string,
    running = false,
    queued: { promptId: string; prompt: string }[] = [],
  ): Promise<Page> {
    seq = 0;
    status = running ? "running" : "idle";
    queue = queued;
    history = records;
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // The file's first page loads the pane's modules cold; on a busy runner that took over 10 s.
    await page.getByText(waitText).first().waitFor({ timeout: 60_000 });
    return page;
  }
  /// Resolves once every finite animation in the transcript has finished, and two frames painted.
  const rest = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let round = 0; round < 5; round++) {
        const running = scroller
          .getAnimations({ subtree: true })
          .filter((animation) => animation.effect?.getTiming().iterations !== Infinity);
        if (!running.length) break;
        await Promise.all(running.map((animation) => animation.finished.catch(() => undefined)));
      }
      await new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done())));
    });
  const topOf = (locator: Locator) => locator.evaluate((el) => el.getBoundingClientRect().top);
  /// Puts `locator`'s top `y` px below the transcript's top.
  const scrollTo = (locator: Locator, y: number) =>
    locator.evaluate((el, down) => {
      const scroller = el.closest<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop += el.getBoundingClientRect().top - scroller.getBoundingClientRect().top - down;
    }, y);
  /// Scrolls the transcript up from its end until `selector` is drawn (the transcript is virtualized).
  const scrollUntilDrawn = (page: Page, selector: string) =>
    page.evaluate(async (query) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let step = 0; step < 200 && !document.querySelector(query); step++) {
        scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight / 3);
        await new Promise<void>((done) => requestAnimationFrame(() => requestAnimationFrame(() => done())));
      }
      return document.querySelector(query) !== null;
    }, selector);
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });

  const LONG = paragraphs(40);
  const LAST = "Paragraph 40 of the landing report";

  test("a 40-paragraph message is one line, and its toggle opens all of it, nothing clipped", async () => {
    const page = await openChat(
      [...turn(1), fromAgent(LONG, "Grid fix", "child-3", "m-long"), reply("Merged the grid fix."), ended()],
      "Merged the grid fix.",
    );
    try {
      const row = page.locator(".cv-received");
      await row.waitFor({ timeout: 10_000 });
      expect(await row.count()).toBe(1);
      // Closed: one line on the tool rows' line, the sender and the first line, nothing under it. The
      // line is the grid's compact row, read from --grid-row: design/grid.md Rule 1, section 3 "row
      // height = 28 (compact)" and section 6 (28 since #27580; 22 under #29965).
      const line = await row.evaluate((el) => {
        const probe = document.createElement("div");
        probe.style.cssText = "position:absolute;visibility:hidden;height:var(--grid-row)";
        el.appendChild(probe);
        const height = probe.getBoundingClientRect().height;
        probe.remove();
        return height;
      });
      expect(line).toBeGreaterThan(0);
      expect(await row.evaluate((el) => Math.round(el.getBoundingClientRect().height))).toBe(Math.round(line));
      expect(await row.locator(".cv-disclosure__line").evaluate((el) => el.getBoundingClientRect().height)).toBe(line);
      expect(await row.locator(".cv-received__from").innerText()).toBe("Grid fix");
      expect(await row.locator(".cv-received__preview").innerText()).toBe(
        "Paragraph 1 of the landing report: every check on the grid lane passed on this run.",
      );
      expect(await row.locator(".cv-disclosure__panel").count()).toBe(0);
      const toggle = row.locator(".cv-disclosure__toggle");
      expect(await toggle.getAttribute("aria-expanded")).toBe("false");
      expect(await toggle.getAttribute("aria-label")).toMatch(/^Message from Grid fix: Paragraph 1 /);

      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("true");
      await rest(page);
      const text = row.locator(".cv-received__text");
      await text.getByText(LAST).waitFor({ timeout: 5_000 });
      expect(await text.locator("p").count()).toBe(40);
      // No From: line in the panel: the line names the sender once.
      expect(await row.locator(".cv-received__from-line").count()).toBe(0);
      // Nothing in the panel is cut with an ellipsis, and the text box hides none of its text.
      const clipped = await row.locator(".cv-disclosure__panel").evaluate((panel) =>
        [panel, ...panel.querySelectorAll<HTMLElement>("*")]
          .filter((el) => {
            const style = getComputedStyle(el);
            return style.textOverflow === "ellipsis" && el.scrollWidth > el.clientWidth + 1;
          })
          .map((el) => el.className),
      );
      expect(clipped).toEqual([]);
      const box = await text.evaluate((el) => ({ scroll: el.scrollHeight, client: el.clientHeight }));
      expect(box.scroll).toBe(box.client);
      // The panel is as tall as the text it holds: no max-height cut around it.
      const panel = await row
        .locator(".cv-disclosure__panel")
        .evaluate((el) => ({ scroll: el.scrollHeight, client: el.clientHeight, wrap: el.parentElement!.clientHeight }));
      expect(panel.scroll).toBe(panel.client);
      expect(panel.wrap).toBeGreaterThanOrEqual(panel.client);
      // No cut, Show more or eight-line card anywhere.
      expect(await page.locator(".cv-received__body, .cv-received__show, [data-cut]").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("opening and closing a message mid-view keeps its line on its pixel", async () => {
    const page = await openChat(
      [
        ...Array.from({ length: 6 }, (_, index) => turn(index)).flat(),
        fromAgent(LONG, "Grid fix", "child-3", "m-mid"),
        reply("Merged the grid fix."),
        ended(),
        ...Array.from({ length: 6 }, (_, index) => turn(index + 10)).flat(),
      ],
      "Answer 15.2",
    );
    try {
      const toggle = page.locator(".cv-received .cv-disclosure__toggle");
      await page.getByText("Answer 15.2").first().waitFor({ timeout: 10_000 });
      expect(await scrollUntilDrawn(page, ".cv-received .cv-disclosure__toggle")).toBe(true);
      // The transcript scrolls: there is more above and below than the view holds.
      const scroll = await page
        .locator(".acpmux-scroll")
        .evaluate((el) => ({ height: el.scrollHeight, view: el.clientHeight }));
      expect(scroll.height).toBeGreaterThan(scroll.view * 2);
      await scrollTo(toggle, scroll.view / 2);
      await rest(page);
      const before = await topOf(toggle);
      expect(
        Math.abs(
          before -
            (await page.locator(".acpmux-scroll").evaluate((el) => el.getBoundingClientRect().top)) -
            scroll.view / 2,
        ),
      ).toBeLessThan(40);

      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("true");
      await rest(page);
      const opened = await topOf(toggle);
      console.log(`mid-view: line top ${before} -> ${opened} opened`);
      expect(Math.abs(opened - before)).toBeLessThan(1);
      await page.locator(".cv-received__text").getByText("Paragraph 1 ").first().waitFor({ timeout: 5_000 });

      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("false");
      await rest(page);
      const closed = await topOf(toggle);
      console.log(`mid-view: line top ${before} -> ${closed} closed`);
      expect(Math.abs(closed - before)).toBeLessThan(1);
      expect(await page.locator(".cv-received .cv-disclosure__panel").count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("the chat's last row, opened and closed with the view at its end, stays on its pixel", async () => {
    const page = await openChat(
      [...Array.from({ length: 6 }, (_, index) => turn(index)).flat(), fromAgent(LONG, "Grid fix", "child-3", "m-end")],
      "Paragraph 1 of the landing report",
    );
    try {
      const toggle = page.locator(".cv-received .cv-disclosure__toggle");
      await toggle.waitFor({ timeout: 10_000 });
      await rest(page);
      expect(await atLatest(page)).toBe(true);
      const before = await topOf(toggle);

      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("true");
      await rest(page);
      const opened = await topOf(toggle);
      console.log(`pinned end: line top ${before} -> ${opened} opened`);
      expect(Math.abs(opened - before)).toBeLessThan(1);

      await toggle.click();
      expect(await toggle.getAttribute("aria-expanded")).toBe("false");
      await rest(page);
      const closed = await topOf(toggle);
      console.log(`pinned end: line top ${before} -> ${closed} closed`);
      expect(Math.abs(closed - before)).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });

  test("three messages from three senders between two replies are three rows, in order, where they arrived", async () => {
    const page = await openChat(
      [
        prompt("Coordinate the lanes and tell me when they land"),
        reply("First reply: messaged the lanes."),
        ended(),
        fromAgent("composer-caret is merged as #2210.", "composer-caret", "child-1", "m-1"),
        ended(),
        fromAgent("sidebar-cleanup is in review.", "sidebar-cleanup", "child-2", "m-2"),
        ended(),
        fromAgent("grid-fix reserves its height now.", "grid-fix", "child-3", "m-3"),
        reply("Second reply: two landed, one in review."),
        ended(),
      ],
      "Second reply: two landed, one in review.",
    );
    try {
      await page.locator(".cv-received").nth(2).waitFor({ timeout: 10_000 });
      // Every row in the transcript's DOM order: the two replies and the three messages between them.
      const order = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>(".acpmux-scroll [data-row-id]")]
          .filter((row) => !row.parentElement?.closest("[data-row-id]"))
          .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)
          .flatMap((row) => {
            const received = row.querySelectorAll(".cv-received");
            if (received.length)
              return [...received].map((el) => `from ${el.querySelector(".cv-received__from")?.textContent}`);
            const text = row.textContent ?? "";
            if (text.includes("First reply")) return ["first reply"];
            if (text.includes("Second reply")) return ["second reply"];
            return [];
          }),
      );
      expect(order).toEqual([
        "first reply",
        "from composer-caret",
        "from sidebar-cleanup",
        "from grid-fix",
        "second reply",
      ]);
      // Each its own row, never one card that holds several.
      const rows = await page.evaluate(() =>
        [...document.querySelectorAll(".cv-received")].map((el) =>
          el.closest("[data-row-id]")?.getAttribute("data-row-id"),
        ),
      );
      expect(new Set(rows).size).toBe(3);
      expect(await page.locator(".cv-waiting__toggle, .cv-received .cv-received").count()).toBe(0);
      expect(await page.locator(".acpmux-scroll").innerText()).not.toMatch(/messages? from/i);
    } finally {
      await page.close();
    }
  });

  // Leo, 2026-10-29: "this ui is all quite inconsistent". A delivered message and one that waits
  // are one row: their chevrons end on one x, one plate under the line, actions only on hover.
  test("a delivered message and a waiting one draw the same line: one chevron column, actions on hover", async () => {
    const page = await openChat(
      [
        ...turn(1),
        fromAgent("Landed #24001; nightly is building.", "lint-lane", "child-1", "m-1"),
        prompt("Add retries to the fetch helper"),
        reply("Reading the helper now."),
        record("queued", {
          text: "Docs are rebuilt for the 2.3 release notes.",
          promptId: "q-2",
          fromAgent: "docs-lane",
          position: 0,
        }),
      ],
      "Reading the helper now.",
      true,
      [{ promptId: "q-2", prompt: "Docs are rebuilt for the 2.3 release notes." }],
    );
    try {
      await page.locator(".cv-pending__toggle").click();
      const rows = page.locator(".cv-received");
      await rows.nth(1).waitFor({ timeout: 10_000 });
      const lines = await rows.evaluateAll((all) =>
        all.map((row) => {
          const line = row.querySelector<HTMLElement>(":scope > .cv-disclosure__line")!;
          const chevron = line.querySelector<HTMLElement>(".cv-rotor")!.getBoundingClientRect();
          const hover = line.querySelector<HTMLElement>(".cv-received__hover");
          return {
            right: Math.round(chevron.right),
            open: Boolean(line.querySelector(".cv-disclosure__open")),
            groups: line.querySelectorAll(".cv-received-actions").length,
            hidden: hover ? getComputedStyle(hover).opacity : "missing",
          };
        }),
      );
      expect(lines).toHaveLength(2);
      expect(lines[0]!.right).toBe(lines[1]!.right);
      for (const line of lines) {
        expect(line.open).toBe(false);
        expect(line.groups).toBe(1);
        expect(line.hidden).toBe("0");
      }
      expect(await page.getByText(/Read after this|Open chat|^From:/).count()).toBe(0);
      // Hovered, the actions show in the line's own plate, and the chevron stays put.
      await rows.nth(1).locator(":scope > .cv-disclosure__line").hover();
      // Measure the revealed controls after their transition, not in its first frame.
      const actions = await rows.nth(1).locator(".cv-received__hover").elementHandle();
      try {
        await page.waitForFunction((node) => node !== null && getComputedStyle(node).opacity === "1", actions, {
          timeout: 5_000,
        });
      } finally {
        await actions?.dispose();
      }
      const hovered = await rows.nth(1).evaluate((row) => {
        const line = row.querySelector<HTMLElement>(":scope > .cv-disclosure__line")!;
        return {
          plate: getComputedStyle(line).backgroundColor,
          shown: getComputedStyle(line.querySelector<HTMLElement>(".cv-received__hover")!).opacity,
          right: Math.round(line.querySelector<HTMLElement>(".cv-rotor")!.getBoundingClientRect().right),
        };
      });
      // The trailing controls share the row's one gap (Leo, 2026-10-29: "the odd gap betwene the pin
      // and the ellipsis"): every visible control is the same distance from the next.
      const gaps = await rows.nth(1).evaluate((row) => {
        const controls = [...row.querySelectorAll<HTMLElement>(".cv-received__hover .cv-message-footer-row > *")]
          .filter((node) => getComputedStyle(node).display !== "none" && node.getBoundingClientRect().width > 0)
          .map((node) => node.getBoundingClientRect());
        return controls.slice(1).map((box, index) => Math.round(box.left - controls[index]!.right));
      });
      // Another session's waiting message has its ⋯ alone: no Pin and no hover Copy beside it (Leo,
      // 2026-10-30: "weird to be able to pin them etc"), so no gap is left to differ.
      expect(new Set(gaps).size).toBeLessThanOrEqual(1);
      expect(await rows.locator(".cv-received__hover .cv-message-pin").count()).toBe(0);
      expect(await rows.locator('.cv-received__hover .cv-message-footer-row [aria-label="Copy"]').count()).toBe(0);
      expect(hovered.plate).not.toBe("rgba(0, 0, 0, 0)");
      expect(hovered.shown).toBe("1");
      expect(hovered.right).toBe(lines[1]!.right);
    } finally {
      await page.close();
    }
  });

  test("messages queued behind the running turn draw after it, in one group, no Read after this turn", async () => {
    const page = await openChat(
      [
        ...turn(1),
        prompt("Add retries to the fetch helper"),
        reply("Reading the helper now."),
        record("queued", { text: "Lint is green on #24001.", promptId: "q-1", fromAgent: "lint-lane", position: 0 }),
        record("queued", { text: "Docs are rebuilt.", promptId: "q-2", fromAgent: "docs-lane", position: 1 }),
      ],
      "Reading the helper now.",
      true,
      [
        { promptId: "q-1", prompt: "Lint is green on #24001." },
        { promptId: "q-2", prompt: "Docs are rebuilt." },
      ],
    );
    try {
      // One collapsed group after the running turn, with no "Read after this turn" (Leo,
      // 2026-10-29: "why the fuck do you guys keep doing this fucking bullshit with the red after
      // this turn?"); opened, a line per message in the queue's order.
      const toggle = page.locator(".cv-pending__toggle");
      await toggle.waitFor({ timeout: 10_000 });
      expect(await toggle.count()).toBe(1);
      expect(await page.getByText(/Read after this (turn|step)/).count()).toBe(0);
      const replyBottom = await page
        .getByText("Reading the helper now.")
        .first()
        .evaluate((el) => el.getBoundingClientRect().bottom);
      expect(await topOf(toggle)).toBeGreaterThanOrEqual(replyBottom);
      await toggle.click();
      const rows = page.locator(".cv-received");
      await rows.nth(1).waitFor({ timeout: 10_000 });
      expect(await rows.count()).toBe(2);
      expect(await rows.locator(".cv-received__from").allInnerTexts()).toEqual(["lint-lane", "docs-lane"]);
      expect(await topOf(rows.nth(1))).toBeGreaterThan(await topOf(rows.first()));
      // No composer-queue row for them.
      expect(await page.locator(".acpmux-queued").count()).toBe(0);
    } finally {
      await page.close();
    }
  });
});
