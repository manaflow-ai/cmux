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
async function cutAndWhole(
  special: (sessionId: string) => Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>,
  /// More rebuilds past a cut after the lag read's, before the cut rows are read.
  more?: (rebuild: (changedFrom: number) => void, pane: unknown) => void,
) {
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
    if (more) {
      more((changedFrom) => pane.rebuild(changedFrom), pane);
      pane.emit();
      flush();
    }
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

test("a subagent that starts above a cut and goes on past it is one group, its whole view kept", async () => {
  // Review of #40175 at 7bf242b0 (F1): a helper that started at record 10, went on at 8,005 and
  // ended at 8,007 drew a second group and lost its first reply past the cut at about 7,001.
  const { cut, whole } = await cutAndWhole((sessionId) => {
    const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
    const put = (record: EventRecord) => {
      const { sessionId: _s, seq: _q, at: _a, ...rest } = record;
      special.set(record.seq, rest);
    };
    const progress = (seq: number, state: string) =>
      put(
        update(
          sessionId,
          seq,
          { sessionUpdate: "subagent_progress" },
          { subagents: [{ id: "helper", parent: null, name: "Reviewer", state }] },
        ),
      );
    progress(10, "running");
    put(update(sessionId, 11, say("First helper reply", "helper-m1"), { subagent: "helper" }));
    progress(12, "completed");
    progress(8_005, "running");
    put(update(sessionId, 8_006, say("Second helper reply", "helper-m2"), { subagent: "helper" }));
    progress(8_007, "completed");
    return special;
  });
  const groups = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.kind === "subagents");
  expect(groups(cut)).toHaveLength(groups(whole).length);
  expect(cut.subagentViews?.helper?.length).toBe(whole.subagentViews?.helper?.length);
  expect(JSON.stringify(cut.subagentViews?.helper)).toContain("First helper reply");
  expect(shown(cut)).toEqual(shown(whole));
});

test("a compaction whose end comes past a cut is one note", async () => {
  // Review of #40175 at 7bf242b0 (F2): compacting at record 6,990, its turn's result at 7,000 notes
  // it failed, and its end at 7,050 takes it back; a cut at 7,001 drew a second note for that end.
  const { cut, whole } = await cutAndWhole((sessionId) => {
    const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
    for (const [seq, state] of [
      [6_990, "running"],
      [7_050, "completed"],
    ] as const) {
      const {
        sessionId: _s,
        seq: _q,
        at: _a,
        ...rest
      } = update(sessionId, seq, {
        sessionUpdate: "compaction",
        state,
      });
      special.set(seq, rest);
    }
    return special;
  });
  const notes = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.kind === "compaction");
  expect(notes(whole)).toHaveLength(1);
  expect(notes(cut)).toHaveLength(1);
  expect(shown(cut)).toEqual(shown(whole));
});

// The class F1 and F2 belong to: any row drawn above a cut that a record past it changes.
const spanning = (records: (sessionId: string) => EventRecord[]) => (sessionId: string) => {
  const special = new Map<number, Omit<EventRecord, "sessionId" | "seq" | "at">>();
  for (const record of records(sessionId)) {
    const { sessionId: _s, seq: _q, at: _a, ...rest } = record;
    special.set(record.seq, rest);
  }
  return special;
};

test("a tool call that starts above a cut and ends past it is one row, ended", async () => {
  const { cut, whole } = await cutAndWhole(
    spanning((sessionId) => [
      update(sessionId, 6_990, {
        sessionUpdate: "tool_call",
        toolCallId: "long-call",
        title: "Run the build",
        kind: "execute",
        status: "in_progress",
      }),
      update(sessionId, 7_050, {
        sessionUpdate: "tool_call_update",
        toolCallId: "long-call",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "built" } }],
      }),
    ]),
  );
  expect(shown(cut)).toEqual(shown(whole));
  expect(JSON.stringify(cut.rows)).toEqual(JSON.stringify(whole.rows));
});

test("a background task that starts above a cut and ends past it is one row, ended", async () => {
  const { cut, whole } = await cutAndWhole(
    spanning((sessionId) => [
      update(sessionId, 6_990, {
        sessionUpdate: "tool_call",
        toolCallId: "bg-call",
        title: "npm run dev",
        kind: "execute",
        status: "completed",
        rawOutput: { backgroundTaskId: "bg-1" },
      }),
      update(sessionId, 7_050, {
        sessionUpdate: "background_task_update",
        taskId: "bg-1",
        toolCallId: "bg-call",
        state: "completed",
        command: "npm run dev",
      }),
    ]),
  );
  expect(shown(cut)).toEqual(shown(whole));
  expect(JSON.stringify(cut.rows)).toEqual(JSON.stringify(whole.rows));
});

const helperProgress = (sessionId: string, seq: number, state: string) =>
  update(
    sessionId,
    seq,
    { sessionUpdate: "subagent_progress" },
    { subagents: [{ id: "helper", parent: null, name: "Reviewer", state }] },
  );

