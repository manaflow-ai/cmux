// A coordinator's turn that never ends mounts as many elements at 20,000 records as at 10,000: the transcript draws the
// rows in its window and what it measures or estimates for the rest, whatever the turn holds (chat-100k-flat
// CASES=coordinator: page elements 1,835 at 2k records, 6,088 at 20k, the open turn's Agent cards all mounted).
// Leo, 2026-11-14: "the dream is infinite chats of infinite length with flat or no growth in cpu/memory/even disk".
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
// jsdom has no layout: a row draws 28px a line it holds (a card, a tool line, a paragraph), as the pane's rows do.
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const lines = this.dataset.rowId ? Math.max(1, this.querySelectorAll("p, li, .cv-agentcall, .cv-step").length) : 0;
  const height = lines * 28;
  return { x: 0, y: 0, top: 0, left: 0, right: 760, bottom: height, width: 760, height, toJSON() {} } as DOMRect;
};

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms: number) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

/// The records of a coordinator's open turn (bench/coordinatorTurn.ts, cut down): per step a short reply and a
/// shell call; every fifth step a long reply; every sixth an Agent call and its subagent, which ends fifteen steps
/// later. The records are made once, in order, so every read of a seq is the same record.
function coordinatorRecords(sessionId: string, count: number): EventRecord[] {
  const out: EventRecord[] = [];
  const push = (dir: string, kind: string, msg: Record<string, unknown>) => {
    const seq = out.length + 1;
    out.push({ sessionId, seq, at: 1_700_000_000_000 + seq * 10, dir, kind, msg } as EventRecord);
  };
  const said = (update: Record<string, unknown>, meta?: Record<string, unknown>) =>
    push("in", String(update.sessionUpdate), {
      method: "session/update",
      params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
    });
  const text = (value: string) => ({ type: "text", text: value });
  push("mux", "user_message", { text: "Coordinate the lanes until every ask is landed" });
  push("mux", "turn_started", {});
  const live: { id: string; call: string; ends: number }[] = [];
  for (let step = 1; out.length < count; step += 1) {
    // Another agent's message, steered into the running turn: what was still going then draws after it.
    if (step % 9 === 0)
      push("mux", "user_message", {
        text: `from lane-${step % 13}\nLanded the fix for step ${step}; CI is green.`,
        steer: true,
        fromAgent: `lane-${step % 13}`,
      });
    const reply =
      step % 5 === 0
        ? `## Status at step ${step}\n\nThe lanes are moving. Two need a review and one waits on CI.\n\n- one\n- two\n- three`
        : `Step ${step}: checked the lanes. `;
    said({ sessionUpdate: "agent_message_chunk", messageId: `m-${step}`, content: text(reply) });
    said({
      sessionUpdate: "tool_call",
      toolCallId: `c-${step}`,
      title: `glaeda-gh status pr ${step}`,
      kind: "execute",
      status: "in_progress",
      rawInput: { command: `glaeda-gh status pr ${step}` },
    });
    said({
      sessionUpdate: "tool_call_update",
      toolCallId: `c-${step}`,
      status: "completed",
      content: [{ type: "content", content: text(`checks SUCCESS: ${step} passed`) }],
    });
    if (step % 6 === 0) {
      const id = `sub-${step}`;
      const call = `agent-${step}`;
      said({
        sessionUpdate: "tool_call",
        toolCallId: call,
        title: "Agent",
        kind: "think",
        status: "in_progress",
        rawInput: {
          description: `Review step ${step}`,
          prompt: `Review the diff of step ${step}.`,
          subagent_type: "general-purpose",
        },
      });
      said(
        { sessionUpdate: "subagent_spawned", subagentSessionId: id },
        {
          subagents: [
            {
              id,
              parent: null,
              name: `reviewer-${step}`,
              task: `Review step ${step}`,
              state: "running",
              toolCallId: call,
            },
          ],
        },
      );
      // Every third runs in the background for the rest of the turn, as a coordinator's reviewers and
      // waits do: the turn's running Agent calls grow with it.
      live.push({ id, call, ends: step % 18 === 0 ? Infinity : step + 15 });
    }
    for (const agent of live.splice(0)) {
      if (step < agent.ends) {
        live.push(agent);
        continue;
      }
      said(
        { sessionUpdate: "subagent_state_update", subagentSessionId: agent.id, state: "completed" },
        { subagents: [{ id: agent.id, parent: null, state: "completed", lastMessage: "Reviewed: no findings." }] },
      );
      said({
        sessionUpdate: "tool_call_update",
        toolCallId: agent.call,
        status: "completed",
        content: [{ type: "content", content: text(`Reviewed: no findings.\nagentId: ${agent.id}`) }],
      });
    }
  }
  return out.slice(0, count);
}

