// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// https://github.com/manaflow-ai/cmux/issues/32727: the composer showed Stop (and the transcript its
// typing dots) while the chat ran no turn. acpmux ends some turns with no end record: a daemon that
// hands its running turn to the next one on restart (hub/shutdown.rs), a wait the restart cut
// (hub/log_load.rs), a host it could not adopt (hub/hosts.rs). Each writes only its `status`
// record, so the pane must read the turn's end from acpmux's status, not wait for a `turn_end`.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000032a7";
const START = Date.UTC(2026, 10, 3, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const record = (step: Step, seq: number): Rec => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: step[0],
  kind: step[1],
  msg: step[2],
});
const tool = {
  method: "session/update",
  params: {
    update: {
      sessionUpdate: "tool_call",
      toolCallId: "c1",
      title: "Fetch base and test merge",
      kind: "execute",
      status: "in_progress",
    },
  },
};
const prompt: Step = ["mux", "user_message", { text: "merge main", promptId: "p1", turnId: "t1" }];
const started: Step = ["mux", "turn_started", { turnId: "t1", promptId: "p1" }];
const status = (value: string): Step => ["mux", "status", { status: value }];

/// A daemon whose chat has `steps` logged and lists the chat as `listed`; `push` sends live records.
function fakeDaemon(steps: Step[], listed: string, extra: Record<string, unknown> = {}) {
  let socket: any;
  const history = steps.map((step, index) => record(step, index + 1));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: listed,
    turnCount: 1,
    updatedAt: START,
    ...extra,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history, hasMore: false };
      case "_acpmux/events":
        return { events: params?.beforeSeq ? [] : history, hasMore: false, lastSeq: history.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  };
  const open = () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
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
  const push = (...live: Step[]) => {
    for (const step of live) {
      const event = record(step, (history.at(-1)?.seq ?? 0) + 1);
      history.push(event);
      if (step[1] === "status") session.status = String(step[2].status);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  const snapshots: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot) => {
      if (snapshot.type === "snapshot") snapshots.push(snapshot);
    },
    undefined,
    daemon.open,
  );
  await settle();
  const last = () => snapshots.at(-1)!;
  return { client, last };
}
const typing = (snapshot: AcpmuxSnapshot) => snapshot.rows.some((row) => row.kind === "typing");

test("a turn acpmux cut with only its status record ends Stop and the typing dots", async () => {
  const daemon = fakeDaemon([status("running"), prompt, started, ["in", "tool_call", tool]], "running");
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  expect(typing(last())).toBe(true);

  // A restart hands the turn on (hub/shutdown.rs): no turn_end, no turn_result, only `idle`.
  daemon.push(status("idle"));
  await settle();
  expect(last().isWorking).toBe(false);
  expect(typing(last())).toBe(false);
  client.close();
});

test("a chat opened after its turn was cut reads no turn, whatever its records opened", async () => {
  // The page holds the turn's opening records but not its status record: the summary says idle.
  const daemon = fakeDaemon([prompt, started, ["in", "tool_call", tool]], "idle");
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(false);
  expect(typing(last())).toBe(false);
  client.close();
});

test("a watched chat's open turn stays open: its turns never set acpmux's status", async () => {
  // hub/watch.rs logs the other app's turns as records and leaves the chat's status as it was.
  const daemon = fakeDaemon([prompt, started], "idle", { watching: "claude" });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  client.close();
});

test("an agent that starts for a waiting prompt does not end its turn", async () => {
  const daemon = fakeDaemon([status("idle")], "idle");
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(false);

  // The prompt opens the turn; the agent comes up (idle to ready), then the turn runs.
  daemon.push(prompt, started, status("ready"));
  await settle();
  expect(last().isWorking).toBe(true);
  daemon.push(status("running"), ["in", "tool_call", tool]);
  await settle();
  expect(last().isWorking).toBe(true);

  // A turn asking the person still runs; its answer goes back to running.
  daemon.push(status("waiting"), status("running"));
  await settle();
  expect(last().isWorking).toBe(true);

  // A normal end: its end records, then its status.
  daemon.push(
    ["mux", "turn_end", { turnId: "t1", stopReason: "end_turn" }],
    ["mux", "turn_result", { turnId: "t1", promptId: "p1", status: "completed", stopReason: "end_turn" }],
    status("ready"),
  );
  await settle();
  expect(last().isWorking).toBe(false);
  expect(last().rows.some((row) => row.kind === "turnSummary")).toBe(true);
  client.close();
});
