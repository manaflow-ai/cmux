// l10n-allow-file: benchmark output, not shipped UI.
// The floor under transcript_replay.long.*_ms: what one streamed record costs the renderer's main thread when no
// React, store or effect runs at all, measured the way transcript-replay.bench.ts measures the pane (CDP
// TaskDuration over a burst, per record; per record one `__replayAt` evaluate, one WebSocket message and one painted
// frame).
// Input: a static copy of the pane at a checkpoint, written by `SNAPSHOT=DIR bun bench/transcript-replay.bench.ts
// --only long` (the pane's real DOM and every CSS rule, scripts removed). Modes, each its own page:
//   harness  the message changes nothing: the cost of the measurement itself (evaluates, a message, a frame)
//   token    the message appends one word to the last row's text: a streamed token, by hand
//   row      the message clones the snapshot's newest row (a tool call's row after a tool_call burst) to the end of
//            its list and drops the list's first row (the virtual list's steady state): a new row, by hand
// So `pane - row` is what the pane's script (React, store, effects, its forced layouts) adds over the browser's own
// style, layout and paint of the same DOM change; `row - harness` is that browser floor.
//   bun bench/long-chat-floor.bench.ts SNAPSHOT.html [--records 200] [--rounds 5] [--modes harness,token,row]
/// <reference types="bun" />
import fs from "node:fs";
import type { CDPSession, Page } from "playwright";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { chromium } from "./browsers";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const file = argv.find((arg) => arg.endsWith(".html"));
if (!file) throw new Error("usage: bun bench/long-chat-floor.bench.ts SNAPSHOT.html [--records N] [--rounds N]");
const RECORDS = Number(flag("--records") ?? 200);
const ROUNDS = Number(flag("--rounds") ?? 5);
const MODES = (flag("--modes") ?? "harness,token,row").split(",");
const html = fs.readFileSync(file, "utf8");

const sockets = new Set<import("bun").ServerWebSocket<unknown>>();
const server = Bun.serve({
  port: 0,
  fetch(request, srv) {
    if (new URL(request.url).pathname === "/ws")
      return srv.upgrade(request) ? undefined : new Response("", { status: 400 });
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
  websocket: {
    open: (ws) => void sockets.add(ws),
    close: (ws) => void sockets.delete(ws),
    message() {},
  },
});

/// The page side: restore the scroll offset, open the socket, apply each message by `mode`.
function wire(mode: string) {
  const w = window as unknown as { __replayAt: (at: number) => void; __open: boolean; __applied: number };
  let now = 0;
  w.__replayAt = (at) => {
    if (at > now) now = at;
  };
  w.__applied = 0;
  const scroller = document.querySelector<HTMLElement>("[data-floor-scroll-top]");
  if (scroller) scroller.scrollTop = Number(scroller.dataset.floorScrollTop);
  const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")];
  const newest = rows.at(-1);
  const list = newest?.parentElement;
  let serial = 0;
  const socket = new WebSocket(`ws://${location.host}/ws`);
  socket.onopen = () => (w.__open = true);
  socket.onmessage = (event) => {
    const record = JSON.parse(event.data as string) as { seq: number; text: string };
    w.__applied++;
    if (mode === "token" && newest) {
      const leaf = [...newest.querySelectorAll("*")]
        .reverse()
        .find((node) => node.childNodes.length && node.textContent);
      (leaf ?? newest).append(` ${record.text}`);
    } else if (mode === "row" && newest && list) {
      const copy = newest.cloneNode(true) as HTMLElement;
      copy.dataset.rowId = `floor-${serial++}`;
      list.append(copy);
      list.querySelector("[data-row-id]")?.remove();
      if (scroller) scroller.scrollTop = scroller.scrollHeight;
    }
  };
}

async function metric(cdp: CDPSession, name: string) {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((each) => each.name === name)?.value ?? 0;
}
const paint = (page: Page, frames: number) =>
  page.evaluate(async (count) => {
    for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
  }, frames);

const browser = await chromium.launch();
const results = new Map<string, number[]>();
try {
  for (let round = 0; round < ROUNDS; round++)
    for (const mode of MODES) {
      const context = await browser.newContext({ viewport: { width: 900, height: 1100 } });
      const page = await context.newPage();
      await installPaintedFrames(page);
      const cdp = await context.newCDPSession(page);
      await cdp.send("Performance.enable");
      await page.goto(`http://127.0.0.1:${server.port}/`);
      await page.evaluate(wire, mode);
      await page.waitForFunction(() => (window as unknown as { __open?: boolean }).__open);
      await paint(page, 10);
      const before = await metric(cdp, "TaskDuration");
      for (let seq = 0; seq < RECORDS; seq++) {
        await page.evaluate((at) => (window as unknown as { __replayAt: (at: number) => void }).__replayAt(at), seq);
        for (const ws of sockets) ws.send(JSON.stringify({ seq, text: `word${seq}` }));
        await paint(page, 1);
      }
      await paint(page, 2);
      const ms = ((await metric(cdp, "TaskDuration")) - before) * 1000;
      const applied = await page.evaluate(() => (window as unknown as { __applied: number }).__applied);
      if (applied !== RECORDS) throw new Error(`${mode}: applied ${applied} of ${RECORDS} records`);
      results.set(mode, [...(results.get(mode) ?? []), ms / RECORDS]);
      await context.close();
    }
} finally {
  await browser.close();
  server.stop(true);
}
const quantile = (values: number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
};
console.log(`long-chat-floor: ${file}, ${RECORDS} records x ${ROUNDS} rounds, main-thread ms per record`);
for (const [mode, values] of results)
  console.log(
    `  ${mode.padEnd(8)} p50 ${quantile(values, 0.5).toFixed(3)}  max ${Math.max(...values).toFixed(3)}  ` +
      `(${values.map((value) => value.toFixed(3)).join(" ")})`,
  );
