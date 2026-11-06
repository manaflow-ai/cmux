// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo 2026-10-21: a long prompt collapses as Claude's does. A 2,000-line prompt from the chat's
// history draws its first ten lines (the last ones fading out under a mask) over Show more, so its
// bubble is at most about ten lines tall; Show more opens it in place and Show less closes it.
// The row's estimated height is its drawn one, so nothing below it moves when it mounts. A short
// prompt draws as before.
//
// Before: the bubble drew all 2,000 lines, about 45,000px of one prompt.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux that holds the chat's history.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-long-prompt.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-long-prompt: skipping (run `bunx playwright install chromium`)");
    describe.skip("long prompt", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c7";
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const LONG = Array.from({ length: 2000 }, (_, index) => `stack frame ${index + 1} at retry.ts:${index + 1}`).join(
    "\n",
  );
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: LONG, promptId: "prompt-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("The retry loop never resets its counter.")],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Fix it", promptId: "prompt-2" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Done.")],
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
    cwd: "/home/dev/api",
    title: "Retry",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 2,
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the transcript.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Fix it", { exact: true }).waitFor({ timeout: 25_000 });
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

  test("a 2,000-line prompt from history draws at most about ten lines tall, then opens and closes", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await page.goto(url());
    await page.getByText("Fix it", { exact: true }).waitFor();
    const longRow = page.locator("article[data-row-id='user-1']");
    await longRow.scrollIntoViewIfNeeded();
    const text = longRow.locator(".cv-user__text");
    await text.waitFor();
    const measure = () =>
      text.evaluate((node) => {
        const style = getComputedStyle(node);
        const bubble = node.closest(".cv-user__bubble")!.getBoundingClientRect().height;
        return {
          // Clamped, the text is a box; drawn whole it has none of its own (display: contents), and
          // its lines are its height.
          height: node.classList.contains("is-clamped")
            ? node.getBoundingClientRect().height
            : (() => {
                const range = document.createRange();
                range.selectNodeContents(node);
                return range.getBoundingClientRect().height;
              })(),
          bubble,
          lineHeight: parseFloat(style.lineHeight),
          mask: style.maskImage || style.getPropertyValue("-webkit-mask-image"),
        };
      });
    const closed = await measure();
    expect(closed.lineHeight).toBeGreaterThan(10);
    // At most ~10 lines: ten, with no part of an eleventh.
    expect(closed.height).toBeLessThanOrEqual(10 * closed.lineHeight + 1);
    expect(closed.height).toBeGreaterThanOrEqual(9 * closed.lineHeight);
    expect(closed.bubble).toBeLessThan(12 * closed.lineHeight + 40);
    // The last lines fade under a mask, not a solid cover.
    expect(closed.mask).toContain("gradient");

    // The row below starts one turn gap under the prompt's row: no overlap, no hole. On the layout
    // grid (#27580, leo-workspace design/grid.md 5.5) a row carries no gap of its own; the stack
    // places a prompt's neighbour `--grid-gap-turn` (32) away, read here as the pane draws it.
    const { gap, turnGap } = await page.evaluate(() => {
      const long = document.querySelector<HTMLElement>("article[data-row-id='user-1']")!.getBoundingClientRect();
      const after = long.bottom;
      const below = [...document.querySelectorAll<HTMLElement>("article[data-row-id]")]
        .map((row) => row.getBoundingClientRect())
        .filter((rect) => rect.top >= long.top + 1)
        .sort((a, b) => a.top - b.top)[0];
      const probe = document.createElement("div");
      probe.style.cssText = "position:absolute;visibility:hidden;height:var(--grid-gap-turn)";
      document.querySelector(".acpmux-thread")!.append(probe);
      const turnGap = probe.getBoundingClientRect().height;
      probe.remove();
      return { gap: below ? below.top - after : Number.NaN, turnGap };
    });
    expect(turnGap).toBeGreaterThan(0);
    expect(Math.abs(gap - turnGap)).toBeLessThan(1);

    // The toggle by its state, not its English words (REVIEW.md).
    const toggle = longRow.locator(".cv-user__more");
    expect(await toggle.getAttribute("aria-expanded")).toBe("false");
    await toggle.click();
    await longRow.locator(".cv-user__more[aria-expanded='true']").waitFor();
    const open = await measure();
    expect(open.height).toBeGreaterThan(1000 * open.lineHeight);
    expect(open.mask === "none" || open.mask === "").toBe(true);

    await toggle.click();
    await longRow.locator(".cv-user__more[aria-expanded='false']").waitFor();
    // Show less plays its fold (PromptText.tsx): the text shrinks back to its first lines, so the
    // clamp is measured once that ends.
    await text.evaluate((node) =>
      Promise.all(
        node
          .closest(".cv-user__bubble")!
          .getAnimations({ subtree: true })
          .map((animation) => animation.finished.catch(() => undefined)),
      ),
    );
    expect((await measure()).height).toBeLessThanOrEqual(10 * closed.lineHeight + 1);

    // The short prompt draws whole, with no toggle and no fade.
    const short = page.locator("article[data-row-id='user-5']");
    await short.scrollIntoViewIfNeeded();
    expect(await short.locator(".cv-user__more").count()).toBe(0);
    expect(await short.locator(".cv-user__text.is-faded").count()).toBe(0);
    await page.close();
  });
});
