// Manual hosted regression; intentionally outside the CI test registry.
// Run from webviews: CMUX_BROWSER_TESTS=1 bun scripts/agent-pane/backward-anchor.harness.ts
// l10n-allow-file: synthetic transcript and measurement diagnostics.
import assert from "node:assert/strict";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium } from "playwright";
import { createServer } from "vite";
import { installPaintedFrames } from "../../test/support/paintedFrames";
import { warmViteServer } from "../../test/support/warmDevServer";

assert.equal(process.env.CMUX_BROWSER_TESTS, "1", "Run on a hosted browser worker only");
const capture = process.env.CMUX_PAGING_CAPTURE_DIR;
if (capture) await mkdir(capture, { recursive: true });
const sessionId = "0190a000-0000-7000-8000-00000000bace";
const update = (text: string) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const events: { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown }[] = [];
const record = (dir: string, kind: string, msg: unknown) => {
  const event = { sessionId, seq: events.length + 1, at: 1790845200000 + events.length * 1000, dir, kind, msg };
  events.push(event);
  return event;
};
for (let turn = 0; turn < 900; turn++) {
  record("mux", "user_message", { text: `Synthetic question ${turn}` });
  record("mux", "turn_started", {});
  record(
    "in",
    "agent_message_chunk",
    update(`Synthetic answer ${turn}. ${"Measured history stays readable. ".repeat(12)}`),
  );
  record("mux", "turn_result", { status: "completed" });
}
const session = () => ({
  sessionId,
  cwd: "/synthetic/project",
  title: "Synthetic paged chat",
  harness: "claude",
  family: "claude",
  status: "ready",
  turnCount: 900,
  updatedAt: 1790845200000,
  lastSeq: events.length,
});
type Params = { beforeSeq?: number; afterSeq?: number; limit?: number; kinds?: string[] };
const cursors: number[] = [];
const held: (() => void)[] = [];
let heldReady: (() => void) | undefined;
const sockets = new Set<{ send(data: string): void }>();
let hold = true;
const pageOf = (params: Params) => {
  const before = params.beforeSeq ?? Infinity;
  const eligible = events.filter((event) => event.seq < before && event.seq > (params.afterSeq ?? 0));
  const limit = Math.min(params.limit ?? 80, 80);
  return { events: eligible.slice(-limit), hasMore: eligible.length > limit, lastSeq: events.length };
};
const daemon = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch(request, server) {
    return server.upgrade(request, { data: undefined }) ? undefined : new Response("synthetic", { status: 426 });
  },
  websocket: {
    open(ws) {
      sockets.add(ws);
    },
    close(ws) {
      sockets.delete(ws);
    },
    message(ws, raw) {
      const { id, method, params = {} } = JSON.parse(String(raw)) as { id?: number; method: string; params?: Params };
      if (id === undefined) return;
      const result =
        method === "initialize"
          ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } }
          : method === "_acpmux/watch"
            ? { sessions: [session()] }
            : method === "_acpmux/attach"
              ? { session: session(), ...pageOf(params) }
              : method === "_acpmux/events"
                ? pageOf(params)
                : null;
      const send = () => ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
      if (method === "_acpmux/events" && (params.limit ?? 0) > 16 && params.beforeSeq) {
        cursors.push(params.beforeSeq);
        if (hold) {
          held.push(send);
          heldReady?.();
          return;
        }
      }
      send();
    },
  },
});
const vite = await createServer({
  configFile: path.resolve(import.meta.dir, "../../vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 900, height: 760 },
  ...(capture ? { recordVideo: { dir: capture, size: { width: 900, height: 760 } } } : {}),
});
const page = await context.newPage();
const errors: string[] = [];
page.on("pageerror", (error) => errors.push(error.message));
// All waits are bounded, and all probes/observers stop explicitly before closing the page.
const waitForHeld = async () => {
  if (!held.length)
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        heldReady = undefined;
        reject(new Error("No beforeSeq request"));
      }, 10_000);
      heldReady = () => {
        clearTimeout(timer);
        heldReady = undefined;
        resolve();
      };
    });
  assert.ok(held.length, "the remote beforeSeq page was requested before reaching the hard edge");
};
try {
  await vite.listen();
  await warmViteServer(vite, "/");
  await installPaintedFrames(page);
  const { port } = vite.httpServer!.address() as { port: number };
  await page.goto(
    `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId}`,
  );
  await page.getByText("Synthetic question 899", { exact: true }).waitFor();
  const receipts: {
    frames: number;
    moved: number;
    missing: number;
    identityMissing: number;
    remounts: number;
    topReversals: number;
    thumbReversals: number;
  }[] = [];
  for (let batch = 0; batch < 4; batch++) {
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -1, bubbles: true }));
      node.scrollTop = node.clientHeight;
      node.dispatchEvent(new Event("scroll", { bubbles: true }));
    });
    await waitForHeld();
    await page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
    await page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const edge = scroller.getBoundingClientRect().top;
      const mounted = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      const existing = mounted.filter((row) => {
        const box = row.getBoundingClientRect();
        return box.bottom > edge && box.top < edge + scroller.clientHeight && row.clientHeight > 0;
      });
      const anchor = existing[0]!;
      if (!anchor) throw new Error("No stable visible anchor");
      const anchorId = anchor.dataset.rowId!;
      const top = anchor.getBoundingClientRect().top;
      const receipt = {
        id: anchorId,
        frames: 0,
        moved: 0,
        // Logical presence is measured by the current row with this id. A remount can leave
        // that row present while still losing the existing DOM node, which is tracked separately.
        missing: 0,
        identityMissing: 0,
        remounts: 0,
        maxDelta: 0,
        top: [] as number[],
        topReversals: 0,
        frameTimes: [] as number[],
        lastFrame: undefined as number | undefined,
        thumb: [] as { position: number; size: number }[],
        thumbReversals: 0,
      };
      const observer = new MutationObserver((records) => {
        for (const record of records)
          for (const removed of record.removedNodes)
            if (existing.some((row) => removed === row || removed.contains(row))) receipt.remounts++;
      });
      observer.observe(scroller, { childList: true, subtree: true });
      const stop = window.cmuxAfterPaint((frame) => {
        receipt.frames++;
        if (receipt.lastFrame !== undefined) receipt.frameTimes.push(frame - receipt.lastFrame);
        receipt.lastFrame = frame;
        const scrollTop = scroller.scrollTop;
        const previousTop = receipt.top.at(-1);
        receipt.top.push(scrollTop);
        if (previousTop !== undefined && scrollTop < previousTop - 1) receipt.topReversals++;
        const scrollRange = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
        const thumb = {
          position: scrollRange > 0 ? scrollTop / scrollRange : 0,
          size: scroller.scrollHeight > 0 ? scroller.clientHeight / scroller.scrollHeight : 1,
        };
        const previousThumb = receipt.thumb.at(-1);
        receipt.thumb.push(thumb);
        if (previousThumb && thumb.position < previousThumb.position - 0.001) receipt.thumbReversals++;
        if (existing.some((row) => !row.isConnected)) receipt.identityMissing++;
        const current = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find(
          (row) => row.dataset.rowId === anchorId,
        );
        if (!current) {
          receipt.missing++;
          return;
        }
        const delta = Math.abs(current.getBoundingClientRect().top - top);
        receipt.maxDelta = Math.max(receipt.maxDelta, delta);
        if (delta > 1) receipt.moved++;
      });
      (window as unknown as { pagingProbe: unknown }).pagingProbe = {
        receipt,
        stop: () => {
          stop();
          observer.disconnect();
        },
      };
    });
    held.shift()!();
    // Finite painted frames include React placement, ResizeObserver reports and deferred warm ranges.
    for (let frame = 0; frame < 24; frame++) {
      await page.evaluate(() => window.cmuxPaintFrame());
      if (capture && frame < 6) await page.screenshot({ path: path.join(capture, `page-${batch}-frame-${frame}.png`) });
    }
    const receipt = await page.evaluate(() => {
      const probe = (
        window as unknown as {
          pagingProbe: {
            receipt: {
              frames: number;
              moved: number;
              missing: number;
              identityMissing: number;
              remounts: number;
              top: number[];
              topReversals: number;
              frameTimes: number[];
              thumb: { position: number; size: number }[];
              thumbReversals: number;
            };
            stop(): void;
          };
        }
      ).pagingProbe;
      probe.stop();
      return probe.receipt;
    });
    receipts.push(receipt);
  }
  console.log(JSON.stringify({ cursors, receipts }, null, 2));
  // Finish a reply while scrolled up, then jump back. Late measurements at the end still land exactly.
  hold = false;
  for (const kind of ["user_message", "turn_started", "agent_message_chunk", "turn_result"]) {
    const msg =
      kind === "user_message"
        ? { text: "Synthetic final question" }
        : kind === "agent_message_chunk"
          ? update(`Synthetic final answer\n\n\`\`\`ts\n${"const synthetic = 1;\n".repeat(80)}\`\`\``)
          : kind === "turn_result"
            ? { status: "completed" }
            : {};
    const event = record(kind === "agent_message_chunk" ? "in" : "mux", kind, msg);
    for (const socket of sockets)
      socket.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  }
  await page.locator(".acpmux-jump-latest[data-shown]").click();
  await page.getByText("Synthetic final answer", { exact: true }).waitFor();
  await page.waitForFunction(() => {
    const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    return Math.abs(node.scrollHeight - node.clientHeight - node.scrollTop) <= 1;
  });
  const bottom = await page.evaluate(async () => {
    const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    // A late 3px ResizeObserver correction fits inside the old follow deadband.
    const row = [...node.querySelectorAll<HTMLElement>(".acpmux-row")].at(-1)!;
    row.style.paddingBottom = "3px";
    await window.cmuxPaintFrame();
    await window.cmuxPaintFrame();
    const gaps: number[] = [];
    await new Promise<void>((resolve) => {
      window.cmuxAfterPaint(() => {
        gaps.push(node.scrollHeight - node.clientHeight - node.scrollTop);
        if (gaps.length < 12) return;
        resolve();
        return false;
      });
    });
    row.style.paddingBottom = "8px";
    await window.cmuxPaintFrame();
    await window.cmuxPaintFrame();
    const largeGap = node.scrollHeight - node.clientHeight - node.scrollTop;
    return { gap: gaps.at(-1)!, largeGap, badFrames: gaps.filter((gap) => Math.abs(gap) > 4).length, gaps };
  });
  console.log(JSON.stringify({ bottom, errors }));
  const manualGap = await page.evaluate(async () => {
    const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    node.dispatchEvent(new WheelEvent("wheel", { deltaY: -40, bubbles: true }));
    node.scrollTop -= 40;
    node.dispatchEvent(new Event("scroll", { bubbles: true }));
    await window.cmuxPaintFrame();
    node.dispatchEvent(new WheelEvent("wheel", { deltaY: 40, bubbles: true }));
    node.scrollTop = node.scrollHeight - node.clientHeight - 3;
    node.dispatchEvent(new Event("scroll", { bubbles: true }));
    await window.cmuxPaintFrame();
    return node.scrollHeight - node.clientHeight - node.scrollTop;
  });
  for (const receipt of receipts) {
    assert.ok(receipt.frames > 0);
    assert.equal(receipt.moved, 0, "painted frames with anchor motion >1px");
    assert.equal(receipt.missing, 0, "painted frames missing the logical anchor row");
    assert.equal(receipt.identityMissing, 0, "painted frames missing the original anchor node");
    assert.equal(receipt.remounts, 0, "existing row mount identity changed during prepend");
    assert.equal(receipt.topReversals, 0, "scroll offset reversed while prepending history");
    assert.equal(receipt.thumbReversals, 0, "normalized scrollbar thumb reversed while prepending history");
  }
  assert.ok(Math.abs(bottom.gap) <= 4, `deadband bottom gap ${bottom.gap}`);
  assert.ok(Math.abs(bottom.largeGap) <= 1, `5-8px growth was not corrected (${bottom.largeGap}px)`);
  assert.equal(bottom.badFrames, 0, "a late measurement must not exceed the follow deadband or bounce");
  assert.ok(Math.abs(manualGap) <= 4, `scrolling into follow left a ${manualGap}px bottom gap`);
  assert.deepEqual(errors, []);
  assert.equal(new Set(cursors).size, cursors.length);
} finally {
  await page
    .evaluate(() => {
      (window as unknown as { pagingProbe?: { stop(): void } }).pagingProbe?.stop();
    })
    .catch(() => undefined);
  await context.close();
  await browser.close();
  await vite.close();
  await daemon.stop(true);
}
