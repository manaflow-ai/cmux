// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The chat's pull requests above the composer (cx-ncc.81, Claude parity): each PR a `gh pr create`
// in the chat opened shows as a bar with its number, repository, title and state; a later
// `gh pr merge` takes its bar away (it lives in the right panel's Changes card). The newest two
// show, the rest behind Show more, and a bar's
// dismiss hides it for this chat, also after a reload. The page is the pane's dev entry with its
// browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-pr-dock.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-pr-dock: skipping (run `bunx playwright install chromium`)");
    describe.skip("pr dock", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000b1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// A shell call that ran `command` and printed `output`.
  const shell = (id: string, command: string, output: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: output } }],
        rawOutput: { exit_code: 0 },
      }),
    ],
  ];
  const create = (id: string, title: string, number: number) =>
    shell(id, `gh pr create --title "${title}" --body x`, `https://github.com/acme/uploader/pull/${number}\n`);
  const steps: Step[] = [
    ["mux", "user_message", { text: "Open the four PRs, then merge the first" }],
    ["mux", "turn_started", {}],
    ...create("t1", "Add retry to the uploader", 41),
    ...create("t2", "Cover retry with a test", 42),
    ...create("t3", "Document retry", 43),
    ...create("t4", "Log each retry", 44),
    ...shell("t5", "gh pr merge 41 --squash", "Merged"),
    ["in", "agent_message_chunk", say("Four PRs open, the first merged.")],
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
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the bars.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Four PRs open, the first merged.").waitFor({ timeout: 25_000 });
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

  /// Each bar above the composer: its number, repository, title and state.
  const bars = (page: import("playwright").Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll(".acpmux-pr-dock__bar")].map((bar) => [
        bar.querySelector(".acpmux-pr-dock__number")?.textContent,
        bar.querySelector(".acpmux-pr-dock__repo")?.textContent,
        bar.querySelector(".acpmux-pr-dock__title")?.textContent,
        bar.getAttribute("data-state"),
      ]),
    );

  test("the chat's pull requests show above the composer, newest first", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url(CHAT));
    await page.getByText("Four PRs open, the first merged.").waitFor();
    await page.locator(".acpmux-pr-dock").waitFor({ timeout: 10_000 });
    expect(await bars(page)).toEqual([
      ["#44", "uploader", "Log each retry", "open"],
      ["#43", "uploader", "Document retry", "open"],
    ]);
    expect(await page.locator(".acpmux-pr-dock__bar").first().getAttribute("href")).toBe(
      "https://github.com/acme/uploader/pull/44",
    );
    // Each one a chip as wide as its text, its dismiss button inside, and no tooltip (Leo, 2026-10-13).
    const chip = await page.evaluate(() => {
      const dock = document.querySelector(".acpmux-pr-dock")!.getBoundingClientRect();
      const chip = document.querySelector(".acpmux-pr-dock__chip")!;
      const box = chip.getBoundingClientRect();
      const x = chip.querySelector(".acpmux-pr-dock__dismiss")!.getBoundingClientRect();
      return {
        narrower: box.width < dock.width / 2,
        inside: x.left >= box.left && x.right <= box.right && x.top >= box.top && x.bottom <= box.bottom,
        titles: chip.querySelectorAll("[title], [data-tooltip]").length + (chip.hasAttribute("title") ? 1 : 0),
      };
    });
    expect(chip).toEqual({ narrower: true, inside: true, titles: 0 });
    // The dock takes its own space in the bottom stack (Leo, 2026-10-14: the PR chip sat over the chat):
    // the transcript runs under the stack (bottomStack.css), and keeps its last line above the dock
    // when scrolled to the end, at any height.
    for (const height of [760, 360]) {
      await page.setViewportSize({ width: 900, height });
      const overlap = await page.evaluate(async () => {
        const scroller = document.querySelector(".acpmux-scroll")!;
        scroller.scrollTop = scroller.scrollHeight;
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        const dock = document.querySelector(".acpmux-pr-dock")!.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll(".acpmux-row")].map((row) => row.getBoundingClientRect());
        const last = Math.max(...rows.map((row) => Math.min(row.bottom, scroller.getBoundingClientRect().bottom)));
        const stack = document.querySelector(".acpmux-main > .acpmux-dock")!.getBoundingClientRect();
        return {
          // The stack holds the dock: nothing of the stack lies above it but the stack's own parts.
          dockInStack: dock.top >= stack.top - 0.5,
          lastLine: Math.max(0, Math.round(last - dock.top)),
        };
      });
      expect(overlap).toEqual({ dockInStack: true, lastLine: 0 });
    }
    await page.setViewportSize({ width: 900, height: 760 });

    // The merged #41 keeps no bar, even behind Show more.
    await page.getByRole("button", { name: "Show 1 more" }).click();
    expect((await bars(page)).map((bar) => bar[0])).toEqual(["#44", "#43", "#42"]);

    await page.getByRole("button", { name: "Dismiss pull request #44" }).click();
    expect((await bars(page)).map((bar) => bar[0])).toEqual(["#43", "#42"]);
    // Focus moves to the bar now in its place, not the page.
    expect(await page.evaluate(() => document.activeElement?.getAttribute("aria-label"))).toBe(
      "Dismiss pull request #43",
    );
    // Dismissed for this chat: a reload keeps it hidden.
    await page.reload();
    await page.getByText("Four PRs open, the first merged.").waitFor();
    await page.locator(".acpmux-pr-dock").waitFor({ timeout: 10_000 });
    expect((await bars(page)).map((bar) => bar[0])).toEqual(["#43", "#42"]);
    await page.close();
  });
  test("the default compact count reveals Session Info Changes and retains PR actions", async () => {
    const page = await browser!.newPage({ viewport: { width: 1200, height: 900 } });
    try {
      await page.goto(url(CHAT));
      await page.getByText("Four PRs open, the first merged.").waitFor();
      await page.evaluate(() => {
        (
          window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
        ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
      });
      const dock = page.locator('.acpmux-pr-dock[data-mode="compact"]');
      await dock.waitFor();
      expect(await page.evaluate(() => document.documentElement.dataset.prDock)).toBeUndefined();
      expect(await dock.locator(".acpmux-pr-dock__bar").count()).toBe(0);
      // Includes the merged PR, exactly as Changes does.
      expect(await dock.locator(".acpmux-pr-dock__count").first().innerText()).toBe("4 PRs");
      const panel = page.locator("aside.acpmux-chat-inspector");
      const toggle = page.locator("button.acpmux-chat-inspector-toggle");
      if (await panel.isVisible()) await toggle.click();
      await panel.waitFor({ state: "detached" });
      await dock.locator(".acpmux-pr-dock__count").first().click();
      const changes = panel.locator('section[data-section="changes"]');
      await changes.getByText("Add retry to the uploader", { exact: true }).waitFor();
      expect(await changes.getAttribute("data-revealed")).not.toBeNull();
      expect(await changes.innerText()).toContain("Add retry to the uploader");
      expect(await changes.locator(".acpmux-chat-inspector-section__value").innerText()).toBe("4");
      await toggle.click();
      await panel.waitFor({ state: "detached" });
      const disclosure = dock.locator(".acpmux-pr-dock__disclosure");
      await disclosure.click();
      await page.keyboard.press("Escape");
      expect(await disclosure.getAttribute("aria-expanded")).toBe("false");
      await page.waitForFunction(() => document.activeElement?.classList.contains("acpmux-pr-dock__disclosure"));
      await disclosure.click();
      await page.mouse.click(20, 200);
      // An inline disclosure stays open while the user reads the chat.
      expect(await disclosure.getAttribute("aria-expanded")).toBe("true");
      const link = page.locator(".acpmux-pr-dock__list .acpmux-pr-dock__bar").first();
      await link.focus();
      await page.locator(".acpmux-pr-card").waitFor();
      expect(await page.locator(".acpmux-pr-card").innerText()).toContain("Log each retry");
      await page.locator(".acpmux-pr-dock__list .acpmux-pr-dock__dismiss").first().click();
      expect(await page.locator(".acpmux-pr-dock__list .acpmux-pr-dock__bar").count()).toBe(3);
      expect(await dock.locator(".acpmux-pr-dock__count").first().innerText()).toBe("4 PRs");
      expect(await page.evaluate(() => document.activeElement?.getAttribute("aria-label"))).toBe(
        "Dismiss pull request #43",
      );
      for (let remaining = 3; remaining > 0; remaining--)
        await dock.locator(".acpmux-pr-dock__dismiss").first().click();
      expect(await dock.locator(".acpmux-pr-dock__disclosure").count()).toBe(0);
      expect(await dock.locator(".acpmux-pr-dock__count").first().innerText()).toBe("4 PRs");
      expect(
        await dock
          .locator(".acpmux-pr-dock__count")
          .first()
          .evaluate((element) => element === document.activeElement),
      ).toBe(true);
    } finally {
      await page.close();
    }
  });
});
