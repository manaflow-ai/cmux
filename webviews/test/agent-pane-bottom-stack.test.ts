// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The chat's bottom stack (hq#1957, Leo 2026-10-14): the queued prompts and the composer card
// stack (a started chat has no folder strip, so the queue meets the card), under a question waiting
// for an answer, in the stack's own flow, so none overlaps another and none is clipped (the queue
// never covers Allow and Deny, hq #1893). The stack never takes the whole pane: the transcript keeps
// room, and the queue scrolls inside its own height instead. The page is the pane's dev entry with
// its browser host, talking JSON-RPC to a stand-in acpmux daemon whose chat opened three PRs and has
// a turn running, waiting on a permission, with six prompts queued behind it.
// The stack lies over the transcript's foot (Leo 2026-10-19, as the Claude and Codex apps lay their
// composer), and every part sits in the stack.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-bottom-stack.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-bottom-stack: skipping (run `bunx playwright install chromium`)");
    describe.skip("bottom stack", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const create = (id: string, title: string, number: number): Step[] => {
    const command = `gh pr create --title "${title}" --body x`;
    return [
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
          content: [
            { type: "content", content: { type: "text", text: `https://github.com/acme/uploader/pull/${number}\n` } },
          ],
          rawOutput: { exit_code: 0 },
        }),
      ],
    ];
  };
  const steps: Step[] = [
    ["mux", "user_message", { text: "Open the three PRs", promptId: "p-turn", turnId: "turn-1" }],
    ["mux", "turn_started", {}],
    ...create("t1", "Add retry to the uploader", 41),
    ...create("t2", "Cover retry with a test", 42),
    ...create("t3", "Document retry", 43),
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Three PRs open." } }),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "t4",
        title: "gh pr merge 41",
        kind: "execute",
        status: "pending",
        rawInput: { command: "gh pr merge 41" },
      }),
    ],
    [
      "mux",
      "permission_request",
      {
        permissionId: "p1",
        request: {
          toolCall: { toolCallId: "t4", title: "gh pr merge 41", kind: "execute" },
          options: [
            { optionId: "allow", name: "Allow", kind: "allow_once" },
            { optionId: "deny", name: "Deny", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const queue = ["first", "second", "third", "fourth", "fifth", "sixth"].map((prompt, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `${prompt} queued prompt`,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Uploader retry",
    harness: "claude",
    family: "claude",
    status: "running",
    steering: true,
    queuePaused: false,
    queued: queue.length,
    queue,
    turn: { turnId: "turn-1", promptId: "p-turn", startedAt: START, prompt: "Open the three PRs" },
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

  /// The chat drew its history: the PR commands' run, folded under its line with the short note
  /// "Three PRs open." in it, as the run after the note (the merge in flight) joins it
  /// (conversation/turns.ts mergeShortNotes, Debug toggle agentPane.debug.codexToolRuns).
  const drawn = (page: Page) => page.locator("button.cv-tool", { hasText: "Ran 3 commands" });

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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await drawn(warm).waitFor({ timeout: 25_000 });
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

  type Box = { name: string; top: number; bottom: number; left: number; right: number };
  /// The drawn boxes of the bottom stack's parts, the transcript and the chat column.
  const layout = (page: Page) =>
    page.evaluate(() => {
      const box = (name: string, selector: string) => {
        const node = document.querySelector(selector);
        if (!node) return undefined;
        const rect = node.getBoundingClientRect();
        return { name, top: rect.top, bottom: rect.bottom, left: rect.left, right: rect.right };
      };
      return {
        main: box("main", ".acpmux-main")!,
        transcript: box("transcript", ".acpmux-main .acpmux-scroll")!,
        stack: box("stack", ".acpmux-main > .acpmux-dock")!,
        parts: [
          box("ask", ".acpmux-asks-stack"),
          box("queue", ".acpmux-composer-queue"),
          box("fold", ".acpmux-queue-foldbar"),
          box("strip", ".acpmux-composer-strip"),
          box("card", ".acpmux-composer-box"),
        ].filter((part) => part !== undefined),
        queueScrolls: (() => {
          const queue = document.querySelector<HTMLElement>(".acpmux-composer-queue");
          return queue ? queue.scrollHeight > queue.clientHeight + 1 : false;
        })(),
      };
    });

  /// Every part drawn, inside the chat column, in the stack over the transcript's foot, and over no other part.
  function expectStacked({ main, stack, parts }: { main: Box; stack: Box; parts: Box[] }) {
    // The stack ends at the pane's bottom.
    expect({ stackToBottom: Math.abs(main.bottom - stack.bottom) <= 0.5 }).toEqual({ stackToBottom: true });
    // The chat has started: no location strip, and nothing left where it stood.
    // Six queued prompts fold: the fold's bar closes the queue, right on the card.
    expect(parts.map((part) => part.name)).toEqual(["ask", "queue", "fold", "card"]);
    const [queue, fold, card] = parts.slice(-3) as [Box, Box, Box];
    expect({ queueToFold: Math.abs(fold.top - queue.bottom) <= 0.5 }).toEqual({ queueToFold: true });
    expect({ foldToCard: Math.abs(card.top - fold.bottom) <= 0.5 }).toEqual({ foldToCard: true });
    for (const part of parts) {
      expect({ part: part.name, clipped: part.top < main.top - 0.5 || part.bottom > main.bottom + 0.5 }).toEqual({
        part: part.name,
        clipped: false,
      });
      expect({ part: part.name, outsideStack: part.top < stack.top - 0.5 }).toEqual({
        part: part.name,
        outsideStack: false,
      });
    }
    for (const [upper, lower] of parts.slice(0, -1).map((part, index) => [part, parts[index + 1]!] as const))
      expect({ pair: `${upper.name}/${lower.name}`, overlap: upper.bottom > lower.top + 0.5 }).toEqual({
        pair: `${upper.name}/${lower.name}`,
        overlap: false,
      });
  }

  async function open(height: number) {
    const page = await browser!.newPage({ viewport: { width: 900, height } });
    await page.goto(url());
    await drawn(page).waitFor();
    // Six queued prompts fold behind "4 more queued"; open it so the whole queue draws.
    await page.locator(".acpmux-queue-fold").click();
    await page.locator(".acpmux-queued", { hasText: "sixth" }).waitFor();
    return page;
  }

  test("the question, the queue and the card stack without overlapping or a gap where the strip was", async () => {
    const page = await open(760);
    const drawn = await layout(page);

    expectStacked(drawn);
    await page.close();
  });

  test("in a short pane the transcript keeps room and the queue scrolls inside its height", async () => {
    const page = await open(480);
    const drawn = await layout(page);
    expectStacked(drawn);
    // What shows of it above the stack: 96 px, less the 32 px the split's quiet row
    // under the card takes from it (bottomStack.css), never under 64.
    const split = await page.locator(".acpmux-composer-foot").count();
    expect(drawn.stack.top - drawn.transcript.top).toBeGreaterThanOrEqual(split ? 64 : 96);
    expect(drawn.queueScrolls).toBe(true);
    await page.close();
  });
  // Leo 2026-10-22: "how did the bottom overflow!? maybe not overflow... the access to the composer
  // got fucked". In a short pane the stack over the transcript (a question, the
  // queue) gave the composer less height than its card and quiet row need, so the quiet row (the
  // mode, the model, the context ring) ran past the pane's bottom edge and could not be clicked. The
  // other parts give up their height first, then the queue, then the card's draft, which scrolls.
  for (const height of [320, 400, 520])
    for (const lines of [0, 12])
      test(`in a ${height} px pane with a ${lines}-line draft the card and its quiet row stay inside and clickable`, async () => {
        const page = await open(height);
        const field = page.locator(".acpmux-composer-box .ProseMirror");
        if (lines) {
          await field.click();
          for (let line = 0; line < lines; line++) {
            if (line) await page.keyboard.press("Shift+Enter");
            await page.keyboard.type(`draft line ${line + 1}`);
          }
        }
        await page.locator(".acpmux-composer-foot .acpmux-picker-button").first().waitFor();
        const drawn = await page.evaluate(() => {
          const main = document.querySelector(".acpmux-main")!.getBoundingClientRect();
          const box = document.querySelector(".acpmux-composer-box")!.getBoundingClientRect();
          const foot = document.querySelector(".acpmux-composer-foot")!.getBoundingClientRect();
          // Every control of the quiet row and of the card's own row answers a click at its centre.
          const controls = [
            ...document.querySelectorAll<HTMLElement>(
              ".acpmux-composer-foot button, .acpmux-composer-box .acpmux-composer-inner button",
            ),
          ].filter((control) => control.offsetWidth > 0 && control.offsetHeight > 0);
          const unreachable = controls
            .filter((control) => {
              const rect = control.getBoundingClientRect();
              const hit = document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2);
              return !hit || !(control === hit || control.contains(hit));
            })
            .map((control) => control.getAttribute("aria-label") || control.textContent?.trim() || control.className);
          return {
            footInside: foot.bottom <= main.bottom + 0.5,
            boxAboveFoot: box.bottom <= foot.top + 0.5,
            boxHeight: Math.round(box.height),
            controls: controls.length,
            unreachable,
          };
        });
        await page.close();
        expect({
          footInside: drawn.footInside,
          boxAboveFoot: drawn.boxAboveFoot,
          unreachable: drawn.unreachable,
        }).toEqual({ footInside: true, boxAboveFoot: true, unreachable: [] });
        // The quiet row has the mode, the model and the ring; the card has + and the mic at least.
        expect(drawn.controls).toBeGreaterThanOrEqual(4);
        // The card keeps at least its one line.
        expect(drawn.boxHeight).toBeGreaterThanOrEqual(40);
      });
});
