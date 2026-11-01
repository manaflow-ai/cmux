// l10n-allow-file: test fixture prompts, not shipped UI.
// The transcript's edges fade instead of cutting rows (Leo 2026-10-14, as New Tab's list did in
// #19791): a soft edge under the header once the view has left the start, and above the composer while
// more lies below. Neither moves anything, and Reduce Transparency keeps plain edges.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-soft-edges.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-soft-edges: skipping (run `bunx playwright install chromium`)");
    describe.skip("soft edges", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000ed9e";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const steps: [string, string, Record<string, unknown>][] = [];
  for (let n = 1; n <= 40; n++)
    steps.push(
      ["mux", "user_message", { text: `Question ${n}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        update({
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: `Answer ${n}: the checks on the merged head are green.` },
        }),
      ],
      ["mux", "turn_result", { status: "completed" }],
    );
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
    cwd: "/home/dev/cmux",
    title: "Soft edges",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 40,
    updatedAt: START,
    lastSeq: events.length,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  /// The pane's socket, for streaming a reply into it.
  let socket: { send(data: string): void } | undefined;
  let seq = events.length;
  const send = (dir: string, kind: string, msg: Record<string, unknown>) =>
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: CHAT, seq: ++seq, at: START + seq * 1000, dir, kind, msg },
      }),
    );

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          socket = ws;
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Whether each edge of the scroller fades, and its box, which must not move.
  const edges = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const style = getComputedStyle(node);
      const mask = style.maskImage || style.webkitMaskImage || "none";
      const fades = (edge: string) =>
        mask !== "none" && parseFloat(style.getPropertyValue(`--acpmux-fade-${edge}`)) > 0;
      const box = node.getBoundingClientRect();
      return {
        top: fades("top"),
        bottom: fades("bottom"),
        box: `${box.x},${box.y},${box.width},${box.height}`,
      };
    });
  /// Until the transcript has held its scroll position over three painted frames with no animation
  /// left running: the view has followed what it was given and its edges have caught up.
  const settled = (page: Page) =>
    page.evaluate(async () => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      for (let tries = 0; tries < 20; tries++) {
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let last = -1;
          let still = 0;
          window.cmuxAfterPaint(() => {
            still = node.scrollTop === last ? still + 1 : 0;
            last = node.scrollTop;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
        if (finite().every((animation) => animation.playState !== "running")) return;
      }
    });
  const scrollTo = async (page: Page, where: "start" | "middle" | "end") => {
    await page.evaluate((where) => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const end = node.scrollHeight - node.clientHeight;
      node.scrollTop = where === "start" ? 0 : where === "end" ? end : end / 2;
    }, where);
    await settled(page);
  };

  test("the transcript fades under the header once scrolled, and above the composer while more lies below", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText("Question 40", { exact: true }).waitFor({ timeout: 60_000 });
    await settled(page);

    const latest = await edges(page);

    // Following a reply as it streams in, the line being written never fades: the view keeps up
    // with each chunk, so nothing ever lies below it.
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      (window as unknown as { fadedBottom: number }).fadedBottom = 0;
      new MutationObserver(() => {
        if (node.hasAttribute("data-fade-bottom")) (window as unknown as { fadedBottom: number }).fadedBottom++;
      }).observe(node, { attributes: true, attributeFilter: ["data-fade-bottom"] });
    });
    send("mux", "user_message", { text: "Question 41" });
    send("mux", "turn_started", {});
    // One chunk a painted frame: each lands, and is drawn, before the next comes.
    for (let chunk = 1; chunk <= 30; chunk++) {
      const text = `Paragraph ${chunk}: a client that fails waits longer before each retry.`;
      send(
        "in",
        "agent_message_chunk",
        update({
          sessionUpdate: "agent_message_chunk",
          content: {
            type: "text",
            text: `${text}\n\n`,
          },
        }),
      );
      await page.getByText(text, { exact: false }).waitFor({ timeout: 10_000 });
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    send("mux", "turn_result", { status: "completed" });
    await page.getByText("Paragraph 30", { exact: false }).waitFor({ timeout: 10_000 });
    await settled(page);
    expect(await page.evaluate(() => (window as unknown as { fadedBottom: number }).fadedBottom)).toBe(0);

    await scrollTo(page, "middle");
    const middle = await edges(page);
    await scrollTo(page, "start");
    const start = await edges(page);
    expect({ latest, middle, start }).toEqual({
      latest: { top: true, bottom: false, box: latest.box },
      middle: { top: true, bottom: true, box: latest.box },
      start: { top: false, bottom: true, box: latest.box },
    });

    // A floating jump button must not erase several extra text lines above the composer.
    // Paint a solid probe through the real scroller's alpha mask: 30px above the dock stays fully
    // legible, while the short edge still softens and everything below the dock stays hidden.
    await scrollTo(page, "middle");
    await page.locator(".acpmux-jump-latest[data-shown]").waitFor();
    const probe = await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const style = getComputedStyle(node);
      const box = node.getBoundingClientRect();
      document.querySelector<HTMLElement>(".acpmux-main")!.style.background = "black";
      node.style.background = "red";
      const foot = box.bottom - parseFloat(style.getPropertyValue("--acpmux-dock-space"));
      // In the right-hand gutter, past the rows' column and short of the scrollbar's lane: the rail's
      // lane on the left keeps full ink by design (conversation.css), so it is no probe for the mask.
      const lane = parseFloat(style.getPropertyValue("--acpmux-scrollbar-lane")) || 16;
      return { x: box.right - lane - 1, foot };
    });
    const pixels = PNG.sync.read(await page.screenshot());
    const redAt = (y: number) => pixels.data[(Math.floor(y) * pixels.width + Math.floor(probe.x)) * 4]!;
    expect(redAt(probe.foot - 30), "text more than one line above the dock stays opaque").toBeGreaterThan(240);
    expect(redAt(probe.foot - 2), "the short transition remains soft").toBeLessThan(100);
    expect(redAt(probe.foot + 4), "rows stay hidden beneath the dock").toBeLessThan(10);
    await page.evaluate(() => {
      document.querySelector<HTMLElement>(".acpmux-main")!.style.removeProperty("background");
      document.querySelector<HTMLElement>(".acpmux-scroll")!.style.removeProperty("background");
    });

    // Reduce Transparency: plain edges.
    await scrollTo(page, "middle");
    await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
    expect(await edges(page)).toEqual({ top: false, bottom: false, box: latest.box });
    await page.close();
  });
});