test("a subagent's record a repair brings past a cut joins its group above it", async () => {
  // The record the lag read brings back (the fold never read it) is a reply of a helper that started
  // and ended at records 10-12: the refold must not take it for a new subagent.
  const { cut, whole } = await cutAndWhole(
    spanning((sessionId) => [
      helperProgress(sessionId, 10, "running"),
      update(sessionId, 11, say("First helper reply", "helper-m1"), { subagent: "helper" }),
      helperProgress(sessionId, 12, "completed"),
      update(sessionId, HELD, say("Late helper reply", "helper-m2"), { subagent: "helper" }),
    ]),
  );
  const groups = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.kind === "subagents");
  expect(groups(cut)).toHaveLength(groups(whole).length);
  expect(JSON.stringify(cut.subagentViews?.helper)).toContain("First helper reply");
  expect(shown(cut)).toEqual(shown(whole));
});

test("a second cut, older than the first, still sees a subagent that started above both", async () => {
  // The first cut (about 7,001) starts the subagent fold over; a later repair from 6,950 cuts at
  // 6,801, between the helper's start at 6,610 and its records at 6,960-6,990.
  const { cut, whole } = await cutAndWhole(
    spanning((sessionId) => [
      helperProgress(sessionId, 6_610, "running"),
      update(sessionId, 6_611, say("First helper reply", "helper-m1"), { subagent: "helper" }),
      update(sessionId, 6_960, say("Second helper reply", "helper-m2"), { subagent: "helper" }),
      helperProgress(sessionId, 6_990, "completed"),
    ]),
    (rebuild) => rebuild(6_950),
  );
  const groups = (snapshot: Snapshot) => snapshot.rows.filter((row) => row.kind === "subagents");
  expect(groups(cut)).toHaveLength(groups(whole).length);
  expect(cut.subagentViews?.helper?.length).toBe(whole.subagentViews?.helper?.length);
  expect(shown(cut)).toEqual(shown(whole));
});

test("a row's write by an older record than the newest noted still spans a cut", async () => {
  // Second review of this fix: a repair's record refolded past a cut writes a row after newer
  // records' writes were noted; that write was dropped, so a later cut between it and the row's
  // start split the row (a compaction drew a second note).
  const { OrderedRows } = await import("./direct");
  const rows = new OrderedRows();
  const write = (seq: number, id: string, version: number) => {
    rows.current = seq;
    rows.set(id, { id, version, at: seq, seq, kind: "compaction" } as never);
    rows.current = undefined;
  };
  write(6_990, "compaction-6990", 1);
  write(11_990, "reply", 1);
  write(12_000, "reply", 2);
  write(7_050, "compaction-6990", 2);
  expect(rows.spanningFrom(7_001)).toBe(6_990);
  // A refold past a cut writes its changes again from the cut on, without growing the log.
  rows.forgetChangesFrom(7_001);
  write(7_050, "compaction-6990", 3);
  expect(rows.spanningFrom(7_001)).toBe(6_990);
  expect(rows.spanningFrom(7_051)).toBe(Infinity);
});

test("a sender claim a repair brings past a cut draws on its inbox notice above it", async () => {
  // Codex review of #41806 at 71c4d12: the cut cleared the map from a prompt id to its inbox notice,
  // so a claim the lag read brought could not find the notice; a full rebuild draws it there.
  const threads = [
    {
      threadId: "from:grid-lane",
      from: ["grid-lane"],
      promptIds: ["inbox-p1"],
      preview: "landing it now",
      messages: [{ promptId: "inbox-p1", from: "grid-lane", text: "landing it now" }],
    },
  ];
  const text = "[inbox] New messages from other agents in 1 thread.";
  const { cut, whole } = await cutAndWhole(
    spanning((sessionId) => [
      mux(sessionId, 101, "user_message", {
        text,
        promptId: "inbox-notice-1",
        _meta: { provenance: { kind: "inbox_notice", noticeId: "inbox-notice-1", threads } },
      }),
      mux(sessionId, HELD, "sender_claim", {
        promptId: "inbox-p1",
        claimed: { harness: "claude-code", entrypoint: "claude-desktop", sessionId: "cc-1", selfReported: true },
        checked: { harness: "claude-code", app: "Claude.app", peerPid: 50 },
      }),
    ]),
  );
  const notice = (snapshot: Snapshot) =>
    JSON.stringify((snapshot.rows as { incoming?: { kind?: string } }[]).find((row) => row.incoming?.kind === "inbox"));
  expect(notice(whole)).toContain("Claude.app");
  expect(notice(cut)).toEqual(notice(whole));
});

test("a sender unknown above a cut is still read again when the chat list names it", async () => {
  // Codex review of #41806 at 236a739: a cut cleared `unknownSenders`, so a listing that later named
  // a sender a row above the cut met no unknown sender and never read that row again.
  let unknown: number | undefined;
  await cutAndWhole(
    spanning((sessionId) => [
      mux(sessionId, 101, "user_message", {
        text: "peer-lane -> this-chat: status?",
        promptId: "from-peer-1",
        client: "acpmux-peer#01a161",
      }),
    ]),
    (_rebuild, pane) => {
      unknown = (pane as unknown as { unknownSenders: Set<string> }).unknownSenders.size;
    },
  );
  expect(unknown).toBeGreaterThan(0);
});
