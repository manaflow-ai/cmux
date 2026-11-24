// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// A local prompt's Return to the agent's first token on screen (goal startup-every-path; Leo 2026-11-24: "i hope
// we're still pursuing startup times for the app itself aka percieved time and percieved interactive time as well as
// general cloud startup time for any and every path we have"). The production pane (a vite build of the pane's dev
// entry) joins a stand-in acpmux holding four finished turns, idle. Each round is a cold page load (a fresh browser
// context, as chat-open.bench.ts loads one); once the chat has painted and rests, the reader types a prompt and
// presses Return. The stand-in plays a scripted agent with no model in it: on `session/prompt` it echoes the user
// message and starts the turn, then after THINK_MS (default 0: the model's time, kept out of the number) sends the
// first `agent_message_chunk`, the rest of the reply and the turn's end. So the number is the app's own cost: the
// pane's send path, the socket both ways and the transcript's render of the first chunk.
// Every painted frame from the Return, the page reads the transcript (test/support/paintedFrames.ts) and marks:
//   prompt_to_request_ms      Return (the keydown's timeStamp) to the stand-in reading `session/prompt`;
//   prompt_to_user_row_ms     Return to the first frame that paints the prompt in the transcript;
//   prompt_to_first_token_ms  Return to the first frame that paints the first token in the transcript's view;
//   token_to_paint_ms         the stand-in's send of the first chunk to that frame.
// Rows chat.first_token.<rail>.<stage> (rail: the thread rail's layout, cmux.experiments' thread-minimap-layout, as
// chat-open.bench.ts names its arms), p50 the median round and p95 the nearest-rank 95th percentile, with each round's
// value in `samples`. The page and the stand-in share the host's clock (performance.timeOrigin + now, Date.now()).
// PROFILE=1 builds the pane unminified (its rounds are then not the production build's) and prints, for the last
// round, the page functions with the most self time from the Return to the first token's frame.
//   [THINK_MS=0] [ARMS=compact,off] [PANE_OUT=dir] [PROFILE=1] bun bench/first-token.bench.ts [rounds=10]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, Page } from "playwright";
import { chromium } from "./browsers";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow, TARGET_MS } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 10);
const THINK_MS = Number(process.env.THINK_MS ?? 0);
const ARMS = (process.env.ARMS ?? "compact").split(",").filter(Boolean);
const PROFILE = process.env.PROFILE === "1";
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isFinite(THINK_MS) || THINK_MS < 0 || !ARMS.length) {
  console.error("usage: [THINK_MS=0] [ARMS=compact,off] bun bench/first-token.bench.ts [rounds=10]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");
const FIELD = ".acpmux-composer-prompt";
const SESSION = "0190a000-0000-7000-8000-0000000000f1";
const PROMPT = "Summarize the retry plan in one line";
/// The first chunk's text: a word no other row holds, so the first frame that shows it is the token's.
const FIRST_TOKEN = "Zephyrfirst";
const REPLY = [`${FIRST_TOKEN} `, "every retry loop ", "shares one capped backoff ", "of eight seconds."];

// ---------- the stand-in acpmux and its scripted agent ----------
let status = "idle";
const summary = () => ({
  sessionId: SESSION,
  cwd: "/home/dev/sun",
  title: "Retry policy",
  harness: "claude",
  family: "claude",
  status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: 4,
  updatedAt: Date.now(),
});
const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: body },
});
const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const events: Event[] = [];
const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
  const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
  events.push(event);
  return event;
};
for (let turn = 0; turn < 4; turn++) {
  record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
  record("mux", "turn_started", {});
  record(
    "in",
    "agent_message_chunk",
    chunk(`Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds.`),
  );
  record("mux", "turn_result", { status: "completed" });
}
const opened = events.length;

function answer(method: string): unknown {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary()] };
    case "_acpmux/attach":
      return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
}
type Socket = { send(data: string): void };
let socket: Socket | undefined;
const emit = (dir: string, kind: string, msg: Record<string, unknown>) =>
  socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
const changed = () =>
  socket?.send(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
    }),
  );
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
/// The round's stand-in marks (Date.now()): `session/prompt` read, the first chunk sent.
const marks = { requestAt: 0, tokenAt: 0 };
let turnDone: Promise<void> = Promise.resolve();

