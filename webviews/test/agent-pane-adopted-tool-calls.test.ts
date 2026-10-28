// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reopened Codex chat shows each turn's work (hq#2569 item 3): the turn that ran three commands
// and edited two files opens its "Worked for 1m 32s" line to those calls, grouped as the pane
// groups a live turn's ("Ran 3 commands", "Edited 2 files +4 -1"), and each command opens to its
// line.
//
// Before: adopting a Codex chat replayed only the prompt and the final answer, so the turn showed
// the answer and a "Worked for 1m 32s" footer that opened nothing.
//
// The records are acpmux's own replay of a Codex rollout (`adopt_replays_a_codex_turns_commands_and_file_edits`
// in cmux-tui/crates/acpmux/tests/hub_integration/adopt.rs writes the fixture). The page is the
// pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux serving them.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-adopted-tool-calls.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-adopted-tool-calls: skipping (run `bunx playwright install chromium`)");
    describe.skip("adopted tool calls", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f7";
  const ANSWER = "Bumped demo to 1.3.0";
  const replay = (await Bun.file(path.join(import.meta.dir, "fixtures/adopted-codex-turn.events.json")).json()) as {
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: unknown;
  }[];
  // The same turn, its edit recorded as a patch whose files only its input names: no diffs and
  // no locations, as an edit too big to draw or a harness that sends no diff content.
  const PATCH_CHAT = "0190a000-0000-7000-8000-0000000000f8";
  const patchOnly = replay.map((record) => {
    const update = (record.msg as { params?: { update?: Record<string, unknown> } }).params?.update;
    if (!update || (update.toolCallId !== "exec-4" && update.kind !== "edit")) return record;
    const { locations: _locations, content: _content, ...rest } = update;
    const params = (record.msg as { params: Record<string, unknown> }).params;
    return { ...record, msg: { ...(record.msg as object), params: { ...params, update: rest } } };
  });
  const chats = new Map(
    [
      [CHAT, replay],
      [PATCH_CHAT, patchOnly],
    ].map(([id, records]) => {
      const events = (records as typeof replay).map((record) => ({ sessionId: id as string, ...record }));
      const session = {
        sessionId: id as string,
        cwd: "/home/dev/demo",
        title: "Bump the version",
        harness: "codex",
        family: "codex",
        status: "idle",
        turnCount: 1,
        updatedAt: events.at(-1)!.at,
      };
      return [id as string, { session, events, lastSeq: events.at(-1)!.seq }];
    }),
  );
  function answer(method: string, params: { sessionId?: string } = {}): unknown {
    const chat = chats.get(params.sessionId ?? CHAT) ?? chats.get(CHAT)!;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [...chats.values()].map((c) => c.session) };
      case "_acpmux/attach":
        return { session: chat.session, lastSeq: chat.lastSeq, events: chat.events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chat.lastSeq };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (chat = CHAT) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat}`;
  };
  const open = async (chat = CHAT): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await page.goto(url(chat));
    await page.getByText(ANSWER).waitFor();
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { sessionId?: string } };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
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
        await warm.getByText(ANSWER).waitFor({ timeout: 25_000 });
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

  test("the adopted turn's Worked for opens to its commands and edited files", async () => {
    const page = await open();
    const worked = page.locator("button.cv-worked");
    await expect(worked.textContent()).resolves.toBe("Worked for 1m 32s");
    expect(await worked.getAttribute("aria-expanded")).toBe("false");
    await worked.click();
    expect(await worked.getAttribute("aria-expanded")).toBe("true");

    // The default Codex-style run summarizes the replay's commands and edits together. Open it
    // before inspecting the same command and edit groups it holds.
    const run = page.locator("button.cv-tool", { hasText: "Ran 3 commands, edited 2 files" });
    await run.waitFor();
    expect(await run.getAttribute("aria-expanded")).toBe("false");
    await run.click();
    const commands = page.locator(".cv-tool-run button.cv-tool", { hasText: "Ran 3 commands" });
    const edits = page.locator(".cv-tool-run button.cv-tool", { hasText: "Edited 2 files" });
    await commands.waitFor();
    await expect(edits.textContent()).resolves.toBe("Edited 2 files+4-1");

    const lines = await page.locator(".cv-command__line").allTextContents();
    expect(lines).toEqual(["git status --short", "grep -n '^version' Cargo.toml", "sed -n 1,8p CHANGELOG.md"]);
    // The answer stays outside the fold, after the work.
    await page.getByText(ANSWER).waitFor();
    await page.close();
  });

  test("a patch whose files only its input names counts each file, not one", async () => {
    const page = await open(PATCH_CHAT);
    await page.locator("button.cv-worked").click();
    await page.locator("button.cv-tool", { hasText: "Ran 3 commands, edited 2 files" }).click();
    await page.locator(".cv-tool-run button.cv-tool", { hasText: "Ran 3 commands" }).waitFor();
    // With no diff the edit keeps its own row; it names both files' count, not the first file. Its
    // label, not the whole row: the row also holds the call's check and time, shown on hover.
    const edit = page.locator(".cv-tool .cv-tool__text", { hasText: /^Edit \d+ files$/ });
    await expect(edit.textContent()).resolves.toBe("Edit 2 files");
    await page.close();
  });
});
