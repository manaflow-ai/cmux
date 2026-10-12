// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A prompt's versions in the real agent pane (cx-ncc.61, Claude parity). Edit and resend forked a chat
// before its second prompt and sent the edited prompt in the fork; acpmux copied the history into the
// fork and marked where it ends (`forked`). The page is the pane's dev entry with its browser host,
// talking JSON-RPC to a stand-in acpmux daemon that serves both chats.
//
// - The chat forked from shows 1/2 under the prompt the edit replaced; Next opens the fork.
// - The fork shows 2/2 under its edited prompt; Previous opens the chat forked from.
// - The prompt before the fork point, and a fork nobody sent in, have no versions.
// - Editing the fork's edited prompt again forks the chat forked from, at the same turn, so the new
//   version is a sibling (not a fork of the fork).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-branches.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-branches: skipping (run `bunx playwright install chromium`)");
    describe.skip("branches", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  // Session ids sort by creation time, as acpmux's UUIDv7s do.
  const PARENT = "0190a000-0000-7000-8000-000000000001";
  const FORK = "0190a000-0000-7000-8000-000000000002";
  const IDLE_FORK = "0190a000-0000-7000-8000-000000000003";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const turn = (prompt: string, reply: string): Step[] => [
    ["mux", "user_message", { text: prompt }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say(reply)],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = (sessionId: string, steps: Step[]) =>
    steps.map(([dir, kind, msg], index) => ({ sessionId, seq: index + 1, at: START + index * 1000, dir, kind, msg }));

  const first = turn("Add retry to the uploader", "Retry added.");
  // The parent: two turns. The fork went through the first (its turn_result is seq 4).
  const parentEvents = events(PARENT, [...first, ...turn("Now cover it with a test", "One test added.")]);
  const forkEvents = events(FORK, [
    ...first,
    ["mux", "forked", { parentId: PARENT, forkSeq: 4 }],
    ...turn("Now cover it with two tests", "Two tests added."),
  ]);
  const idleEvents = events(IDLE_FORK, [...first, ["mux", "forked", { parentId: PARENT, forkSeq: 4 }]]);
  const summary = (sessionId: string, title: string, turnCount: number, lineage?: object) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title,
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount,
    updatedAt: START,
    ...lineage,
  });
  const sessions = [
    summary(PARENT, "Uploader retry", 2),
    summary(FORK, "Uploader retry (edited)", 2, { parentId: PARENT, forkSeq: 4 }),
    summary(IDLE_FORK, "Uploader retry fork", 1, { parentId: PARENT, forkSeq: 4 }),
  ];
  const transcripts: Record<string, ReturnType<typeof events>> = {
    [PARENT]: parentEvents,
    [FORK]: forkEvents,
    [IDLE_FORK]: idleEvents,
  };

  const forks: Record<string, any>[] = [];

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: ["acp.session.fork"] } },
        };
      case "acp.session.fork":
        forks.push(params);
        return { sessionId: IDLE_FORK };
      case "_acpmux/watch":
        return { sessions };
      case "_acpmux/attach": {
        const chat = transcripts[params.sessionId] ?? parentEvents;
        return {
          session: sessions.find((entry) => entry.sessionId === params.sessionId),
          lastSeq: chat.length,
          events: chat,
        };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: (transcripts[params.sessionId] ?? []).length };
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
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the versions.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(PARENT));
        await warm.getByText("One test added.").waitFor({ timeout: 25_000 });
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

  /// The `n/m` under the prompt with this text, or null when it has no versions.
  const versionOf = (page: Page, prompt: string) =>
    page.evaluate((text) => {
      const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((node) => node.textContent === text);
      const row = bubble?.closest(".cv-user");
      return row?.querySelector(".cv-user__version-count")?.textContent ?? null;
    }, prompt);
  /// Waits until the prompt with this text shows `n/m` (the session list arrives after the transcript).
  const waitForVersion = (page: Page, prompt: string, version: string) =>
    page.waitForFunction(
      ([text, want]) => {
        const bubble = [...document.querySelectorAll(".cv-user__bubble")].find((node) => node.textContent === text);
        return bubble?.closest(".cv-user")?.querySelector(".cv-user__version-count")?.textContent === want;
      },
      [prompt, version],
      { timeout: 10_000 },
    );

  test("the replaced prompt and the edited one step between the chat and its edit", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(PARENT));
    await page.getByText("One test added.").waitFor();
    await waitForVersion(page, "Now cover it with a test", "1/2");
    expect(await versionOf(page, "Add retry to the uploader")).toBeNull();
    expect(await page.getByRole("button", { name: "Previous version" }).isDisabled()).toBe(true);

    await page.getByRole("button", { name: "Next version" }).click();
    await page.getByText("Two tests added.").waitFor();
    await waitForVersion(page, "Now cover it with two tests", "2/2");
    expect(await versionOf(page, "Add retry to the uploader")).toBeNull();
    expect(await page.getByRole("button", { name: "Next version" }).isDisabled()).toBe(true);

    await page.getByRole("button", { name: "Previous version" }).click();
    await page.getByText("One test added.").waitFor();
    await waitForVersion(page, "Now cover it with a test", "1/2");
    await page.close();
  });

  test("editing the fork's edited prompt forks the chat it came from at the same turn", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(FORK));
    await waitForVersion(page, "Now cover it with two tests", "2/2");
    const row = page.locator(".cv-user", { hasText: "Now cover it with two tests" });
    await row.hover();
    await row.getByRole("button", { name: "Edit" }).click();
    await page.getByRole("textbox", { name: "Edit your message" }).fill("Now cover it with three tests");
    await page.locator(".cv-user__edit").getByRole("button", { name: "Send" }).click();
    await page.waitForFunction(() => document.querySelector(".cv-user__edit") === null, undefined, { timeout: 10_000 });
    expect(forks).toEqual([{ sessionId: PARENT, throughSeq: 4 }]);
    await page.close();
  });
});