/// The scripted agent's turn, as acpmux runs one; answers the prompt request when it ends.
async function runTurn(ws: Socket, id: number, promptId: string | undefined) {
  status = "running";
  emit("mux", "user_message", { text: PROMPT, ...(promptId ? { promptId } : {}) });
  emit("mux", "turn_started", {});
  changed();
  if (THINK_MS > 0) await sleep(THINK_MS);
  for (const [index, part] of REPLY.entries()) {
    if (index === 0) marks.tokenAt = Date.now();
    emit("in", "agent_message_chunk", chunk(part));
    await sleep(20);
  }
  status = "idle";
  emit("mux", "turn_result", { status: "completed" });
  changed();
  ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
}

// ---------- the page side ----------
/// Resolves once the transcript's offset and height have held, with nothing in it animating, for 12 painted frames.
const rest = (page: Page) =>
  page.evaluate(async () => {
    const moving = () =>
      document
        .getAnimations()
        .some(
          (animation) =>
            animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
        );
    let last = "";
    for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
      await window.cmuxPaintFrame();
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const now = scroller ? `${scroller.scrollTop}:${scroller.scrollHeight}` : "none";
      held = now === last && !moving() ? held + 1 : 0;
      last = now;
    }
  });

/// The page's marks, wall ms (performance.timeOrigin + performance.now()): the Return's keydown, the first painted
/// frame with the prompt in the transcript and the first with the first token in the transcript's view.
type PageMarks = { enter: number; user: number; token: number };

/// Arms the page: the Return's keydown time, then a read after every painted frame until the token shows.
const arm = (page: Page) =>
  page.evaluate(
    ({ prompt, token }) => {
      const w = window as unknown as { __ft: PageMarks; __ftStop: () => void };
      const wall = (at: number) => performance.timeOrigin + at;
      w.__ft = { enter: 0, user: 0, token: 0 };
      addEventListener(
        "keydown",
        (event) => {
          if (event.key === "Enter" && !w.__ft.enter) w.__ft.enter = wall(event.timeStamp || performance.now());
        },
        { capture: true },
      );
      const visible = (scroller: HTMLElement, text: string) => {
        const walker = document.createTreeWalker(scroller, NodeFilter.SHOW_TEXT);
        const view = scroller.getBoundingClientRect();
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.includes(text)) continue;
          const box = node.parentElement?.getBoundingClientRect();
          if (box && box.height > 0 && box.bottom > view.top && box.top < view.bottom) return true;
        }
        return false;
      };
      w.__ftStop = window.cmuxAfterPaint(() => {
        if (!w.__ft.enter) return;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return;
        const now = wall(performance.now());
        if (!w.__ft.user && scroller.textContent?.includes(prompt)) w.__ft.user = now;
        if (!w.__ft.token && visible(scroller, token)) w.__ft.token = now;
        return !(w.__ft.user && w.__ft.token);
      });
    },
    { prompt: PROMPT, token: FIRST_TOKEN },
  );

export type Round = { requestMs: number; userMs: number; tokenMs: number; tokenToPaintMs: number };

/// A round's stages from its marks (pure); a stage whose mark never came is NaN.
export function stages(page: PageMarks, stand: { requestAt: number; tokenAt: number }): Round {
  const span = (from: number, to: number) => (from && to ? Math.round((to - from) * 10) / 10 : Number.NaN);
  return {
    requestMs: span(page.enter, stand.requestAt),
    userMs: span(page.enter, page.user),
    tokenMs: span(page.enter, page.token),
    tokenToPaintMs: span(stand.tokenAt, page.token),
  };
}

/// p50 the median, p95 the nearest-rank 95th percentile (pure).
export function percentiles(values: readonly number[]): { p50: number; p95: number } {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  const p50 = sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
  return { p50, p95: sorted[Math.max(0, Math.ceil(0.95 * sorted.length) - 1)]! };
}

type ProfileNode = { id: number; callFrame: { functionName: string; url: string; lineNumber: number } };
/// The functions with the most self time in a CPU profile (pure): `name file:line ms`, most first.
export function selfTimes(
  profile: { nodes: ProfileNode[]; samples: number[]; timeDeltas: number[] },
  top = 15,
): string[] {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const ms = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const frame = byId.get(id)?.callFrame;
    if (!frame) return;
    const key = `${frame.functionName || "(anonymous)"} ${frame.url.split("/").pop()}:${frame.lineNumber + 1}`;
    ms.set(key, (ms.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
  });
  return [...ms]
    .sort((a, b) => b[1] - a[1])
    .slice(0, top)
    .map(([key, value]) => `${value.toFixed(1).padStart(7)} ms  ${key}`);
}

