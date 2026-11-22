// Scratch repro (not committed): a real long chat in the real pane, a turn streaming, the draft growing 1 to 5 lines.
// bun test/anchor-repro.scratch.ts FIXTURE TAIL WIDTH HEIGHT OUTDIR
import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";

const [fixture, tailArg, widthArg, heightArg, out] = process.argv.slice(2);
const TAIL = Number(tailArg ?? 20000);
const WIDTH = Number(widthArg ?? 900);
const HEIGHT = Number(heightArg ?? 800);
const outDir = out ?? "/tmp/anchor-repro";
mkdirSync(outDir, { recursive: true });
const ENGINE = process.env.ANCHOR_ENGINE === "chromium" ? chromium : webkit;
const SESSION = "0190a000-0000-7000-8000-0000000000c1";
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: any };
const all: Event[] = readFileSync(fixture!, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line))
  // drop the last open turn so the history ends idle
  .map((event: Event) => ({ ...event, sessionId: SESSION }));
let lastEnd = all.length - 1;
while (lastEnd > 0 && all[lastEnd]!.kind !== "turn_result") lastEnd--;
const events = all.slice(0, lastEnd + 1);
const opened = events.length;
const summary = {
  sessionId: SESSION,
  cwd: "/home/dev/sun",
  title: "Coordinator",
  harness: "claude",
  family: "claude",
  status: "idle",
  turnCount: 400,
  updatedAt: Date.now(),
};
let seq = events.at(-1)!.seq;
const record = (dir: string, kind: string, msg: any): Event => {
  const event = { sessionId: SESSION, seq: ++seq, at: Date.now(), dir, kind, msg };
  events.push(event);
  return event;
};
const update = (text: string) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
function answer(method: string, params: any): unknown {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary] };
    case "_acpmux/attach": {
      const tail = events.slice(Math.max(0, opened - TAIL), opened);
      return { session: summary, lastSeq: tail.at(-1)!.seq, events: tail };
    }
    case "_acpmux/events": {
      const before = params?.beforeSeq ?? Infinity;
      const after = params?.afterSeq ?? -1;
      const limit = params?.limit ?? 500;
      let list = events.filter((e) => e.seq < before && e.seq > after);
      const hasMore = list.length > limit;
      list = params?.beforeSeq != null ? list.slice(-limit) : list.slice(0, limit);
      return { events: list, hasMore, lastSeq: seq };
    }
    default:
      return null;
  }
}
let socket: any;
const daemon = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  fetch(request, server) {
    return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
  },
  websocket: {
    open(ws) {
      socket = ws;
    },
    message(ws, raw) {
      const message = JSON.parse(String(raw));
      if (message.id !== undefined)
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
    },
  },
});
const send = (event: Event) =>
  socket.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));

const { createServer } = await import("vite");
const webviews = path.resolve(import.meta.dir, "..");
const vite = await createServer({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const browser = await ENGINE.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: WIDTH, height: HEIGHT }, deviceScaleFactor: Number(process.env.DPR ?? 1), ...(process.env.VIDEO ? { recordVideo: { dir: outDir, size: { width: WIDTH, height: HEIGHT } } } : {}) });
await installPaintedFrames(page);
page.on("pageerror", (e) => console.log("PAGEERROR", String(e).slice(0, 400), e.stack?.slice(0, 1200)));
page.on("console", async (m) => { if (m.type() === "error") console.log("CONSOLE", (await Promise.all(m.args().map((a) => a.evaluate((x: any) => String(x) + " @@ " + String(x?.stack ?? "")).catch(() => "?")))).join(" | ").slice(0, 2500)); });
const { port } = vite.httpServer!.address() as { port: number };
const endpoint = `ws://127.0.0.1:${daemon.port}/`;
const t0 = Date.now();
await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
await page.waitForSelector(".acpmux-scroll .acpmux-row", { timeout: 120_000 });
await page.waitForTimeout(3000);
console.log("opened in", Date.now() - t0, "ms");
const state = () =>
  page.evaluate(() => {
    const s = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    return {
      rows: s.querySelectorAll(".acpmux-row").length,
      scrollTop: s.scrollTop,
      scrollHeight: s.scrollHeight,
      clientHeight: s.clientHeight,
    };
  });
