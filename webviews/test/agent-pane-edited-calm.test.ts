// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// The Edited files card and the turn's diff stay small and calm (cx-ncc.99, Leo: "too big / too
// tonka toys"): nothing heavier than medium weight, file names in regular weight, paths in the
// chat's monospace with counts in tabular figures, compact rows, small radii and hairline rims,
// the card flush with the reply text, and diff lines no taller or larger than the terminal-sized
// code. The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in
// acpmux daemon (as agent-pane-edited-side.test.ts).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-edited-calm.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-edited-calm: skipping (run `bunx playwright install chromium`)");
    describe.skip("edited calm", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const edit = (id: string, path: string, oldText: string | null, newText: string): Step[] => [
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
  const steps: Step[] = [
    ["mux", "user_message", { text: "Add retry to the uploader" }],
    ["mux", "turn_started", {}],
    ...edit("e1", "/home/dev/uploader/src/net/upload.ts", "a\nb\n", "a\nretry\nb\nbackoff\n"),
    ...edit("e2", "/home/dev/uploader/README.md", "x\ny\n", "x\n"),
    ...edit("e3", "/home/dev/uploader/src/net/backoff.ts", null, "export const backoff = 2;\n"),
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

  /// Every element's computed look under `root`, pseudo rims included, for the bounds below.
  const looks = (page: import("playwright").Page, root: string) =>
    page.evaluate((query) => {
      const host = document.querySelector(query);
      if (!host) throw new Error(`no ${query}`);
      const px = (value: string) => Math.max(0, ...value.split(/[\s,]+/).map((part) => parseFloat(part) || 0));
      return [host, ...host.querySelectorAll("*")].flatMap((node) => {
        const style = getComputedStyle(node);
        const after = getComputedStyle(node, "::after");
        const shadows = [style.boxShadow, after.content === "none" ? "none" : after.boxShadow]
          .filter((shadow) => shadow !== "none")
          // An inset ring's width is its spread (the 4th length).
          .map((shadow) => [...shadow.matchAll(/(-?[\d.]+)px/g)].map((m) => parseFloat(m[1]!))[3] ?? 0);
        return [
          {
            cls: node.getAttribute("class") ?? node.tagName,
            text: node.children.length === 0 ? (node.textContent ?? "").trim() : "",
            weight: Number(style.fontWeight),
            radius: px(style.borderRadius),
            border: Math.max(
              ...["Top", "Right", "Bottom", "Left"].map((side) =>
                style.getPropertyValue(`border-${side.toLowerCase()}-style`) === "none"
                  ? 0
                  : parseFloat(style.getPropertyValue(`border-${side.toLowerCase()}-width`)) || 0,
              ),
            ),
            ring: Math.max(0, ...shadows),
          },
        ];
      });
    }, root);
  const style = (page: import("playwright").Page, selector: string, ...props: string[]) =>
    page.evaluate(
      ([query, names]) => {
        const node = document.querySelector(query as string);
        if (!node) throw new Error(`no ${query}`);
        const style = getComputedStyle(node);
        const rect = node.getBoundingClientRect();
        return {
          height: rect.height,
          left: rect.left,
          ...Object.fromEntries((names as string[]).map((name) => [name, style.getPropertyValue(name)])),
        } as Record<string, string | number>;
      },
      [selector, props] as const,
    );
  const calm = (list: Awaited<ReturnType<typeof looks>>) => {
    const loud = list.filter((one) => one.weight > 500).map((one) => `${one.cls} ${one.text} ${one.weight}`);
    const round = list.filter((one) => one.radius > 8).map((one) => `${one.cls} ${one.radius}`);
    const thick = list
      .filter((one) => one.border > 1 || one.ring > 1)
      .map((one) => `${one.cls} ${one.border}/${one.ring}`);
    return { loud, round, thick };
  };

  test("the card: regular weights, mono paths, tabular counts, compact rows, small radii, hairline rims", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    await page.locator(".acpmux-edited-file").first().waitFor();
    expect(calm(await looks(page, ".acpmux-edited"))).toEqual({ loud: [], round: [], thick: [] });
    expect((await style(page, ".acpmux-edited-base", "font-weight"))["font-weight"]).toBe("400");
    expect(String((await style(page, ".acpmux-edited-path", "font-family"))["font-family"])).toMatch(/mono|Menlo/i);
    expect(
      String(
        (await style(page, ".acpmux-edited-file .acpmux-diff-counts", "font-variant-numeric"))["font-variant-numeric"],
      ),
    ).toContain("tabular-nums");
    expect((await style(page, ".acpmux-edited-file")).height).toBeLessThanOrEqual(28);
    expect((await style(page, ".acpmux-edited-head")).height).toBeLessThanOrEqual(40);
    expect((await style(page, ".acpmux-review-changes")).height).toBeLessThanOrEqual(24);
    // No tile around the head's glyph.
    expect(
      await page.locator(".acpmux-edited-icon").evaluate((node) => node.getBoundingClientRect().width),
    ).toBeLessThanOrEqual(16);
    await page.close();
  });

  test("the card adds no left indent: it starts where the reply's text starts", async () => {
    const page = await browser!.newPage({ viewport: { width: 1200, height: 760 } });
    await page.goto(url(CHAT));
    const reply = page.getByText("Retry added to the uploader.");
    await reply.waitFor();
    const text = await reply.evaluate((node) => node.getBoundingClientRect().left);
    const card = (await style(page, ".acpmux-edited")).left as number;
    expect(Math.abs(card - text)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("the diff: a regular file header, plain-text badges, terminal-sized code lines", async () => {
    const page = await browser!.newPage({ viewport: { width: 1500, height: 800 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    await page.locator(".acpmux-edited-head .acpmux-review-changes").click();
    await page.locator(".acpmux-diff-panel .acpmux-file-header").first().waitFor();
    expect(calm(await looks(page, ".acpmux-diff-panel .acpmux-file-header")).loud).toEqual([]);
    expect((await style(page, ".acpmux-file-header")).height).toBeLessThanOrEqual(30);
    const badge = await style(page, ".acpmux-fh-badge", "background-color", "font-size");
    expect(badge["background-color"]).toBe("rgba(0, 0, 0, 0)");
    // Pierre draws the lines in its shadow root.
    const lines = await page.waitForFunction(() => {
      for (const host of document.querySelectorAll(".acpmux-diff-panel *")) {
        const line = host.shadowRoot?.querySelector("[data-line]");
        if (!line) continue;
        const style = getComputedStyle(line);
        return { size: parseFloat(style.fontSize), height: line.getBoundingClientRect().height };
      }
      return null;
    });
    const { size, height } = (await lines.jsonValue())!;
    expect(size).toBeLessThanOrEqual(12);
    expect(height).toBeLessThanOrEqual(19);
    await page.close();
  });
});
