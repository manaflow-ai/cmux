// l10n-allow-file: test fixture prompts, thoughts and commands, not shipped UI.
// Every line in an opened "Worked for" group sits on the one 22px pitch (--cv-tool-row-height,
// design/chat-transcript.md "One-line row pitch"), whatever the line is: a thought first, a tool
// run, a background task's notice and the run the agent did after it. Leo, 2026-11-16, on two
// opened groups: "why is the spacing different on the first thinking tool call?" and "why is the
// background task space after so big".
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-worked-group-pitch-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-worked-group-pitch: skipping (run `bunx playwright install chromium`)");
    describe.skip("worked group pitch", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f9";
  const START = Date.UTC(2026, 10, 16, 18, 0, 0);
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  const think = (text: string): Step => [
    "in",
    "agent_thought_chunk",
    update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
  ];
  const ran = (id: string, command: string, kind = "execute"): Step => [
    "in",
    "tool_call",
    update({ sessionUpdate: "tool_call", toolCallId: id, title: command, kind, status: "completed" }),
  ];
  const THINKING_REPLY = "Linux hosts can share their screen once the portal is in.";
  const NOTICE_REPLY = "The quiet text change is pushed.";
  const steps: Step[] = [
    // Shot 1: a thought leads the turn's work.
    ["mux", "user_message", { text: "Does screen sharing work on Linux?", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    think("The question is about Linux, most likely host support for screen sharing and remote access."),
    ran("fetch", "git-fetch-once"),
    say("Checking the portal code."),
    ran("grep", "rg portal src"),
    ran("cat", "cat README.md"),
    say(THINKING_REPLY),
    ["mux", "turn_result", { turnId: "t1", status: "completed" }],
    // Shot 2: inside a prompt's turn, a background task's notice, then the run the agent did after it.
    ["mux", "user_message", { text: "Push the quiet text change", turnId: "t2" }],
    ["mux", "turn_started", { turnId: "t2" }],
    ran("push", "git push"),
    ["mux", "background_turn", { state: "started", id: "bg-1", trigger: "task_notification" }],
    [
      "mux",
      "user_message",
      {
        text: "<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command finished: cd ~/lane && git push (exit 0)</summary>\n</task-notification>",
        client: "adopt",
      },
    ],
    ran("log", "git log -1"),
    ran("read", "README.md", "read"),
    [
      "mux",
      "background_turn",
      { state: "ended", id: "bg-1", trigger: "task_notification", quiet: false, reason: "result" },
    ],
    say(NOTICE_REPLY),
    ["mux", "turn_result", { turnId: "t2", status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 7000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Worked group pitch",
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
  const atRest = (page: Page) =>
    page.evaluate(
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
  const open = async (): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 1400 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText(NOTICE_REPLY).waitFor();
    await page.mouse.move(0, 0);
    await atRest(page);
    // Open every turn's "Worked for" group.
    for (let pass = 0; pass < 4; pass += 1) {
      const shut = page.locator("button.cv-worked.is-toggle[aria-expanded='false']");
      if ((await shut.count()) === 0) break;
      await shut.first().click();
      await page.mouse.move(0, 0);
      await atRest(page);
    }
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText(NOTICE_REPLY).waitFor({ timeout: 25_000 });
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

  /// Every drawn one-line line in the transcript, top to bottom: a tool row, a thought, a
  /// disclosure line (a received notice), or a row of no such part; prose (`.cv-md`) and prompts
  /// break runs. Two lines in a row with no break between them are one pitch apart.
  const lines = (page: Page) =>
    page.evaluate(() => {
      const LINE = ".cv-tool, .cv-disclosure__line";
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter((row) => row.getBoundingClientRect().height > 0)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const out: { run: number; top: number; height: number; text: string; row: string }[] = [];
      const dump: string[] = [];
      let run = 0;
      for (const row of rows) {
        const box = row.getBoundingClientRect();
        dump.push(
          `${box.top.toFixed(1)}+${box.height.toFixed(1)} ${row.className.replace(/\s+/g, ".")} | ${(row.innerText || "").replace(/\s+/g, " ").slice(0, 70)}`,
        );
        const prose = row.querySelector(".cv-md, .cv-user__bubble, .cv-worked");
        const found = [...row.querySelectorAll<HTMLElement>(LINE)].filter(
          (node) => node.getBoundingClientRect().height > 0 && !node.parentElement?.closest(LINE),
        );
        if (prose && found.length === 0) {
          run += 1;
          continue;
        }
        if (found.length === 0) found.push(row);
        for (const node of found) {
          const rect = node.getBoundingClientRect();
          out.push({
            run,
            top: Math.round(rect.top * 10) / 10,
            height: Math.round(rect.height * 10) / 10,
            text: (node.textContent ?? "").trim().slice(0, 40),
            row: row.className.split(/\s+/).slice(1, 3).join("."),
          });
        }
        if (prose) run += 1;
      }
      return { out, dump };
    });

  test("every line of an opened Worked group sits one 22px pitch from the next", async () => {
    const page = await open();
    const { out: measured, dump } = await lines(page);
    const pitches = measured
      .slice(1)
      .map((line, index) => ({ prev: measured[index]!, line }))
      .filter(({ prev, line }) => prev.run === line.run)
      .map(({ prev, line }) => ({
        from: prev.text,
        to: line.text,
        pitch: Math.round((line.top - prev.top) * 10) / 10,
      }));
    // Base drew thought->next 26 and notice->next 54 (cmux#44818). WORKED_GROUP_PITCH_LOG=1 prints the rows.
    if (process.env.WORKED_GROUP_PITCH_LOG === "1") console.log(`rows\n${dump.join("\n")}\n${JSON.stringify(pitches)}`);
    const thought = pitches.find((pitch) => pitch.from.startsWith("The question is about Linux"));
    const notice = pitches.find((pitch) => pitch.from.includes("Background command finished"));
    expect(thought).toBeDefined();
    expect(notice).toBeDefined();
    for (const pitch of pitches) expect({ ...pitch, pitch: Math.round(pitch.pitch) }).toEqual({ ...pitch, pitch: 22 });
    await page.close();
  });
});
