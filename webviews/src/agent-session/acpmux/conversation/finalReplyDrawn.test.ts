// l10n-allow-file: recorded chat fixtures, not shipped UI.
// A turn's final reply always draws as its own row after the turn's "Worked for", whatever follows
// it (Leo, 2026-11-12: "I can't see the GUI coordinator talking to me right now. Why is this
// happening? ... This has happened for the past couple bits"). The coordinator answered each time:
// its turn 2414207 streamed a 2,025-character reply (2414413..2414548) and ended at 2414555, and an
// inbox notice turn started 5 ms later; his NIGHTLY showed only the "Worked for" rows.
// These replay that stretch as the daemon pages it to the pane (`_acpmux/events`, kinds
// `transcript`, text masked), through the pane's own reducer (direct.ts) and fold (turns.ts), on
// reopen and live, under every fold arm, and check the class over random turn sequences.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";
import { settleReact } from "../../../../test/support/domTeardown";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";
import { turnReplies, undrawnReplies } from "./repliesDrawn";
import { turnView } from "./turns";

const SESSION = "01a18a35-b1e8-7951-ba2f-703bf916b9a6";
const logged: EventRecord[] = readFileSync(new URL("./fixtures/sr2-turn-2414207.ndjson", import.meta.url), "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = { window: scope.window, document: scope.document, had: "window" in scope };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(async () => {
  await settleReact();
  if (saved.had) Object.assign(scope, { window: saved.window, document: saved.document });
  else {
    delete scope.window;
    delete scope.document;
  }
});