console.log("state", JSON.stringify(await state()));
await page.locator(".acpmux-composer-prompt .ProseMirror, .acpmux-composer-prompt").first().click();
await page.keyboard.type("Also cover the 503 path");
await page.waitForTimeout(1000);
if (process.env.PRE === "wheel") {
  await page.mouse.move(WIDTH / 2, 200);
  for (const dy of [-800, -1200, -600, 400, 900, 1500, 3000, 3000]) {
    await page.mouse.wheel(0, dy);
    await page.waitForTimeout(250);
  }
  await page.waitForTimeout(800);
  console.log("after wheel", JSON.stringify(await state()));
}
await page.screenshot({ path: path.join(outDir, "00-start.png") });
console.log("state", JSON.stringify(await state()));

// A turn starts and streams while the draft grows.
const STREAM = process.env.ANCHOR_STREAM !== "0";
let streaming = true;
if (STREAM) {
  send(record("mux", "user_message", { text: "Next step?", promptId: "p-x" }));
  send(record("mux", "turn_started", {}));
  (async () => {
    let i = 0;
    while (streaming) {
      i++;
      send(
        record(
          "in",
          "agent_message_chunk",
          update(i % 6 === 0 ? `\n\nParagraph ${i}. ` : `word${i} and some more streamed text for the reply `),
        ),
      );
      await Bun.sleep(40);
    }
  })();
  await page.waitForTimeout(600);
}
await page.evaluate(() => {
  const own = window as any;
  own.__frames = [];
  own.__stop = window.cmuxAfterPaint(() => {
    const s = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!s) return false;
    const rows = s.querySelectorAll<HTMLElement>(".acpmux-row");
    const last = rows[rows.length - 1]!;
    const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
    const field = document.querySelector<HTMLElement>(".acpmux-composer-prompt .ProseMirror");
    const pm = field ? (field.closest(".acpmux-composer-md-scroll, [data-composer-scroll]") as HTMLElement) ?? field.parentElement! : null;
    own.__frames.push({
      t: Math.round(performance.now()),
      box: Math.round(box.getBoundingClientRect().height),
      scrollTop: Math.round(s.scrollTop),
      fromEnd: Math.round(s.scrollHeight - s.clientHeight - s.scrollTop),
      gap: Math.round(box.getBoundingClientRect().top - last.getBoundingClientRect().bottom),
      rows: rows.length,
      sh: s.scrollHeight,
      fieldTop: field ? Math.round(field.scrollTop) : -1,
      pmTop: pm ? Math.round(pm.scrollTop) : -1,
    });
  });
});
let shotN = 1;
for (let cycle = 0; cycle < Number(process.env.CYCLES ?? 1); cycle++) {
  if (cycle > 0) {
    await page.keyboard.press("Control+a");
    await page.keyboard.press("Backspace");
    await page.keyboard.type("Also cover the 503 path");
    await page.waitForTimeout(400);
  }
  for (let line = 2; line <= 5; line++) {
    await page.keyboard.press("Shift+Enter");
    await page.keyboard.type(`line ${line} of the draft`, { delay: Number(process.env.DELAY ?? 20) });
    if (cycle === 0) await page.screenshot({ path: path.join(outDir, `${String(shotN++).padStart(2, "0")}-line${line}.png`) });
  }
}
await page.waitForTimeout(800);
streaming = false;
if (STREAM) send(record("mux", "turn_result", { status: "completed" }));
await page.waitForTimeout(800);
await page.screenshot({ path: path.join(outDir, `${String(shotN++).padStart(2, "0")}-end.png`) });
const frames = await page.evaluate(() => {
  (window as any).__stop();
  return (window as any).__frames;
});
writeFileSync(path.join(outDir, "frames.json"), JSON.stringify(frames));
const minTop = Math.min(...frames.map((f: any) => f.scrollTop));
const maxEnd = Math.max(...frames.map((f: any) => f.fromEnd));
const gaps = frames.map((f: any) => f.gap);
console.log(
  `frames=${frames.length} scrollTop first=${frames[0].scrollTop} min=${minTop} maxFromEnd=${maxEnd} gap min=${Math.min(...gaps)} max=${Math.max(...gaps)}`,
);
console.log("state", JSON.stringify(await state()));
await page.close();
await browser.close();
await vite.close();
daemon.stop(true);
process.exit(0);
