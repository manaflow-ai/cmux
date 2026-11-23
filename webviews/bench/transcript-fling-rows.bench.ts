// l10n-allow-file: benchmark output, not shipped UI.
/// <reference types="bun" />
// The production pane, with the same flat conversation served as v1 records or v2 row changes.
// The stand-in has 100k visible messages and pages in 40 turns. Open and older start at the
// page's request. Token and prepend start at input/page delivery. Open, older and token stop
// when their row is visible; prepend stops when an older row is mounted in a painted frame,
// including overscan. Rects count Element and Range.getBoundingClientRect across the document.
// Run from webviews: bun bench/transcript-fling-rows.bench.ts
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { perfRow } from "./perfRow";
import { papercutPane, type PapercutStep } from "../test/support/papercutChat";
import type { ChatChange, ChatRow } from "../src/agent-session/acpmux/rows/wire";
import { installPaintedFrames } from "../test/support/paintedFrames";

type Arm = "v1" | "v2";
type Reading = { ms: number; rects: number; rowRects: number; turn?: number };
type Phase = "open" | "older" | "prepend" | "token";
type Results = Partial<Record<Phase, Reading>>;
const turns = Number(process.env.ROWS ?? 100_000) / 2;
const pageTurns = 40;
const traceRects = process.env.TRACE_RECTS === "1";
if (!Number.isSafeInteger(turns) || turns < pageTurns * 3) throw new Error("ROWS must be even and at least 240");
const viewport = { width: 1100, height: 800 };
const token = " bench-token-arrived";
const chunk = (text: string) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
const question = (turn: number) => `Question ${turn}`;
const answer = (turn: number) => `Answer ${turn}: the checks on the merged head are green.`;
const start = Date.UTC(2026, 9, 19, 9) / 1000;

function rows(first: number, last: number): ChatRow[] {
  const result: ChatRow[] = [];
  for (let n = first; n <= last; n++) {
    const turn = (n - 1) * 4 + 1;
    const at = start + (n - 1) * 3;
    const head = { turn, rev: 1, at, open: false, est: 1 };
    result.push(
      { ...head, id: turn, kind: "user", body: { content: question(n), state: "sent" } },
      { ...head, id: turn + 1, kind: "group", body: { prompt: turn, ms: 2000, calls: 0 } },
      {
        ...head,
        id: turn + 2,
        group: turn + 1,
        at: at + 2,
        kind: "text",
        body: { text: answer(n) },
        open: n === turns,
      },
    );
    if (n < turns)
      result.push({
        ...head,
        id: turn + 3,
        at: at + 2,
        group: turn + 1,
        kind: "notice",
        body: { notice: "turn_result", status: "completed", seq: turn + 3 },
      });
  }
  return result;
}