/// A chat opened empty, then `count` records of the coordinator's open turn streamed into it live; its rows.
async function streamedRows(count: number): Promise<AcpmuxRow[]> {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const { MockAcpmuxSocket, mockHost } = await import("../src/agent-session/acpmux/mock");
  let target = "";
  let records: EventRecord[] = [];
  let total = 0;
  let socket: { deliver: (message: unknown) => void } | undefined;
  class Chat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          return { ...result, events: [], hasMore: false, lastSeq: 0, pageThrough: 0, turnOpener: null };
        }
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq !== undefined) {
          const limit = Number(params.limit ?? 400);
          const kinds: string[] | undefined = params.kinds?.includes("transcript") ? undefined : params.kinds;
          const events: EventRecord[] = [];
          for (let seq = params.beforeSeq - 1; seq >= 1 && events.length < limit; seq -= 1) {
            const event = records[seq - 1]!;
            if (!kinds || kinds.includes(event.kind)) events.unshift(event);
          }
          return { events, hasMore: (events[0]?.seq ?? 1) > 1, lastSeq: total };
        }
        if (method === "_acpmux/events" && params.sessionId === target)
          return { events: records.slice(Number(params.afterSeq ?? 0), total), hasMore: false, lastSeq: total };
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (rows = (next as { rows: AcpmuxRow[] }).rows),
    undefined,
    () => new Chat() as unknown as WebSocket,
  );
  try {
    client.setFollowing(true);
    expect(await settle(() => target !== "", 10_000)).toBe(true);
    records = coordinatorRecords(target, count);
    for (let index = 0; index < 20; index += 1) await tick();
    for (let index = 0; index < count; index += 1) {
      total += 1;
      socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/event", params: records[index] });
      if (index % 50 === 49) {
        await tick();
        flush();
      }
    }
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    return rows;
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}

/// What the transcript mounts for the turn's rows, followed at its end as the open chat is.
async function mounted(rows: AcpmuxRow[]) {
  const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const shown = turnView(rows, new Set(), { working: true, now: 1_700_000_000_000 + rows.length * 10 });
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={shown} working onToggleActivity={() => {}} expanded={new Set()} />),
    );
    // The follow pass and the deferred warm rows settle over a few frames.
    for (let frame = 0; frame < 6; frame += 1) await act(async () => void (await tick()));
    const doc = dom.window.document;
    const cards = (row: AcpmuxRow) =>
      (row.items ?? []).filter((item) => item.tool?.kind === "think" && item.tool.title === "Agent").length;
    return {
      rows: shown.length,
      mountedRows: doc.querySelectorAll(".acpmux-row").length,
      agentCards: doc.querySelectorAll(".cv-agentcall").length,
      elements: host.getElementsByTagName("*").length,
      biggestRow: Math.max(0, ...shown.map(cards)),
      // The mounted rows that hold the most, to read what grew.
      heavy: [...doc.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((node) => ({
          id: node.dataset.rowId,
          elements: node.getElementsByTagName("*").length,
          cards: node.querySelectorAll(".cv-agentcall").length,
        }))
        .sort((a, b) => b.elements - a.elements)
        .slice(0, 4),
    };
  } finally {
    await act(async () => root.unmount());
  }
}

