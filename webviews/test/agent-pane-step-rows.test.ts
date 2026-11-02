// l10n-allow-file: test fixture prompts, thoughts and commands, not shipped UI.
// The steps of a turn read as one list (Leo 2026-10-13, cmux NEXT on macOS 27): tool calls,
// thoughts and a background shell's end all draw on one rhythm (22px since #24565), whether
// they share a transcript row or not. An opened run's steps sit in one card (`.cv-steps`,
// #27896, the card the message groups draw, #27864): each is still one 22px row, the card's steps
// on one equal pitch of their own, and the rows outside cards keep the rhythm with no gap. A
// finished thought is one quiet row like the others that opens to its full text, wrapped, with no
// tooltip (Leo 2026-10-20). Inner tool rows keep their chevron slot quiet until hover, then light
// their icon, words and chevron together; the group header keeps its own disclosure.
//
// Before: the background task's end used a smaller font in a 22px row with its own margins, a
// step in the next transcript row sat 10px further down than one in the same row, a thought was
// cut to one line with the rest in a tooltip, and inner rows kept a visible chevron at rest.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-step-rows.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-step-rows: skipping (run `bunx playwright install chromium`)");
    describe.skip("step rows", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f2";
  const START = Date.UTC(2026, 9, 13, 9, 0, 0);
  const THOUGHT =
    "The release build fails only on the arm64 slice, so the cached acpmux is probably the x86_64 one. Check the cache key in build-acpmux.sh before rebuilding anything, then compare it with the commit the fleet step pinned.";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const call = (id: string, title: string, kind: string, extra: object = {}): Step[] => [
    [
      "in",
      "tool_call",
      update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "in_progress", ...extra }),
    ],
    ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" })],
  ];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Why does the release build fail?" }],
    ["mux", "turn_started", {}],
    ...call("c1", "git status", "execute", { rawInput: { command: "git status" } }),
    [
      "in",
      "agent_thought_chunk",
      update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: THOUGHT } }),
    ],
    ...call("c2", "ls build", "execute", { rawInput: { command: "ls build" } }),
    [
      "in",
      "background_task_update",
      update({
        sessionUpdate: "background_task_update",
        taskId: "task-bg1",
        toolCallId: "bg1",
        command: "scripts/cmux-next/build-web-bundles.sh",
        state: "completed",
      }),
    ],
    ...call("c3", "Read build-acpmux.sh", "read", { locations: [{ path: "/home/dev/cmux/scripts/build-acpmux.sh" }] }),
    // The turn is still running. Its finished steps fold under their run's line (Debug toggle
    // agentPane.debug.codexToolRuns, on by default), which the tests open (`openRun`).
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
    cwd: "/home/dev/cmux",
    title: "Release build",
    harness: "claude",
    family: "claude",
    status: "running",
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
  const open = async (): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url());
    await page.getByText("build-acpmux.sh").first().waitFor();
    // Rows place by their drawn heights a frame after they mount: two painted frames later they have.
    await installPaintedFrames(page);
    await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
    return page;
  };
  /// Opens the group of the first two commands and the thought between them ("Ran 2 commands",
  /// conversation/ToolGroupRow.tsx; the thought stays in the group, toolGroups.ts), so each step in
  /// it draws its own row.
  const openRun = async (page: Page) => {
    await page.locator(".acpmux-row button.cv-tool", { hasText: "Ran 2 commands" }).click();
    await page.locator(".cv-thought").waitFor();
    // The fold plays (a Web Animation, fold.ts), then the rows below it place by their drawn heights.
    await page.evaluate(async () => {
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("build-acpmux.sh").first().waitFor({ timeout: 25_000 });
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

  test("every step is one grid row on one rhythm, across transcript rows", async () => {
    const page = await open();
    await openRun(page);
    const rows = await page.locator(".acpmux-row .cv-tool").evaluateAll((nodes) =>
      nodes.map((node) => {
        const box = node.getBoundingClientRect();
        const card = node.closest(".cv-steps");
        return {
          text: node.textContent?.replace(/\s+/g, " ").trim().slice(0, 24) ?? "",
          top: box.top,
          height: Math.round(box.height),
          fontSize: getComputedStyle(node).fontSize,
          card: card ? [...document.querySelectorAll(".cv-steps")].indexOf(card) : -1,
        };
      }),
    );
    // The finished thought is folded to one line too. The line is the grid's compact row, read from
    // --grid-row: design/grid.md Rule 1, section 3 "row height = 28 (compact)" and section 6 (28 since
    // #27580; 22 from #24565 and #29965).
    const line = await page.locator(".acpmux-row .cv-tool").first().evaluate((node) => {
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--grid-row)";
      node.parentElement!.appendChild(probe);
      const height = Math.round(probe.getBoundingClientRect().height);
      probe.remove();
      return height;
    });
    expect(line).toBeGreaterThan(0);
    expect(rows.map((row) => row.height)).toEqual(rows.map(() => line));
    expect(new Set(rows.map((row) => row.fontSize)).size).toBe(1);
    const pairs = rows.slice(1).map((row, index) => ({
      above: rows[index]!,
      row,
      gap: Math.round((row.top - (rows[index]!.top + rows[index]!.height)) * 10) / 10,
    }));
    // Outside a card, each step starts where the one above it ends.
    const outside = pairs.filter(({ above, row }) => above.card < 0 && row.card < 0);
    expect(outside.map(({ row, gap }) => ({ row: row.text, gap }))).toEqual(
      outside.map(({ row }) => ({ row: row.text, gap: 0 })),
    );
    // In a card, every step is one pitch below the one above it: the same gap, no drift.
    const inCard = pairs.filter(({ above, row }) => above.card >= 0 && above.card === row.card);
    expect(inCard.length).toBeGreaterThanOrEqual(2);
    expect(inCard.map(({ row, gap }) => ({ row: row.text, gap }))).toEqual(
      inCard.map(({ row }) => ({ row: row.text, gap: inCard[0]!.gap })),
    );
    expect(rows.length).toBeGreaterThanOrEqual(5);
    await page.close();
  });

  test("a finished thought is one quiet row that opens to its full text, wrapped, with no tooltip", async () => {
    const page = await open();
    await openRun(page);
    const toggle = page.locator("button.cv-thought");
    expect((await toggle.innerText()).trim()).toBe("Thought");
    expect(await page.locator(".cv-thought__body, .cv-thought__text").count()).toBe(0);
    await toggle.click();
    // The fold plays, then the text has its height.
    const thought = page.locator(".cv-thought__body");
    await page.waitForFunction(
      () => (document.querySelector(".cv-thought__body")?.getBoundingClientRect().height ?? 0) > 26,
      undefined,
      { timeout: 5_000 },
    );
    expect((await thought.innerText()).replace(/\s+/g, " ")).toContain(THOUGHT);
    expect(await thought.evaluate((node) => node.closest("[title]") === null && !node.querySelector("[title]"))).toBe(
      true,
    );
    // Wrapped, not cut: it is taller than one row and nothing in it overflows.
    const box = await thought.evaluate((node) => ({
      height: node.getBoundingClientRect().height,
      clipped: [...node.querySelectorAll<HTMLElement>("*")].some((child) => child.scrollWidth > child.clientWidth + 1),
    }));
    expect(box.height).toBeGreaterThan(26);
    expect(box.clipped).toBe(false);
    await page.close();
  });

  test("a tool run's summary line lights its words on hover only and keeps its glyph's tone", async () => {
    const page = await open();
    const run = page.locator(".acpmux-row button.cv-tool.is-run", { hasText: "Ran 2 commands" });
    const look = () =>
      run.evaluate((node) => ({
        text: getComputedStyle(node.querySelector(".cv-tool__text")!).color,
        icon: getComputedStyle(node.querySelector(".cv-tool__icon")!).color,
      }));
    await page.mouse.move(0, 0);
    const rest = await look();
    await run.hover();
    await page.waitForFunction((before) => {
      const text = document.querySelector(".acpmux-row button.cv-tool.is-run .cv-tool__text");
      return text && getComputedStyle(text).color !== before && !text.getAnimations().length;
    }, rest.text);
    const hovered = await look();
    expect(hovered.text).not.toBe(rest.text);
    expect(hovered.icon).toBe(rest.icon);
    // Open and still focused from the click, with the pointer gone, it is back at rest: only hover lights it.
    await run.click();
    await page.mouse.move(0, 0);
    await page.waitForFunction((before) => {
      const text = document.querySelector(".acpmux-row button.cv-tool.is-run .cv-tool__text");
      return text && getComputedStyle(text).color === before && !text.getAnimations().length;
    }, rest.text);
    expect(await run.getAttribute("aria-expanded")).toBe("true");
    expect(await run.evaluate((node) => node === document.activeElement)).toBe(true);
    expect(await look()).toEqual(rest);
    await page.close();
  });

  test("an inner step row reveals and lights its chevron only on hover", async () => {
    const page = await open();
    await openRun(page);
    const row = page.locator(".cv-steps > .cv-step > .cv-tool").first();
    const look = () =>
      row.evaluate((node) => {
        const chevron = node.querySelector<SVGElement>(".cv-tool__chevron");
        const icon = node.querySelector<HTMLElement>(".cv-tool__icon");
        const text = node.querySelector<HTMLElement>(".cv-tool__text, .cv-command__text");
        return {
          color: getComputedStyle(node).color,
          icon: icon ? getComputedStyle(icon).color : "none",
          text: text ? getComputedStyle(text).color : "none",
          chevron: chevron ? getComputedStyle(chevron).opacity : "none",
          width: node.getBoundingClientRect().width,
        };
      });
    const waitForChevron = (opacity: string) =>
      page.waitForFunction((expected) => {
        const chevron = document.querySelector<SVGElement>(".cv-steps > .cv-step > .cv-tool .cv-tool__chevron");
        return chevron && getComputedStyle(chevron).opacity === expected;
      }, opacity);
    await page.mouse.move(0, 0);
    await waitForChevron("0");
    const rest = await look();
    expect(rest.chevron).toBe("0");
    await row.hover();
    await waitForChevron("1");
    const hovered = await look();
    expect(hovered.chevron).toBe("1");
    expect(hovered.color).toBe(hovered.icon);
    expect(hovered.color).toBe(hovered.text);
    expect(hovered.color).not.toBe(rest.color);
    expect(hovered.width).toBe(rest.width);
    await row.click();
    await page.mouse.move(0, 0);
    await waitForChevron("1");
    const opened = await look();
    expect(opened.chevron).toBe("1");
    expect(opened.color).toBe(opened.icon);
    expect(opened.color).toBe(opened.text);
    await page.close();
  });
});
