// l10n-allow-file: test fixture prompts, thoughts and commands, not shipped UI.
// The steps of a turn read as one list (Leo 2026-10-13, cmux NEXT on macOS 27): tool calls,
// thoughts and a background shell's end all draw on one rhythm (22px since #24565), whether
// they share a transcript row or not. A finished thought is one quiet row like the others that
// opens to its full text, wrapped, with no tooltip (Leo 2026-10-20), and a row shows nothing more
// on hover: its disclosure chevron is there at rest.
//
// Before: the background task's end used a smaller font in a 22px row with its own margins, a
// step in the next transcript row sat 10px further down than one in the same row, a thought was
// cut to one line with the rest in a tooltip, and a hover brightened the row and showed its chevron.
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

  test("every step is one 22px row on one rhythm, across transcript rows", async () => {
    const page = await open();
    await openRun(page);
    const rows = await page.locator(".acpmux-row .cv-tool").evaluateAll((nodes) =>
      nodes.map((node) => {
        const box = node.getBoundingClientRect();
        return {
          text: node.textContent?.replace(/\s+/g, " ").trim().slice(0, 24) ?? "",
          top: Math.round(box.top),
          height: Math.round(box.height),
          fontSize: getComputedStyle(node).fontSize,
        };
      }),
    );
    // The finished thought is folded to one line too.
    expect(rows.map((row) => row.height)).toEqual(rows.map(() => 22));
    expect(new Set(rows.map((row) => row.fontSize)).size).toBe(1);
    // Each step starts where the one above it ends.
    const gaps = rows.slice(1).map((row, index) => row.top - (rows[index]!.top + rows[index]!.height));
    expect({ rows: rows.map((row) => row.text), gaps }).toEqual({
      rows: rows.map((row) => row.text),
      gaps: gaps.map(() => 0),
    });
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

  test("a step row shows nothing more on hover; its chevron is there at rest", async () => {
    const page = await open();
    const row = page.locator(".acpmux-row button.cv-tool").first();
    const look = () =>
      row.evaluate((node) => {
        const chevron = node.querySelector<SVGElement>(".cv-tool__chevron");
        return {
          color: getComputedStyle(node).color,
          chevron: chevron ? getComputedStyle(chevron).visibility : "none",
        };
      });
    await page.mouse.move(0, 0);
    const rest = await look();
    expect(rest.chevron).toBe("visible");
    await row.hover();
    expect(await look()).toEqual(rest);
    await page.close();
  });
});
