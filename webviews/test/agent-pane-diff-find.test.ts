// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// Find in the changes view (cx-ncc.85, Claude parity). With the diff open and the keyboard in it,
// Find (Cmd-F, the app's Edit menu) opens a find bar over the diff instead of the chat's: it counts
// the query's matches in the changed lines, highlights them, and Enter steps through them, scrolling
// each into view. Escape closes it. The keyboard in the transcript beside a wide diff still finds
// in the chat. The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-diff-find.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-diff-find: skipping (run `bunx playwright install chromium`)");
    describe.skip("diff find", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000d7";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const edit = (id: string, path: string, oldText: string, newText: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: `Edit ${path}`,
        kind: "edit",
        status: "in_progress",
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "diff", path, oldText, newText }],
      }),
    ],
  ];
  // A long run of added lines between two matches, so stepping to the second one scrolls.
  const filler = Array.from({ length: 60 }, (_, i) => `const line${i} = ${i};\n`).join("");
  const extra = Array.from({ length: 40 }, (_, i) => `const extra${i} = ${i};\n`).join("");
  const steps: Step[] = [
    ["mux", "user_message", { text: "Add retry to the uploader" }],
    ["mux", "turn_started", {}],
    ...edit(
      "e1",
      "/home/dev/uploader/src/upload.ts",
      `export const timeout = 5;\n${filler}export const done = true;\n`,
      `export const timeout = 5;\n${filler}export const done = true;\nexport const retryDelay = 250;\n${extra}export const retryLimit = 5;\n`,
    ),
    ...edit("e2", "/home/dev/uploader/README.md", "Uploads files.\n", "Uploads files, with retry.\n"),
    ["in", "agent_message_chunk", say("Retry added to the uploader.")],
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
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, any>;
          };
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
    // again if it stalls, so the test times only the card.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Retry added to the uploader.").waitFor({ timeout: 25_000 });
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

  /** Reads until `read` gives `want` (each read is a round trip to the page; 5 s at most), then checks it. */
  async function until<T>(read: () => Promise<T>, want: T) {
    let got = await read();
    for (const deadline = Date.now() + 5_000; !Bun.deepEquals(got, want) && Date.now() < deadline;) got = await read();
    expect(got as unknown).toEqual(want);
  }
  /** The diff find's highlights: how many matches and the active one's text and line. */
  const highlights = (page: import("playwright").Page) =>
    page.evaluate(() => {
      const registry = (CSS as unknown as { highlights: Map<string, Set<Range>> }).highlights;
      const all = registry.get("cmux-find-match");
      const active = [...(registry.get("cmux-find-active") ?? [])][0];
      const row = active?.startContainer.parentElement?.closest("[data-line]");
      const body = document.querySelector(".acpmux-diff-body")!.getBoundingClientRect();
      const rect = active?.getBoundingClientRect();
      return {
        count: (all?.size ?? 0) + (active ? 1 : 0),
        active: active?.toString(),
        line: row?.getAttribute("data-line"),
        onScreen: rect ? rect.top >= body.top && rect.bottom <= body.bottom : false,
      };
    });
  const openDiff = async (page: import("playwright").Page) => {
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    await page.locator(".acpmux-edited-head .acpmux-review-changes").click();
    await page.locator(".acpmux-diff-panel [data-line]").first().waitFor();
  };
  const command = (page: import("playwright").Page, name: string) =>
    page.evaluate((name) => (window as any).cmuxAcpmuxBridge.command(name), name);

  test("Find with the keyboard in the diff finds in the changed lines", async () => {
    const page = await browser!.newPage({ viewport: { width: 1500, height: 520 } });
    await openDiff(page);
    await page.locator(".acpmux-diff-back").focus();
    await command(page, "find");
    const field = page.locator(".acpmux-diff-panel").getByRole("searchbox", { name: "Find in Changes" });
    await field.waitFor({ timeout: 5_000 });
    expect(await field.evaluate((node) => node === document.activeElement)).toBe(true);
    expect(await page.locator(".acpmux-scroll .acpmux-find").count()).toBe(0);
    await field.fill("retry");
    const count = page.locator(".acpmux-diff-panel .acpmux-find .find-pill__count");
    await until(() => count.textContent(), "1 of 3");
    await until(async () => (await highlights(page)).count, 3);
    expect((await highlights(page)).active?.toLowerCase()).toBe("retry");
    expect((await highlights(page)).line).toBe("63");
    // The diff's matches in order: retryDelay, retryLimit 41 lines below it, then README's.
    await field.press("Enter");
    await until(() => count.textContent(), "2 of 3");
    await until(async () => (await highlights(page)).line, "104");
    expect((await highlights(page)).onScreen).toBe(true);
    await field.press("Enter");
    await until(() => count.textContent(), "3 of 3");
    await field.press("Shift+Enter");
    await until(() => count.textContent(), "2 of 3");
    await field.press("Escape");
    await until(() => field.count(), 0);
    expect((await highlights(page)).count).toBe(0);
    await page.close();
  });

  test("Find with the keyboard in the transcript beside the diff still finds in the chat", async () => {
    const page = await browser!.newPage({ viewport: { width: 1500, height: 520 } });
    await openDiff(page);
    await page.locator(".acpmux-scroll .acpmux-edited-head .acpmux-review-changes").focus();
    await command(page, "find");
    await page.getByRole("searchbox", { name: "Find in Chat" }).waitFor({ timeout: 5_000 });
    expect(await page.locator(".acpmux-diff-panel .acpmux-find").count()).toBe(0);
    await page.close();
  });
});