/// The rows the pane's reducer folds `events` into, as a reopen reads them.
function replay(events: readonly EventRecord[]): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay(SESSION, [...events], (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return [...rows];
}

/// Every arm of the fold experiments a host can set (as replyAlwaysVisible.test.ts lists them).
const ARMS: Record<string, string>[] = [
  {},
  { "claude-turn-fold": "runs" },
  ...["nested-open", "nested", "header", "split"].map((arm) => ({ "turn-fold-steered": arm })),
  ...["groups", "runs", "replies"].map((arm) => ({ "turn-fold-replies": arm })),
];
function eachArm(check: (arm: string) => void) {
  try {
    for (const arms of ARMS) {
      globalThis.cmuxExperiments = arms;
      check(JSON.stringify(arms));
    }
  } finally {
    delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
  }
}
const named = (replies: readonly { startSeq: number; fromSeq: number; toSeq: number }[]) =>
  replies.map((reply) => `turn ${reply.startSeq} (reply ${reply.fromSeq}..${reply.toSeq})`).join(", ");

test("the coordinator's turn 2414207 draws its reply above the inbox turn that followed, on reopen", () => {
  const replies = turnReplies(logged);
  const leos = replies.find((reply) => reply.startSeq === 2414207);
  expect(leos?.text.length).toBe(2025);
  const rows = replay(logged);
  eachArm((arm) => {
    for (const family of ["claude", undefined]) {
      const drawn = turnView(rows, new Set(), { agentFamily: family });
      expect(named(undrawnReplies(replies, drawn)), `${arm} ${family}`).toBe("");
      // The reply sits after its own turn's fold and before the next turn's.
      const at = drawn.findIndex((row) => row.id === `assistant-${leos!.segment}`);
      const next = drawn.findIndex((row) => row.id === "worked-user-2414559");
      expect(at, arm).toBeGreaterThan(0);
      if (next >= 0) expect(at, arm).toBeLessThan(next);
    }
  });
});

test("every ended turn's reply draws at each record of the stretch, as the page grows", () => {
  const replies = turnReplies(logged);
  for (let end = 0; end < logged.length; end += 1) {
    const event = logged[end]!;
    if (event.kind !== "turn_result" && event.kind !== "turn_started" && event.kind !== "user_message") continue;
    const upTo = logged.slice(0, end + 1);
    const ended = replies.filter((reply) => reply.endSeq <= event.seq);
    const drawn = turnView(replay(upTo), new Set(), { agentFamily: "claude" });
    expect(named(undrawnReplies(ended, drawn)), `through ${event.seq}`).toBe("");
  }
});

const settle = async (done: () => boolean) => {
  for (let turns = 0; !done(); turns += 1) {
    if (turns > 20_000) throw new Error(`never settled: ${done.toString()}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
};

for (const batch of [1, 9]) {
  test(`live: the stretch streamed ${batch === 1 ? "one record" : `${batch} records`} at a time draws every reply`, async () => {
    const { MockAcpmuxSocket, mockHost } = await import("../mock");
    const { turnViewFrom } = await import("./turns");
    let live: ReturnType<typeof turnViewFrom> | undefined;
    let shown: any;
    let snapshots = 0;
    let socket!: any;
    const client = await AcpmuxDirectClient.connect(
      mockHost,
      (snapshot) => {
        shown = snapshot;
        snapshots += 1;
        // As App.tsx draws it: each snapshot's turns built on the last one's.
        live = turnViewFrom(
          snapshot.rows,
          new Set() as never,
          {
            working: snapshot.isWorking,
            clockOffset: snapshot.clockOffsetMs,
            turnStartedAtMs: snapshot.turnStartedAtMs,
            agentFamily: "claude",
            waitingSteers: snapshot.waitingSteers,
          } as never,
          live,
        );
      },
      undefined,
      () => (socket = new MockAcpmuxSocket(() => Promise.resolve())) as unknown as WebSocket,
    );
    const id = mockHost.sessionId!;
    await settle(() => shown?.summary !== undefined);
    const replies = turnReplies(logged);
    let sent = 0;
    for (const event of logged) {
      if (event.dir === "mux") {
        if (event.kind === "turn_started") socket.touch(id, { status: "running", turn: { turnId: event.msg?.turnId } });
        socket.emit(id, { mux: event.kind, msg: event.msg });
        if (event.kind === "turn_result") socket.touch(id, { status: "idle", turn: undefined });
      } else
        socket.emit(id, {
          update: event.msg.params.update,
          ...(event.msg.params._meta && { meta: event.msg.params._meta }),
        });
      sent += 1;
      if (sent % batch !== 0 && event.kind !== "turn_result") continue;
      const before = snapshots;
      await settle(() => snapshots > before);
      if (event.kind !== "turn_result") continue;
      const ended = replies.filter((reply) => reply.endSeq <= event.seq);
      expect(named(undrawnReplies(ended, live!.rows)), `live through ${event.seq}`).toBe("");
    }
    expect(named(undrawnReplies(replies, live!.rows))).toBe("");
    client.close?.();
  }, 60_000);
}

// The class: a turn the person, an inbox notice or a finished background command opened, its
// reply streamed between calls, thoughts and helpers' progress, then any of those opening the next
// turn at once. For every turn that ended with text after its last call, that text draws.
let seq = 0;
const at = () => 1794519714000 + seq * 40;
const record = (kind: string, dir: "mux" | "in", msg: EventRecord["msg"]): EventRecord => ({
  seq: (seq += 1),
  kind,
  dir,
  msg,
  sessionId: SESSION,
  at: at(),
});
const update = (kind: string, data: Record<string, unknown>, meta?: Record<string, unknown>) =>
  record(kind, "in", {
    method: "session/update",
    params: { ...(meta && { _meta: meta }), update: { sessionUpdate: kind, ...data } },
  });

function randomChat(random: () => number): EventRecord[] {
  seq = 0;
  const pick = <T>(list: readonly T[]) => list[Math.floor(random() * list.length)]!;
  const events: EventRecord[] = [];
  const turns = 2 + Math.floor(random() * 5);
  for (let turn = 0; turn < turns; turn += 1) {
    const turnId = `t${turn}`;
    const opener = pick(["person", "inbox", "background"] as const);
    const promptId = `${opener}-${turn}`;
    events.push(
      record("user_message", "mux", {
        text: opener === "person" ? `Question ${turn}` : `[${opener}] notice ${turn}`,
        promptId,
        turnId,
        ...(opener === "person"
          ? { client: "cmux-react-agent-pane#01a1d1" }
          : {
              client: "acpmux",
              ...(opener === "inbox" && {
                _meta: {
                  provenance: {
                    kind: "inbox_notice",
                    noticeId: promptId,
                    threads: [{ threadId: "from:lane", label: "lane", new: 1, from: ["lane"], promptIds: ["x"], blocker: false, preview: "Pushed." }],
                  },
                },
              }),
            }),
      }),
      record("turn_started", "mux", { promptId, turnId, client: opener === "person" ? "cmux-react-agent-pane#01a1d1" : "acpmux" }),
    );
    const steps = 1 + Math.floor(random() * 6);
    let segment = 0;
    for (let step = 0; step < steps; step += 1) {
      const kind = pick(["call", "thought", "note", "subagent", "task"] as const);
      if (kind === "call") {
        const id = `c${turn}.${step}`;
        events.push(
          update("tool_call", { toolCallId: id, title: `run ${id}`, kind: "execute", status: "in_progress", rawInput: { command: id } }),
          update("tool_call_update", { toolCallId: id, status: "completed" }),
        );
      } else if (kind === "thought") events.push(update("agent_thought_chunk", { content: { type: "text", text: "Thinking." } }));
      else if (kind === "note") {
        segment += 1;
        events.push(update("agent_message_chunk", { content: { type: "text", text: `Note ${turn}.${step}.` }, messageId: `m${turn}.${segment}` }, { acpmux: { segment: `${turnId}.${segment}` } }));
      } else if (kind === "subagent") events.push(update("subagent_progress", { subagentSessionId: "coord/helper", task: "Review" }));
      else events.push(update("task_progress", { taskId: "watch", description: "Watch CI", status: "running" }));
    }
    // The final reply, in chunks, sometimes split by a thought or a helper's progress.
    segment += 1;
    const messageId = `m${turn}.${segment}`;
    const pieces = 1 + Math.floor(random() * 5);
    for (let piece = 0; piece < pieces; piece += 1) {
      events.push(update("agent_message_chunk", { content: { type: "text", text: `Answer ${turn} part ${piece}. ` }, messageId }, { acpmux: { segment: `${turnId}.${segment}` } }));
      if (random() < 0.2) events.push(update("subagent_progress", { subagentSessionId: "coord/helper", task: "Review" }));
    }
    events.push(
      record("turn_end", "mux", { stopReason: "end_turn", turnId }),
      record("turn_result", "mux", { status: "completed", stopReason: "end_turn", promptId, turnId }),
    );
  }
  return events;
}

test("property: every ended turn's final reply draws, whatever opens the next turn", () => {
  let state = 0x2414207;
  const random = () => {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state / 0x80000000;
  };
  eachArm((arm) => {
    for (let run = 0; run < 60; run += 1) {
      const events = randomChat(random);
      const replies = turnReplies(events);
      expect(replies.length).toBeGreaterThan(0);
      const drawn = turnView(replay(events), new Set(), { agentFamily: "claude" });
      const missing = undrawnReplies(replies, drawn);
      // Every reply is found: a replay that drew nothing would pass the check below vacuously.
      expect(drawn.some((row) => row.kind === "assistant"), `${arm} run ${run}`).toBe(true);
      expect(named(missing), `${arm} run ${run}\n${drawn.map((row) => `${row.kind}:${row.id}`).join("\n")}`).toBe("");
    }
  });
});
