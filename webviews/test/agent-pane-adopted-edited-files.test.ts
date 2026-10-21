// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reopened Codex turn that edited two files ends with the edited-files card (hq#2569 item 4):
// "Edited 2 files +4 -1" with a row and counts per file; View changes opens the turn's diff with
// its hunks; the chat menu lists Changes; the summary's Outputs lists the files.
//
// Before: the turn had no edit records, so none of these drew (#22155 replays them); with them,
// the chat menu still had no Changes (only the header button) and Outputs said "None" (its files
// were listed only under the summary's Changes).
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

await requireBrowserLane("agent-pane-adopted-edited-files.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-adopted-edited-files: skipping (run `bunx playwright install chromium`)");
    describe.skip("adopted edited files", () => test("chromium", () => {}));
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
  const events = replay.map((record) => ({ sessionId: CHAT, ...record }));
  const lastSeq = events.at(-1)!.seq;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/demo",
    title: "Bump the version",
    harness: "codex",
    family: "codex",
    status: "idle",
    turnCount: 1,
    updatedAt: events.at(-1)!.at,
  };
  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq };
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
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await page.goto(url());
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

  test("the edited-files card lists each file with its counts, and View changes opens the hunks", async () => {
    const page = await open();
    const card = page.locator(".acpmux-edited");
    await expect(card.locator(".acpmux-edited-title").innerText()).resolves.toMatch(/^Edited 2 files\s*\+4\s*-1/);
    const files = await card.locator(".acpmux-edited-file").allInnerTexts();
    expect(files.map((row) => row.replace(/\s+/g, " ").trim())).toEqual(["CHANGELOG.md +3 -0", "Cargo.toml +1 -1"]);
    // A reopened Codex edit is replayed as hunks, parts of each file (`_meta.acpmux.fragment`): no
    // whole-file text to put back, so the card offers no Undo the host would refuse.
    await card.hover();
    expect(await card.locator(".acpmux-edited-undo").count()).toBe(0);
    await card.getByRole("button", { name: "View changes" }).click();
    // The browser host has no pane beside the chat: the turn's diff opens in place, its hunks drawn.
    await page.getByText('version = "1.3.0"').first().waitFor();
    await page.getByText("- Bump the version to 1.3.0").first().waitFor();
    await page.close();
  });

  test("the chat menu lists Changes", async () => {
    const page = await open();
    await page.getByRole("button", { name: "Chat actions" }).click();
    const items = page.locator(".acpmux-chat-menu-item .acpmux-chat-menu-label");
    await items.first().waitFor();
    expect(await items.allTextContents()).toContain("Changes");
    await page.close();
  });

  test("the summary's Outputs lists the edited files", async () => {
    const page = await open();
    await page.getByRole("button", { name: "Chat summary" }).click();
    const outputs = page.locator('section[aria-label="Outputs"] li');
    await outputs.first().waitFor();
    const rows = (await outputs.allInnerTexts()).map((row) => row.replace(/\s+/g, " ").trim());
    expect(rows).toEqual(["CHANGELOG.md +3 -0", "Cargo.toml +1 -1"]);
    await page.close();
  });
});
