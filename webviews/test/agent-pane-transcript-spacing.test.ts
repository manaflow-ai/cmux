// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The transcript's vertical rhythm, as Claude Code desktop sets it (Leo 2026-10-20: "weird amounts
// of negative space"): a message's meta row hugs it, a reply's footer sits right under the
// reply, and turns are a fixed gap apart. The spacing tokens are `--cv-meta-gap`, `--cv-meta-row`, `--cv-message-gap` and
// `--cv-turn-gap` in conversation/conversation.css.
//
// Before: an older prompt's hidden action row and the row's padding left a 40px band under its
// bubble, a reply's footer started about 22px under the reply, and a footer sat 8px over the next
// prompt.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-transcript-spacing.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-transcript-spacing: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript spacing", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f7";
  const START = Date.UTC(2026, 9, 20, 18, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Is the hosted test run done?", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("Checking the hosted run now.")],
    ["mux", "user_message", { text: "Also check the PR checks.", promptId: "p-2" }],
    ["in", "agent_message_chunk", say("Not yet: the hosted test run is still queued.")],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Ship it when green.", promptId: "p-3" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "run-1",
        title: "gh pr checks",
        kind: "execute",
        status: "in_progress",
      }),
    ],
    ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: "run-1", status: "completed" })],
    ["in", "agent_message_chunk", say("Meanwhile the PR checks are still waiting on the hosted run.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 9000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Hosted run",
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
  const open = async (): Promise<Page> => {
    // Shorter than the chat, so it opens at its bottom and the last footer's gap to the composer is
    // the transcript's runway; in a taller page a short chat sits at the top, far over the composer.
    const page = await browser!.newPage({ viewport: { width: 900, height: 420 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText("Meanwhile the PR checks").waitFor();
    await page.mouse.move(0, 0);
    // At rest: a frame has painted with no hover fade or other finite animation still running.
    await page.evaluate(
      () =>
        new Promise<void>((resolve) =>
          window.cmuxAfterPaint(() => {
            const moving = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            if (moving) return true;
            resolve();
            return false;
          }),
        ),
    );
    return page;
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
        await warm.getByText("Meanwhile the PR checks").waitFor({ timeout: 25_000 });
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

  /// The gaps that make the rhythm, in px, read off the drawn transcript at rest.
  const gaps = (page: Page) =>
    page.evaluate(() => {
      const bubble = (text: string) =>
        [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find((node) => node.textContent === text)!;
      const userRow = (text: string) => bubble(text).closest<HTMLElement>(".acpmux-row")!;
      const rowAfter = (row: HTMLElement) => {
        const top = row.getBoundingClientRect().bottom;
        return [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
          .filter((node) => node.getBoundingClientRect().top >= top - 1)
          .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top)[0]!;
      };
      const rect = (node: Element) => node.getBoundingClientRect();
      const reply = (text: string) =>
        [...document.querySelectorAll<HTMLElement>(".cv-md")].find((node) => node.textContent?.includes(text))!;

      const first = bubble("Is the hosted test run done?");
      const last = bubble("Ship it when green.");
      const lastActions = userRow("Ship it when green.").querySelector(".cv-user__actions")!;
      const afterFirst = rowAfter(userRow("Is the hosted test run done?"));
      const firstContent = afterFirst.querySelector(".cv-md, .cv-worked") ?? afterFirst;
      // A Claude turn's first run line, where a Codex turn draws Worked for (turns.ts claudeGroups).
      const worked = rowAfter(userRow("Ship it when green.")).querySelector(".cv-worked, .cv-tool");
      // Turn footers only: a reply's own row (cv-reply-actions) reuses their look.
      const footers = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions:not(.cv-reply-actions)")];
      const lastFooterTime = footers.at(-1)!.querySelector(".cv-turn-time")!;
      const lastReply = reply("Meanwhile the PR checks");
      const dock = document.querySelector<HTMLElement>(".acpmux-main[data-dock=float] > .acpmux-dock")!;
      // The reply's last line's text box (its content area, the line less its half-leading), the
      // footer's 24px line, and the next prompt's bubble: the line sits in the middle of that room.
      const lastLineBottom = (node: Element) => {
        const range = document.createRange();
        range.selectNodeContents(node);
        const lines = [...range.getClientRects()].filter((box) => box.height > 0);
        return lines.at(-1)!.bottom;
      };
      const firstFooter = footers[0]!;
      const firstFooterReply = reply("Not yet: the hosted test run");
      const lastFooter = footers.at(-1)!;
      return {
        footerRoomAbove: rect(firstFooter).top - lastLineBottom(firstFooterReply),
        footerRoomBelow: rect(last).top - rect(firstFooter).bottom,
        lastFooterRoomAbove: rect(lastFooter).top - lastLineBottom(lastReply),
        lastFooterRoomBelow: rect(dock).top - rect(lastFooter).bottom,
        metaRowUnderBubble: Math.round(rect(lastActions).top - rect(last).bottom),
        metaRowHeight: Math.round(rect(lastActions).height),
        olderPromptToNext: Math.round(rect(firstContent).top - rect(first).bottom),
        promptToWorked: worked ? Math.round(rect(worked).top - rect(lastActions).bottom) : -1,
        replyToFooterText: Math.round(rect(lastFooterTime).top - rect(lastReply).bottom),
        footerToNextPrompt: Math.round(rect(last).top - rect(footers[0]!).bottom),
        lastFooterToComposer: Math.round(rect(dock).top - rect(footers.at(-1)!).bottom),
      };
    });

  test("meta rows hug their message and the rhythm has no empty bands", async () => {
    const page = await open();
    const measured = await gaps(page);
    // The meta row starts 4px under its bubble and is one compact 24px line.
    expect(measured.metaRowUnderBubble).toBeGreaterThanOrEqual(2);
    expect(measured.metaRowUnderBubble).toBeLessThanOrEqual(6);
    expect(measured.metaRowHeight).toBeGreaterThanOrEqual(20);
    expect(measured.metaRowHeight).toBeLessThanOrEqual(24);
    // An older prompt's hidden row reserves only its own line (4 + 24), then the 8px message gap.
    expect(measured.olderPromptToNext).toBeLessThanOrEqual(37);
    // The turn's first line (a run's, in this Claude chat) follows the prompt's meta row at the message gap.
    expect(measured.promptToWorked).toBeGreaterThanOrEqual(0);
    expect(measured.promptToWorked).toBeLessThanOrEqual(10);
    // A reply's footer starts right under the reply.
    expect(measured.replyToFooterText).toBeGreaterThanOrEqual(0);
    expect(measured.replyToFooterText).toBeLessThanOrEqual(10);
    // Turns sit a fixed 16px apart (--cv-turn-gap, tightened from 24px in 4ae4a48893cf): the
    // footer's line to the next prompt.
    expect(measured.footerToNextPrompt).toBeGreaterThanOrEqual(12);
    expect(measured.footerToNextPrompt).toBeLessThanOrEqual(20);
    // The last footer uses that same turn gap before the floating composer; there is no extra
    // runway under every transcript.
    expect(measured.lastFooterToComposer).toBeGreaterThanOrEqual(12);
    expect(measured.lastFooterToComposer).toBeLessThanOrEqual(20);
    // A footer's line is centred between the reply's last line and what follows it, the next prompt
    // or the composer (Leo, 2026-10-31: "padding after == padding before that kinda thing all
    // around"). Before: 7px over it and 16px under.
    expect(Math.abs(measured.footerRoomAbove - measured.footerRoomBelow)).toBeLessThanOrEqual(1.5);
    expect(Math.abs(measured.lastFooterRoomAbove - measured.lastFooterRoomBelow)).toBeLessThanOrEqual(1.5);
    await page.close();
  });
});