// Sends the changes on the same document entry point as the app's native host. The dev host
// installed by the fixture handles all other calls, including the v1 socket handshake.
async function instrument(page: Page, arm: Arm) {
  await installPaintedFrames(page);
  await page.addInitScript(
    ({ arm, turns, pageTurns, token, traceRects }) => {
      type Envelope = { op?: string; id?: number; params?: Record<string, unknown> };
      const scope = window as unknown as {
        __rowsResult: Results;
        __cmuxOlderTrace(phase: string): void;
        __rectStacks: Record<string, number>;
        __rowsHost(method: string, params: Record<string, unknown>): Promise<{ value?: unknown; change?: ChatChange }>;
        __rowsReceive(change: ChatChange): void;
        cmuxChatRows: { receive(batch: { batch: number; changes: string[] }): void };
      };
      let batch = 0;
      const result: Results = {};
      scope.__rectStacks = {};
      scope.__rowsResult = result;
      const pending = new Map<Phase, { began: number; rects: number; rowRects: number }>();
      const firstTailTurn = turns - pageTurns + 1;
      let olderBoundary = firstTailTurn;
      const begin = (phase: Phase, before?: number) => {
        if (pending.has(phase) || result[phase]) return;
        const active = { began: performance.now(), rects: 0, rowRects: 0 };
        pending.set(phase, active);
        window.cmuxAfterPaint(() => {
          if (phase === "prepend") {
            const mounted = Array.from(document.querySelectorAll(".acpmux-row[data-row-id]")).some((row) => {
              const turn = Number(/(?:Question |Answer )(\d+)/.exec(row.textContent ?? "")?.[1]);
              return turn > 0 && turn < olderBoundary;
            });
            if (!mounted) return true;
            result.prepend = {
              ms: performance.now() - active.began,
              rects: active.rects,
              rowRects: active.rowRects,
            };
            pending.delete(phase);
            return false;
          }
          // Hit test painted rows. A prefetched row sitting in the virtualizer's overscan
          // must not win the older-page measurement.
          for (let y = 25; y < innerHeight; y += 14) {
            const row = document.elementFromPoint(innerWidth / 2, y)?.closest("[data-row-id]");
            if (!row) continue;
            const text = row.textContent ?? "";
            const turn = Number(/(?:Question |Answer )(\d+)/.exec(text)?.[1]);
            if (!turn || (phase === "older" ? turn >= before! : turn !== turns)) continue;
            if (phase === "open" && !text.includes(`Answer ${turns}:`)) continue;
            if (phase === "token" && !text.includes(token)) continue;
            result[phase] = {
              ms: performance.now() - active.began,
              rects: active.rects,
              rowRects: active.rowRects,
              turn,
            };
            pending.delete(phase);
            return false;
          }
          return true;
        });
      };
      const countRect = (element: Element | null) => {
        for (const [phase, active] of pending) {
          active.rects++;
          if (traceRects && phase === "prepend") {
            const site = (new Error().stack ?? "")
              .split("\n")
              .slice(3, 7)
              .map((line) => line.trim())
              .join(" <- ");
            scope.__rectStacks[site] = (scope.__rectStacks[site] ?? 0) + 1;
          }
          if (element?.closest(".acpmux-row")) active.rowRects++;
        }
      };
      const rect = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = function () {
        countRect(this);
        return rect.call(this);
      };
      const rangeRect = Range.prototype.getBoundingClientRect;
      Range.prototype.getBoundingClientRect = function () {
        const node = this.commonAncestorContainer;
        countRect(node instanceof Element ? node : node.parentElement);
        return rangeRect.call(this);
      };
      scope.__rowsReceive = (change) => {
        if (change.kind === "chatOp") begin("token");
        if (change.kind === "chatPage") begin("prepend");
        scope.cmuxChatRows.receive({ batch: ++batch, changes: [JSON.stringify(change)] });
      };
      let olderAsked = false;
      scope.__cmuxOlderTrace = (phase) => {
        if (arm !== "v1") return;
        if (phase === "ask") olderAsked = true;
        if (phase === "reply" && pending.has("older")) begin("prepend");
      };
      const Socket = window.WebSocket;
      window.WebSocket = class extends Socket {
        constructor(...args: ConstructorParameters<typeof WebSocket>) {
          super(...args);
          this.addEventListener("message", (event) => {
            if (arm !== "v1" || typeof event.data !== "string") return;
            if (event.data.includes(token)) begin("token");
          });
        }
        override send(data: Parameters<WebSocket["send"]>[0]) {
          if (arm === "v1" && typeof data === "string") {
            const { method, params } = JSON.parse(data);
            if (method === "_acpmux/attach") begin("open");
            if (method === "_acpmux/events" && olderAsked && params.beforeSeq && !params.promptIndex) {
              if (!pending.has("older")) olderBoundary = Math.min(firstTailTurn, Math.ceil(params.beforeSeq / 4));
              begin("older", olderBoundary);
            }
          }
          super.send(data);
        }
      };
      {
        const handlers = new Proxy({} as Record<string, unknown>, {
          set(target, key: string, value: { postMessage(request: Envelope): Promise<unknown> }) {
            if (key !== "cmuxPage") target[key] = value;
            else
              target[key] = {
                async postMessage(request: Envelope) {
                  if (request.op === "cmux.agent.handshake") {
                    const reply = (await value.postMessage(request)) as { value: { linkScheme: string } };
                    // A NIGHTLY handshake. The dev host normally advertises cmux-dev, enabling
                    // its dev-only whole-document motion audit even in a production bundle.
                    reply.value.linkScheme = "cmux-nightly";
                    return reply;
                  }
                  if (arm !== "v2" || !request.op?.startsWith("cmux.agent.chat.rows."))
                    return value.postMessage(request);
                  const method = request.op.slice("cmux.agent.chat.rows.".length);
                  const params = request.params ?? {};
                  if (method === "open") begin("open");
                  if (method === "page") {
                    if (!pending.has("older"))
                      olderBoundary = Math.min(firstTailTurn, Math.ceil(Number(params.before) / 4));
                    begin("older", olderBoundary);
                  }
                  const reply = await scope.__rowsHost(method, params);
                  if (reply.change) scope.__rowsReceive(reply.change);
                  return { t: "ok", id: request.id, value: reply.value ?? {} };
                },
              };
            return true;
          },
        });
        Object.assign(window, { webkit: { messageHandlers: handlers } });
      }
    },
    { arm, turns, pageTurns, token, traceRects },
  );
}

