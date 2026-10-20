// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// A subagent read "running" for good once nothing would end it: its turn was stopped and the
// harness never sent the subagent's end, or the agent restarted (a resume, a reopen, an exit)
// and the subagent it had was gone. Now such a subagent reads as stopped: cancelled when its
// turn was stopped, disconnected when the agent behind it went away. One that still reports
// (a background subagent's progress) reads running again.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d4";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>, acpmux?: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update, ...(acpmux ? { _meta: { acpmux } } : {}) },
});
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
const spawned = (id: string, name: string): Step => [
  "in",
  "subagent_spawned",
  update({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id, parent: null, name, state: "running" }] }),
];
const progress = (id: string, action: string): Step => [
  "in",
  "subagent_progress",
  update({ sessionUpdate: "subagent_progress" }, { subagents: [{ id, parent: null, state: "running", action }] }),
];
const turn = (text: string): Step[] => [
  ["mux", "user_message", { text }],
  ["mux", "turn_started", {}],
];

/// A daemon over a fake socket: attach answers with `history`; `push` sends live events.
function fakeDaemon(history: ReturnType<typeof record>) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history };
      case "_acpmux/events": {
        const before = params?.beforeSeq ?? Infinity;
        const after = params?.afterSeq ?? 0;
        const events = history.filter((event) => event.seq > after && event.seq < before);
        return { events, hasMore: false, more: false, lastSeq: history.at(-1)?.seq ?? 0 };
      }
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id !== undefined)
          queueMicrotask(() =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (events: ReturnType<typeof record>) => {
    for (const event of events) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return () => rows;
}

const states = (rows: AcpmuxRow[]) =>
  rows.filter((row) => row.kind === "subagents").flatMap((row) => row.subagents?.map((a) => [a.name, a.state]) ?? []);

test("a subagent whose turn was stopped reads cancelled, live and on a reload", async () => {
  const steps: Step[] = [...turn("Review with two agents"), spawned("a1", "Reviewer"), spawned("a2", "Tester")];
  const daemon = fakeDaemon(record(steps));
  const rows = await connect(daemon);
  expect(states(rows())).toEqual([
    ["Reviewer", "running"],
    ["Tester", "running"],
  ]);
  // The harness ended the turn without a word about its subagents.
  daemon.push(record([["mux", "turn_result", { status: "cancelled" }]], steps.length + 1));
  expect(states(rows())).toEqual([
    ["Reviewer", "cancelled"],
    ["Tester", "cancelled"],
  ]);
  // A reload replays the same log and reads the same.
  const reloaded = await connect(fakeDaemon(record([...steps, ["mux", "turn_result", { status: "cancelled" }]])));
  expect(states(reloaded())).toEqual([
    ["Reviewer", "cancelled"],
    ["Tester", "cancelled"],
  ]);
});

test("a subagent the restarted agent no longer reports reads disconnected", async () => {
  for (const restart of [
    ["mux", "resumed", { level: "exact" }],
    ["mux", "reopened", {}],
    ["mux", "exited", { code: 1 }],
    ["mux", "stopped", { code: 0 }],
    ["mux", "turn_result", { status: "failed", detail: "outcome_unknown" }],
  ] as Step[]) {
    const steps: Step[] = [
      ...turn("Run the audit in the background"),
      spawned("bg", "Audit"),
      ["mux", "turn_result", { status: "completed" }],
      restart,
    ];
    const rows = await connect(fakeDaemon(record(steps)));
    expect([restart[1], states(rows())]).toEqual([restart[1], [["Audit", "disconnected"]]]);
  }
});

test("a background subagent that still reports reads running", async () => {
  // Its turn ended normally: it runs on in the background.
  const quiet = await connect(
    fakeDaemon(
      record([
        ...turn("Audit in the background"),
        spawned("bg", "Audit"),
        ["mux", "turn_result", { status: "completed" }],
      ]),
    ),
  );
  expect(states(quiet())).toEqual([["Audit", "running"]]);

  // Its turn was stopped, but it went on reporting after: still running.
  const steps: Step[] = [
    ...turn("Audit in the background"),
    spawned("bg", "Audit"),
    spawned("fg", "Reviewer"),
    ["mux", "turn_result", { status: "cancelled" }],
    progress("bg", "Read src/net.ts"),
  ];
  const daemon = fakeDaemon(record(steps));
  const rows = await connect(daemon);
  expect(states(rows())).toEqual([
    ["Audit", "running"],
    ["Reviewer", "cancelled"],
  ]);
  // After a resume, a subagent that reports again is live again.
  daemon.push(record([["mux", "resumed", { level: "exact" }], progress("bg", "Read src/fetch.ts")], steps.length + 1));
  expect(states(rows())).toEqual([
    ["Audit", "running"],
    ["Reviewer", "cancelled"],
  ]);
});
