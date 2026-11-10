// A rebuild past a cut (direct.ts `rebuild`'s `changedFrom`, longChatCost.test.ts) folds again only
// the newest turns of a long chat and keeps the rows above as drawn. What it draws must be what a
// full rebuild draws: these open a 12,000-record chat, drop its last record live, let a lag read
// bring it back (a rebuild past a cut), and compare with the full rebuild of the same records.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";

setDefaultTimeout(120_000);
import { JSDOM } from "jsdom";
import type { EventRecord } from "./direct";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: "window" in scope, document: "document" in scope };
const before = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key]) scope[key] = before[key];
    else delete scope[key];
});

const HELD = 12_000;
const TURN = 200;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const settle = async (done: () => boolean, ms = 30_000) => {
  const deadline = performance.now() + ms;
  while (!done() && performance.now() < deadline) await tick();
  return done();
};

const update = (sessionId: string, seq: number, body: Record<string, unknown>, acpmux?: Record<string, unknown>) =>
  ({
    sessionId,
    seq,
    at: 1_700_000_000_000 + seq * 10,
    dir: "in",
    kind: String(body.sessionUpdate),
    msg: {
      method: "session/update",
      params: { sessionId, update: body, ...(acpmux ? { _meta: { acpmux } } : {}) },
    },
  }) as EventRecord;
const mux = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown> = {}) =>
  ({ sessionId, seq, at: 1_700_000_000_000 + seq * 10, dir: "mux", kind, msg }) as EventRecord;
const say = (text: string, messageId: string) => ({
  sessionUpdate: "agent_message_chunk",
  messageId,
  content: { type: "text", text },
});

/// Record `seq` of a chat of `TURN`-record turns, unless `special` names it.
function recordAt(sessionId: string, seq: number, special: Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>) {
  const own = special.get(seq);
  if (own) return { ...own, sessionId, seq, at: 1_700_000_000_000 + seq * 10 } as EventRecord;
  const phase = seq % TURN;
  if (phase === 1) return mux(sessionId, seq, "user_message", { text: `turn ${seq}` });
  if (phase === 2) return mux(sessionId, seq, "turn_started");
  if (phase === 0) return mux(sessionId, seq, "turn_result", { status: "completed" });
  return update(sessionId, seq, say(`w${seq} `, `m${Math.floor(seq / 20)}`));
}

type Snapshot = {
  rows: { id: string; kind: string; text?: string; presetApproval?: { outcome?: string } }[];
  subagentViews?: Record<string, unknown[]>;
};

/// The chat drawn after its last record, dropped live, came back through a lag read, and the same
/// chat drawn again whole (a full rebuild).
async function cutAndWhole(special: (sessionId: string) => Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>) {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  let target = "";
  let specials = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
  let socket: { deliver: (message: unknown) => void } | undefined;
  const at = (seq: number) => recordAt(target, seq, specials);
  class LongChat extends MockAcpmuxSocket {
    constructor() {
      super(() => Promise.resolve());
      socket = this as unknown as typeof socket;
      const self = this as unknown as { answer: (method: string, params: any) => Promise<unknown> };
      const answer = self.answer.bind(this);
      self.answer = async (method, params) => {
        if (method === "_acpmux/attach") {
          const result = (await answer(method, params)) as Record<string, unknown>;
          target = params.sessionId;
          specials = special(target);
          const events: EventRecord[] = [];
          for (let seq = HELD - 1 - 400 + 1; seq <= HELD - 1; seq += 1) events.push(at(seq));
          return { ...result, events, hasMore: true, lastSeq: HELD - 1, pageThrough: HELD - 1, turnOpener: null };
        }
        if (method === "_acpmux/events" && params.sessionId === target && params.beforeSeq === undefined) {
          const events: EventRecord[] = [];
          for (let seq = Number(params.afterSeq ?? 0) + 1; seq <= HELD; seq += 1) events.push(at(seq));
          return { events, hasMore: false };
        }
        return answer(method, params);
      };
    }
  }
  const frames: (() => void)[] = [];
  AcpmuxDirectClient.scheduleFrame = (run) => void frames.push(run);
  let snapshot: Snapshot = { rows: [] };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (next) => (snapshot = next as unknown as Snapshot),
    undefined,
    () => new LongChat() as unknown as WebSocket,
  );
  const pane = client as unknown as {
    events: EventRecord[];
    rebuild: (changedFrom?: number) => void;
    emit: () => void;
  };
  const flush = () => {
    for (const run of frames.splice(0)) run();
  };
  try {
    expect(await settle(() => target !== "" && pane.events.length >= 400)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    // The records that streamed in while the pane stayed open, drawn once.
    const streamed: EventRecord[] = [];
    for (let seq = 1; seq <= HELD - 1 - 400; seq += 1) streamed.push(at(seq));
    pane.events = streamed.concat(pane.events);
    pane.rebuild();
    pane.emit();
    flush();
    // The last record never reaches the pane; acpmux says it lagged, and the lag read brings it.
    socket!.deliver({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [target], dropped: 1 } });
    expect(await settle(() => pane.events.at(-1)?.seq === HELD)).toBe(true);
    for (let index = 0; index < 20; index += 1) await tick();
    flush();
    const cut = snapshot;
    pane.rebuild();
    pane.emit();
    flush();
    return { cut, whole: snapshot };
  } finally {
    client.close?.();
    AcpmuxDirectClient.scheduleFrame = undefined;
  }
}