async function readArm(arm: Arm) {
  const reply = answer(turns);
  const split = reply.lastIndexOf(" ");
  const extra: PapercutStep[] = [
    ["mux", "user_message", { text: question(turns) }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", chunk(reply.slice(0, split))],
    ["in", "agent_message_chunk", chunk(reply.slice(split))],
  ];
  const browser = await chromium.launch({ headless: true });
  try {
    const pane = await papercutPane(() => browser, {
      turns: turns - 1,
      running: false,
      extra,
      attachPage: pageTurns * 4,
      capabilities: arm === "v2" ? ["attach-hold-v1"] : [],
      session: { status: "running", turnCount: turns },
      production: { minify: !traceRects },
    });
    try {
      const page = await browser.newPage({ viewport });
      page.on("pageerror", (error) => console.error(arm, error.message));
      await instrument(page, arm);
      let sid = "";
      const asks: string[] = [];
      type HeightKey = { id: number; rev: number; width: number; signature: string };
      const heights = new Map<string, number>();
      const keyFor = ({ id, rev, width, signature }: HeightKey) => JSON.stringify([id, rev, width, signature]);
      await page.exposeFunction("__rowsHost", (method: string, params: Record<string, unknown>) => {
        asks.push(method);
        if (method === "open") {
          sid = String(params.sid);
          const tail = rows(turns - pageTurns + 1, turns);
          const open = tail.pop()!;
          return {
            value: { sid, heights: true },
            change: {
              kind: "chatWindow",
              replaces: true,
              window: {
                sid,
                cursor: 1,
                edition: 1,
                rows: tail,
                open: [{ row: open }],
                hasBefore: true,
                hasAfter: false,
              },
            } satisfies ChatChange,
          };
        }
        if (method === "heights.write") {
          const entries = params.entries as (HeightKey & { height: number })[];
          for (const entry of entries) heights.set(keyFor(entry), entry.height);
          return { value: { stored: entries.length } };
        }
        if (method === "heights.read") {
          return {
            value: {
              rows: (params.rows as HeightKey[]).map((row) => ({ ...row, height: heights.get(keyFor(row)) ?? null })),
            },
          };
        }
        if (method === "page") {
          const last = Math.floor((Number(params.before) - 1) / 4);
          const first = Math.max(1, last - pageTurns + 1);
          return {
            change: {
              kind: "chatPage",
              page: { sid, edition: 1, rows: rows(first, last), hasBefore: first > 1, hasAfter: true },
            } satisfies ChatChange,
          };
        }
        return {};
      });
      await page.goto(pane.address());
      const waitFor = async (phase: Phase) => {
        try {
          await page.waitForFunction(
            (phase) => !!(window as unknown as { __rowsResult: Results }).__rowsResult[phase],
            phase,
            { timeout: 15_000 },
          );
        } catch (cause) {
          const pageState = await page.evaluate(() => ({
            result: (window as unknown as { __rowsResult: Results }).__rowsResult,
            tail: [...document.querySelectorAll(".acpmux-row")]
              .slice(-4)
              .map((row) => [row.getAttribute("data-row-id"), row.textContent?.slice(0, 90)]),
          }));
          throw new Error(
            `${arm} never painted ${phase}: ${JSON.stringify({ asks, methods: pane.methods.slice(-8), ...pageState })}`,
            { cause },
          );
        }
      };
      await waitFor("open");
      if (arm === "v2") {
        if (!sid || !(await page.locator(`[data-row-id="row-${turns * 4 - 1}"]`).count()))
          throw new Error("v2 fell back before open painted");
        if (!traceRects)
          await page.evaluate(
            ({ sid, id, token }) =>
              (window as unknown as { __rowsReceive(change: ChatChange): void }).__rowsReceive({
                kind: "chatOp",
                sid,
                replay: false,
                op: { op: "text", seq: 2, rowId: id, text: token },
              }),
            { sid, id: turns * 4 - 1, token },
          );
      } else if (!traceRects) {
        pane.record("agent_message_chunk", chunk(token), "in");
      }
      if (!traceRects) await waitFor("token");
      // Drive the five fling steps used by transcript-fling.bench.ts until the older page is on screen.
      await page.evaluate(() => {
        const scroll = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const steps = [1500, 2400, 1900, 3000, 2100];
        let frame = 0;
        const up = () => {
          if ((window as unknown as { __rowsResult: Results }).__rowsResult.older || frame >= 240) return;
          const dy = -steps[frame++ % steps.length]!;
          const event = new WheelEvent("wheel", { deltaY: dy, bubbles: true, cancelable: true });
          if (scroll.dispatchEvent(event)) scroll.scrollTop += dy;
          requestAnimationFrame(up);
        };
        requestAnimationFrame(up);
      });
      await waitFor("older");
      await waitFor("prepend");
      if (arm === "v2" ? !asks.includes("page") : !pane.history.requests.some((before) => before !== undefined))
        throw new Error(`${arm} did not request an older page`);
      const measured = await page.evaluate(() => (window as unknown as { __rowsResult: Results }).__rowsResult);
      if (traceRects) {
        const stacks = await page.evaluate(() =>
          Object.entries((window as unknown as { __rectStacks: Record<string, number> }).__rectStacks)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 14),
        );
        console.log("TRANSCRIPT_FLING_ROWS_TRACE", JSON.stringify({ arm, stacks }));
      }
      if (!traceRects) {
        for (const [phase, reading] of Object.entries(measured)) {
          perfRow({ name: `transcript_fling.${arm}.${phase}_to_paint`, p95: reading.ms, samples: [reading.ms] });
          perfRow({ name: `transcript_fling.${arm}.${phase}_rects`, p95: reading.rects, unit: "calls" });
        }
      }
      console.log(
        "TRANSCRIPT_FLING_ROWS_JSON",
        JSON.stringify({ arm, rows: turns * 2, engine: "chromium", storedHeights: heights.size, ...measured }),
      );
    } finally {
      await pane.close();
    }
  } finally {
    await browser.close();
  }
}

const arm = process.env.ARM;
if (arm && arm !== "v1" && arm !== "v2") throw new Error("ARM must be v1 or v2");
if (arm !== "v2") await readArm("v1");
if (arm !== "v1") await readArm("v2");