// From 10k records on, the turn's running Agent cards take more room than the window and the history it mounts
// above it (VirtualTranscript HISTORY_VIEWPORTS), so twice the records must mount no more.
test("a coordinator's open turn mounts as many elements at 20k records as at 10k", async () => {
  const at10k = await mounted(await streamedRows(10_000));
  const at20k = await mounted(await streamedRows(20_000));
  console.log(`open-turn-cards 10k=${JSON.stringify(at10k)} 20k=${JSON.stringify(at20k)}`);
  expect(at10k.agentCards).toBeGreaterThan(0);
  expect(at20k.agentCards).toBeLessThanOrEqual(at10k.agentCards * 1.1 + 8);
  expect(at20k.mountedRows).toBeLessThanOrEqual(at10k.mountedRows * 1.1 + 4);
  expect(at20k.elements).toBeLessThanOrEqual(at10k.elements * 1.1 + 40);
}, 600_000);

// The running turn's run that keeps many Agent cards in sight draws as rows of a few cards each, which the
// transcript windows; the rows draw exactly what the one row drew, in the same order, and Find still finds a call
// in a later one.
test("a long run cut into parts draws as the one row did", async () => {
  const { runParts, RUN_PART_STRETCHES } = await import("../src/agent-session/acpmux/conversation/runParts");
  const { ToolRows } = await import("../src/agent-session/acpmux/conversation/TurnRows");
  const { findRowIndex, rowHolds } = await import("../src/agent-session/acpmux/conversation/chatFind");
  type Item = NonNullable<AcpmuxRow["items"]>[number];
  const at = 1_700_000_000_000;
  const items: Item[] = [];
  for (let n = 0; n < 40; n += 1) {
    items.push({
      kind: "tool",
      text: "",
      tool: {
        id: `agent-${n}`,
        title: "Agent",
        kind: "think",
        status: n % 3 ? "in_progress" : "completed",
        inputSummary: JSON.stringify({
          description: `Review step ${n}`,
          prompt: `Review the diff of step ${n}.`,
          subagent_type: "general-purpose",
        }),
        ...(n % 3 ? {} : { output: `Reviewed: no findings.\nagentId: sub-${n}` }),
      },
    } as Item);
    for (const k of [0, 1])
      items.push({
        kind: "tool",
        text: "",
        tool: {
          id: `c-${n}-${k}`,
          title: `glaeda-gh status pr ${n}`,
          kind: "execute",
          status: "completed",
          command: `glaeda-gh status pr ${n}`,
          output: "checks SUCCESS",
        },
      } as Item);
  }
  const row: AcpmuxRow = { id: "run-1", version: 7, at, kind: "activity", items, foldRun: true, settled: true };
  const parts = runParts(row);
  expect(parts.length).toBeGreaterThan(2);
  expect(parts[0]!.id).toBe(row.id);
  expect(new Set(parts.map((part) => part.id)).size).toBe(parts.length);
  expect(parts.flatMap((part) => part.items!)).toEqual(items);
  for (const part of parts) expect(part.items!.length).toBeLessThanOrEqual(RUN_PART_STRETCHES * 3);
  // The same row cut again is the same parts (no new objects to lay out and draw again).
  expect(runParts(row)).toBe(parts);
  const host = dom.window.document.getElementById("root")!;
  const drawn = async (rows: AcpmuxRow[]) => {
    const root = createRoot(host);
    try {
      await act(async () =>
        root.render(
          <div>
            {rows.map((one) => (
              <div key={one.id} className="part">
                <ToolRows row={one} />
              </div>
            ))}
          </div>,
        ),
      );
      // Each row draws its entries in a `.cv-tools` box of its own (KeepOpenedLine.tsx); what is in them is the same.
      const tags = [...host.querySelectorAll(".part *")]
        .filter((node) => !(node.classList.contains("cv-tools") && !node.parentElement?.closest(".cv-tools")))
        .map((node) => `${node.tagName}.${node.className}`);
      return { tags, text: host.textContent, cards: host.querySelectorAll(".cv-agentcall").length };
    } finally {
      await act(async () => root.unmount());
    }
  };
  const whole = await drawn([row]);
  const cut = await drawn(parts);
  expect(whole.cards).toBe(40);
  expect(cut.cards).toBe(whole.cards);
  expect(cut.text).toBe(whole.text);
  expect(cut.tags).toEqual(whole.tags);
  // Find goes to the part that holds the call.
  const shown = [{ id: "u", version: 1, at, kind: "user", text: "go" } as AcpmuxRow, ...parts];
  expect(findRowIndex(shown, row.id, rowHolds({ toolId: "agent-37" }))).toBe(
    shown.findIndex((one) => one.items?.some((item) => item.tool?.id === "agent-37")),
  );
});