async function round(browser: Browser, url: string, rail: string, profile = false): Promise<Round> {
  events.length = opened;
  status = "idle";
  marks.requestAt = 0;
  marks.tokenAt = 0;
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  try {
    await page.addInitScript((rail) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": rail }));
    }, rail);
    await installPaintedFrames(page);
    await page.goto(url);
    await page.locator(FIELD).waitFor({ timeout: 60_000 });
    await page.locator("[data-row-id]").first().waitFor({ timeout: 60_000 });
    await page.locator(FIELD).click();
    await page.keyboard.type(PROMPT);
    await page.mouse.move(0, 0);
    await rest(page);
    await arm(page);
    const cdp = profile ? await page.context().newCDPSession(page) : undefined;
    if (cdp) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    await page.keyboard.press("Enter");
    await page.waitForFunction(
      () => {
        const ft = (window as unknown as { __ft: PageMarks }).__ft;
        return ft.user > 0 && ft.token > 0;
      },
      undefined,
      { timeout: 30_000 + THINK_MS },
    );
    if (cdp) {
      const { profile } = await cdp.send("Profiler.stop");
      console.log(`first-token [rail ${rail}]: self time, Return to the first token's frame and a little after:`);
      for (const line of selfTimes(profile as never)) console.log(line);
    }
    await turnDone;
    const pageMarks = await page.evaluate(() => (window as unknown as { __ft: PageMarks }).__ft);
    return stages(pageMarks, marks);
  } finally {
    await page.close();
  }
}

async function paneBuild(): Promise<{ out: string; owned: boolean }> {
  const reuse = process.env.PANE_OUT;
  if (reuse && fs.existsSync(path.join(reuse, "index.html"))) return { out: reuse, owned: false };
  const out = reuse ?? fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "first-token-bench-"));
  const builtAt = performance.now();
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false, sourcemap: true } : {}) },
    logLevel: "error",
  });
  console.log(`first-token: pane built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
  return { out, owned: !reuse };
}

if (import.meta.main) {
  const releases: (() => unknown)[] = [];
  const release = async () => {
    for (const stop of [...releases].reverse()) {
      try {
        await stop();
      } catch {
        // Release the rest.
      }
    }
  };
  process.once("SIGINT", () => void release().then(() => process.exit(130)));
  try {
    const daemon = Bun.serve({
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
            params?: { _meta?: { acpmux?: { promptId?: string } } };
          };
          if (message.method === "_acpmux/attach" || message.method === "_acpmux/watch") socket = ws;
          if (message.method === "session/prompt" && message.id !== undefined) {
            marks.requestAt ||= Date.now();
            turnDone = runTurn(ws, message.id, message.params?._meta?.acpmux?.promptId);
            return;
          }
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const { out, owned } = await paneBuild();
    if (owned) releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    releases.push(() => statics.stop(true));
    const endpoint = `#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux`;
    const url = `http://127.0.0.1:${statics.port}/${endpoint}&session=${SESSION}`;
    const browser = await chromium.launch({ headless: true });
    releases.push(() => browser.close());

    for (const rail of ARMS) {
      const rounds: Round[] = [];
      for (let index = 0; index < ROUNDS; index++)
        rounds.push(await round(browser, url, rail, PROFILE && index === ROUNDS - 1));
      console.log(`first-token [rail ${rail}]: ${ROUNDS} cold loads, think ${THINK_MS} ms, chromium`);
      console.log("round | prompt->request ms | prompt->user row ms | prompt->first token ms | token->paint ms");
      for (const [index, r] of rounds.entries())
        console.log(`${index + 1} | ${r.requestMs} | ${r.userMs} | ${r.tokenMs} | ${r.tokenToPaintMs}`);
      const row = (stage: string, values: number[], target: number) => {
        if (values.some((value) => !Number.isFinite(value))) throw new Error(`first-token: ${stage} missed a round`);
        perfRow({
          name: `chat.first_token.${rail}.${stage}`,
          ...percentiles(values),
          unit: "ms",
          target,
          floor: 17,
          samples: values,
        });
      };
      // A send until its result paints is a response (TARGET_MS.response); the model's own wait adds THINK_MS.
      row(
        "prompt_to_first_token_ms",
        rounds.map((r) => r.tokenMs),
        TARGET_MS.response + THINK_MS,
      );
      row(
        "prompt_to_request_ms",
        rounds.map((r) => r.requestMs),
        TARGET_MS.response,
      );
      row(
        "prompt_to_user_row_ms",
        rounds.map((r) => r.userMs),
        TARGET_MS.response,
      );
      row(
        "token_to_paint_ms",
        rounds.map((r) => r.tokenToPaintMs),
        TARGET_MS.response,
      );
    }
  } finally {
    await release();
  }
}