const shown = (snapshot: Snapshot) =>
  snapshot.rows.map((row) => `${row.id} ${row.kind} ${row.text ?? ""} ${row.presetApproval?.outcome ?? ""}`);

test("a reply that goes on across a prompt into a running turn is drawn once past a cut", async () => {
  // A prompt sent while turn 6801's reply streams (no result between): the reply's message goes on
  // in its row after the prompt. The rebuild's window starts at about record 7,000.
  const { cut, whole } = await cutAndWhole((sessionId) => {
    const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
    for (let seq = 6_980; seq <= 7_020; seq += 1) {
      const { sessionId: _s, seq: _q, at: _a, ...rest } = update(sessionId, seq, say(`x${seq} `, "crossing"));
      special.set(seq, rest);
    }
    const {
      sessionId: _s,
      seq: _q,
      at: _a,
      ...prompt
    } = mux(sessionId, 7_000, "user_message", { text: "and also this" });
    special.set(7_000, prompt);
    return special;
  });
  const replies = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.text?.includes("x7001 "));
  expect(replies(whole)).toHaveLength(1);
  expect(replies(cut)).toHaveLength(1);
  expect(shown(cut)).toEqual(shown(whole));
});

test("a finished subagent's view above a cut stays after the rebuild", async () => {
  const { cut, whole } = await cutAndWhole((sessionId) => {
    const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
    const put = (record: EventRecord) => {
      const { sessionId: _s, seq: _q, at: _a, ...rest } = record;
      special.set(record.seq, rest);
    };
    put(
      update(
        sessionId,
        10,
        { sessionUpdate: "subagent_progress" },
        { subagents: [{ id: "helper", parent: null, name: "Reviewer", state: "running" }] },
      ),
    );
    put(update(sessionId, 11, say("Helper reply", "helper-m"), { subagent: "helper" }));
    put(
      update(
        sessionId,
        12,
        { sessionUpdate: "subagent_progress" },
        { subagents: [{ id: "helper", parent: null, name: "Reviewer", state: "completed" }] },
      ),
    );
    return special;
  });
  expect(Object.keys(whole.subagentViews ?? {})).toContain("helper");
  expect(Object.keys(cut.subagentViews ?? {})).toEqual(Object.keys(whole.subagentViews ?? {}));
  expect(cut.subagentViews?.helper?.length).toBe(whole.subagentViews?.helper?.length);
});

test("a preset approval asked above a cut is closed by its decision past it", async () => {
  const ask = {
    preset: "lane",
    digest: "d1",
    harness: "claude",
    model: "opus",
    policy: "approve-all",
    host: "linux-3",
  };
  const { cut, whole } = await cutAndWhole((sessionId) => {
    const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
    const { sessionId: _s, seq: _q, at: _a, ...request } = mux(sessionId, 6, "preset_approval_request", ask);
    special.set(6, request);
    // The decision is the record the lag read brings back, in the last turn.
    const {
      sessionId: _t,
      seq: _r,
      at: _b,
      ...decision
    } = mux(sessionId, HELD, "preset_approval_decision", {
      preset: "lane",
      digest: "d1",
      outcome: "approved",
    });
    special.set(HELD, decision);
    return special;
  });
  const card = (snapshot: Snapshot) => snapshot.rows.find((row) => row.id === "preset-approval-6");
  expect(card(whole)?.presetApproval?.outcome).toBe("approved");
  expect(card(cut)?.presetApproval?.outcome).toBe("approved");
  expect(shown(cut)).toEqual(shown(whole));
});