// The summary card's Subagents section drew every subagent the chat ever ran (chat-100k-flat CASES=coordinator: 2,386
// card body elements at 20k records, 11,772 at 100k). Its body is a scroller: it mounts only the rows that body shows
// and a few past it, over a box as tall as the rest, and draws the rest as it scrolls to them; nothing is lost.
test("the summary card mounts only the subagents its body shows, and scrolls to the last", async () => {
  const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
  const { firstRowCount } = await import("../src/agent-session/acpmux/session-info/WindowedRows");
  type Agents = Parameters<typeof SubagentStatusList>[0]["agents"];
  const agents = (n: number): Agents =>
    Array.from({ length: n }, (_, index) => ({
      id: `sub-${index}`,
      parent: null,
      name: `reviewer-${index}`,
      state: index % 4 === 0 ? "running" : "completed",
      startedAt: 1_700_000_000_000 + index * 1_000,
      ...(index % 4 === 0 ? {} : { endedAt: 1_700_000_000_000 + index * 1_000 + 500 }),
    }));
  // The card's body, 400px tall, scrolls; a list row is 28px (summary.css .acpmux-summary-row), laid out from the
  // body's scroll. jsdom has no layout, so this test lays out the body and its list's rows itself.
  const BODY = 400;
  const ROW = 28;
  const proto = dom.window.HTMLElement.prototype;
  const laidOut = proto.getBoundingClientRect;
  let body: HTMLElement | null = null;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    const rect = (top: number, height: number) =>
      ({ x: 0, y: top, top, left: 0, right: 288, bottom: top + height, width: 288, height, toJSON() {} }) as DOMRect;
    if (this === body) return rect(0, BODY);
    const list = this.parentElement;
    if (body && this.tagName === "LI" && list?.classList.contains("acpmux-summary-list") && body.contains(list))
      return rect(Array.prototype.indexOf.call(list.children, this) * ROW - body.scrollTop, ROW);
    return laidOut.call(this);
  };
  const host = dom.window.document.getElementById("root")!;
  const lines = () => host.querySelectorAll(".acpmux-summary-agents .acpmux-agent-line").length;
  const drawn: Record<number, { lines: number; elements: number }> = {};
  try {
    for (const n of [40, 400, 4_000]) {
      const root = createRoot(host);
      try {
        await act(async () =>
          root.render(
            <div className="acpmux-summary-card__body" style={{ overflowY: "auto" }} ref={(node) => void (body = node)}>
              <SubagentStatusList agents={agents(n)} waiting={new Set()} onOpen={() => {}} />
            </div>,
          ),
        );
        drawn[n] = { lines: lines(), elements: host.getElementsByTagName("*").length };
        expect(host.querySelector(".acpmux-summary-more")).toBeNull();
        const spacer = host.querySelector<HTMLElement>("[data-rows-rest]");
        if (lines() < n) {
          // The rest's box is as tall as their rows, so the body's scroll takes its whole height at once.
          expect(spacer?.style.height).toBe(`${(n - lines()) * ROW}px`);
          // Scrolled to the end, the body draws its last subagent.
          body!.scrollTop = n * ROW - BODY;
          await act(async () => void body!.dispatchEvent(new dom.window.Event("scroll")));
          expect(await settle(() => lines() === n, 5_000)).toBe(true);
          expect(host.querySelector("[data-rows-rest]")).toBeNull();
        }
        expect(host.textContent).toContain(`reviewer-${n - 1}`);
      } finally {
        await act(async () => root.unmount());
        body = null;
      }
    }
  } finally {
    proto.getBoundingClientRect = laidOut;
  }
  console.log(`summary-subagents ${[40, 400, 4_000].map((n) => `${n}=${JSON.stringify(drawn[n])}`).join(" ")}`);
  // 40 fit, all drawn; past that, a window's rows and the overscan (WindowedRows, 48 here), whatever the chat ran.
  expect(drawn[40]!.lines).toBe(40);
  expect(drawn[400]!.lines).toBeLessThanOrEqual(firstRowCount(1_024));
  expect(drawn[4_000]).toEqual(drawn[400]!);
});
