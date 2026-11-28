// cmux-web-test-timeout: 400
// l10n-allow-file: synthetic CMUX-896 report-shaped conversation, not shipped UI.
// Inspect settled text before any scroll can repair a stale placement or retained clip.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-rich-followup-browser.test.ts", async () => {
  const { createServer } = await import("vite");
  const sessionId = "0190a000-0000-7000-8000-0000000000e6";
  type Event = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
  let events: Event[] = [];
  let status = "idle";
  let socket: { send(data: string): void } | undefined;
  const summary = () => ({
    sessionId,
    cwd: "/home/dev/example",
    title: "Rich follow-up",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 1,
    updatedAt: Date.now(),
  });
  function record(dir: string, kind: string, msg: Record<string, unknown>) {
    const event = { sessionId, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  }
  function emit(dir: string, kind: string, msg: Record<string, unknown>) {
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
  }
  const chunk = (text: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
    },
  });
  function changed() {
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId, session: summary(), kind: "queue", seq: events.length },
      }),
    );
  }
  function begin(id: string, text: string) {
    status = "running";
    emit("mux", "user_message", { text, promptId: id });
    emit("mux", "turn_started", {});
    changed();
  }
  function finish() {
    emit("mux", "turn_result", { status: "completed" });
    status = "idle";
    changed();
  }
  const richReply = [
    "Here is what happens when the push completes.\n\n",
    ...Array.from(
      { length: 6 },
      (_, index) =>
        `${index + 1}. Review the completed change and its browser evidence before continuing to the next reply.\n   - Read the \`session/update\` event and [verification notes](https://example.com/notes).\n   - Keep the measured row height with the text it describes as this sentence wraps onto more lines.\n\n`,
    ),
    "Previous rich reply end.\n\n",
  ];
  const followup = [
    "The MCP interception is a rerouting step.\n\n",
    "### What it does\n\nIt routes the request through the same session and preserves the reply.\n\n",
    "### Why I added it\n\n- Keep the response in order.\n- Preserve the earlier numbered list.\n\n",
    "### Why the review blocked it\n\nThe next reply must remain readable below the earlier reply.\n\nRich follow-up end.",
  ];
  let daemon: ReturnType<typeof Bun.serve>;
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    if (await probeEngineOrSkip("rich follow-up", name, engine))
      browsers.set(name, await engine.launch({ headless: true }));
  }
  if (browsers.size === 0) return;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.method === "_acpmux/attach") socket = ws;
          let result: unknown = null;
          if (message.method === "initialize")
            result = {
              protocolVersion: 1,
              _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
            };
          if (message.method === "_acpmux/watch") result = { sessions: [summary()] };
          if (message.method === "_acpmux/attach") result = { session: summary(), lastSeq: events.length, events };
          if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: events.length };
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        },
      },
    });
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
  }, 120_000);
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function inspectSettled(page: Page) {
    await page.getByText("Rich follow-up end.", { exact: false }).waitFor();
    // Wait on actual motion completion, without scrolling or changing layout styles.
    await page.waitForFunction(
      () =>
        document
          .querySelector(".acpmux-scroll")!
          .getAnimations({ subtree: true })
          .every(
            (animation) =>
              animation.playState !== "running" || animation.effect?.getComputedTiming().iterations === Infinity,
          ),
      undefined,
      { timeout: 15_000 },
    );
    return page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-row:not(.acpmux-row--fold-ghost)")];
      const problems: string[] = [];
      const spans: { id: string; top: number; bottom: number; left: number; right: number }[] = [];
      let proseLines = 0;
      let previousEnd = false;
      let finalEnd = false;
      let visiblePreviousEnd = false;
      let visibleFinalEnd = false;
      let previousEndBottom = -Infinity;
      let finalReplyTop = Infinity;
      for (const row of rows) {
        const id = row.dataset.rowId ?? String(rows.indexOf(row));
        if (getComputedStyle(row).contentVisibility === "auto" && !row.checkVisibility({ contentVisibilityAuto: true }))
          continue;
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        for (let text = walker.nextNode(); text; text = walker.nextNode()) {
          if (!text.textContent?.trim()) continue;
          const prose = !!text.parentElement?.closest(".cv-reply");
          const range = document.createRange();
          range.selectNodeContents(text);
          const rects = [...range.getClientRects()].filter((rect) => rect.height > 0 && rect.width > 0);
          if (prose && !rects.length) problems.push(`${id}: prose has no painted extent`);
          const parentStyle = getComputedStyle(text.parentElement!);
          const lead =
            Math.max(0, (Number.parseFloat(parentStyle.lineHeight) || 0) - Number.parseFloat(parentStyle.fontSize)) / 2;
          let top = -Infinity;
          let bottom = Infinity;
          let visible = true;
          for (let node = text.parentElement; node && node !== row.parentElement; node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.display === "none" || style.visibility !== "visible" || Number(style.opacity) < 0.99)
              visible = false;
            const box = node.getBoundingClientRect();
            if (style.overflowY !== "visible") {
              top = Math.max(top, box.top);
              bottom = Math.min(bottom, box.bottom);
            }
            const clip = /^inset\(([^)]*)\)/.exec(style.clipPath);
            if (clip) {
              const sides = clip[1]!.split(/\s+/).map((value) => Number.parseFloat(value) || 0);
              top = Math.max(top, box.top + (sides[0] ?? 0));
              bottom = Math.min(bottom, box.bottom - (sides[2] ?? sides[0] ?? 0));
            } else if (prose && style.clipPath !== "none") problems.push(`${id}: unexpected clip ${style.clipPath}`);
          }
          if (prose) {
            if (!visible) problems.push(`${id}: prose is hidden`);
            if (rects.some((rect) => rect.top + lead < top - 1 || rect.bottom - lead > bottom + 1))
              problems.push(`${id}: prose is clipped`);
            proseLines += rects.length;
            previousEnd ||= text.textContent.includes("Previous rich reply end.");
            finalEnd ||= text.textContent.includes("Rich follow-up end.");
          }
          if (!visible) continue;
          for (const rect of rects) {
            const clippedTop = Math.max(rect.top + lead, top, view.top);
            const clippedBottom = Math.min(rect.bottom - lead, bottom, view.bottom);
            if (clippedBottom > clippedTop && prose) {
              if (text.textContent.includes("Previous rich reply end.")) {
                visiblePreviousEnd = true;
                previousEndBottom = Math.max(previousEndBottom, clippedBottom);
              }
              if (text.textContent.includes("Rich follow-up end.")) visibleFinalEnd = true;
              if (text.parentElement?.closest(".cv-reply")?.textContent?.includes("Rich follow-up end."))
                finalReplyTop = Math.min(finalReplyTop, clippedTop);
            }
            if (clippedBottom > clippedTop)
              spans.push({
                id,
                top: clippedTop,
                bottom: clippedBottom,
                left: rect.left,
                right: rect.right,
              });
          }
        }
      }
      const overlaps: string[] = [];
      for (let index = 0; index < spans.length; index++) {
        const a = spans[index]!;
        for (const b of spans.slice(index + 1)) {
          if (a.id === b.id) continue;
          const vertical = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
          const horizontal = Math.min(a.right, b.right) - Math.max(a.left, b.left);
          if (vertical > 1 && horizontal > 1) overlaps.push(`${a.id}/${b.id}: ${vertical.toFixed(2)}px`);
        }
      }
      return {
        problems: [...new Set(problems)],
        overlaps,
        previousEnd,
        finalEnd,
        visiblePreviousEnd,
        visibleFinalEnd,
        boundaryGap: finalReplyTop - previousEndBottom,
        visibleGhosts: [...document.querySelectorAll<HTMLElement>(".acpmux-row--fold-ghost")].filter((ghost) => {
          const rect = ghost.getBoundingClientRect();
          const style = getComputedStyle(ghost);
          return (
            Number(style.opacity) > 0 &&
            style.visibility === "visible" &&
            rect.bottom > view.top &&
            rect.top < view.bottom
          );
        }).length,
        proseLines,
        visibleRows: new Set(spans.map((span) => span.id)).size,
        scrollTop: scroller.scrollTop,
      };
    });
  }

  for (const [engine, browser] of browsers) {
    test(`${engine}: settled detector rejects overlapping rows and clipped final prose`, async () => {
      const page = await browser.newPage();
      try {
        await page.setContent(`<div class="acpmux-scroll" style="position:relative;height:300px;font:20px/24px Arial">
          <div class="acpmux-row" data-row-id="previous" style="position:absolute;top:0;height:48px">
            <div class="cv-reply">First line<br>Previous rich reply end.</div>
          </div>
          <div class="acpmux-row" data-row-id="final" style="position:absolute;top:72px;height:48px">
            <div class="cv-reply">Next line<br>Rich follow-up end.</div>
          </div>
        </div>`);
        const clean = await inspectSettled(page);
        expect(clean.problems).toEqual([]);
        expect(clean.overlaps).toEqual([]);
        await page.locator('[data-row-id="final"]').evaluate((node) => {
          (node as HTMLElement).style.top = "24px";
        });
        expect((await inspectSettled(page)).overlaps.length).toBeGreaterThan(0);
        await page.locator('[data-row-id="final"]').evaluate((node) => {
          (node as HTMLElement).style.top = "72px";
          (node as HTMLElement).style.clipPath = "inset(0 0 24px)";
        });
        expect((await inspectSettled(page)).problems).toContain("final: prose is clipped");
      } finally {
        await page.close();
      }
    });
    for (const narrow of [false, true]) {
      test(`${engine}: rich follow-up ${narrow ? "during width reflow" : "at stable width"} remains readable at rest`, async () => {
        events = [];
        status = "idle";
        socket = undefined;
        record("mux", "user_message", { text: "Start the session", promptId: "seed" });
        record("mux", "turn_started", {});
        record("in", "agent_message_chunk", chunk("Ready for the report-shaped reply."));
        record("mux", "turn_result", { status: "completed" });
        const page = await browser.newPage({ viewport: { width: 1000, height: 1000 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId}`,
          );
          await page.getByText("Ready for the report-shaped reply.").waitFor();
          begin("previous", "What happens when the push completes?");
          for (const text of richReply.slice(0, -1)) {
            emit("in", "agent_message_chunk", chunk(text));
            // fixed-wait: input streaming cadence, not a layout completion assumption.
            await Bun.sleep(25);
          }
          await page.locator(".cv-reply ol li").first().waitFor();
          const beforeWidth = await page.locator(".acpmux-scroll").evaluate((node) => node.clientWidth);
          // The previous reply's final chunk, completion, and next turn share a delivery burst.
          // Start resizing at that boundary; no settle wait between the two assistant replies.
          const reflow = narrow ? page.setViewportSize({ width: 620, height: 1000 }) : Promise.resolve();
          emit("in", "agent_message_chunk", chunk(richReply.at(-1)!));
          finish();
          begin("followup", "What is the MCP interception?");
          for (const text of followup) {
            emit("in", "agent_message_chunk", chunk(text));
            // fixed-wait: input streaming cadence.
            await Bun.sleep(25);
          }
          await reflow;
          finish();
          // The final footer must belong after this reply, not a still-mounted earlier turn.
          await page.waitForFunction(
            () => {
              const reply = [...document.querySelectorAll(".cv-reply")]
                .find((node) => node.textContent?.includes("Rich follow-up end."))
                ?.closest(".acpmux-row");
              const footer = document.querySelector(".acpmux-row--final-footer");
              return (
                !!reply &&
                !!footer &&
                !!(reply.compareDocumentPosition(footer) & Node.DOCUMENT_POSITION_FOLLOWING) &&
                !document.querySelector("[data-turn-end-folding]")
              );
            },
            undefined,
            { timeout: 15_000 },
          );
          const result = await inspectSettled(page);
          const afterWidth = await page.locator(".acpmux-scroll").evaluate((node) => node.clientWidth);
          console.log(`RICH_FOLLOWUP_REPORT ${JSON.stringify({ engine, narrow, beforeWidth, afterWidth, ...result })}`);
          expect(result.problems).toEqual([]);
          expect(result.overlaps).toEqual([]);
          expect(result.previousEnd).toBe(true);
          expect(result.finalEnd).toBe(true);
          expect(result.visiblePreviousEnd).toBe(true);
          expect(result.visibleFinalEnd).toBe(true);
          expect(result.boundaryGap).toBeGreaterThanOrEqual(0);
          expect(result.visibleGhosts).toBe(0);
          expect(result.proseLines).toBeGreaterThan(10);
          expect(result.visibleRows).toBeGreaterThan(1);
          if (narrow) expect(afterWidth).toBeLessThan(beforeWidth);
          else expect(afterWidth).toBe(beforeWidth);
        } finally {
          await page.close();
        }
      }, 120_000);
    }
  }
});
