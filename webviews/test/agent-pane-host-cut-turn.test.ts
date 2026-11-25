// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// https://github.com/manaflow-ai/cmux/issues/32727: the composer showed Stop (and the transcript its
// typing dots) while the chat ran no turn. The pane held a turn open from its records until an end
// record that never reached it. acpmux's summary says which turn it holds open (`turn`, null
// between turns), and each `session_changed` is built when sent, after its record: the pane's turn
// follows it, closed when acpmux runs none and open again when it runs one the pane saw no start of.
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
const running = { turnId: "t1", promptId: "p1", startedAt: START, client: "cmux", prompt: "merge main", turnSeq: 2 };

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
  const send = (method: string, params: unknown) =>
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method, params }) });
  const push = (...live: Step[]) => {
    for (const step of live) {
      const event = record(step, (history.at(-1)?.seq ?? 0) + 1);
      history.push(event);
      send("_acpmux/event", event);
    }
  };
  /// A `session_changed` with the summary as acpmux builds it when it sends it.
  const change = (fields: Record<string, unknown>) => {
    Object.assign(session, fields);
    send("_acpmux/session_changed", {
      sessionId: CHAT,
      session: { ...session },
      kind: "status",
      seq: history.at(-1)?.seq ?? 0,
    });
  };
  return { open, push, change };
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

test("a turn acpmux holds no longer ends Stop and the typing dots, with no end record", async () => {
  const daemon = fakeDaemon([status("running"), prompt, started, ["in", "tool_call", tool]], "running", {
    turn: running,
  });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  expect(typing(last())).toBe(true);

  // The turn's end never reaches the pane: only acpmux's summary says it holds none.
  daemon.push(status("idle"));
  daemon.change({ status: "idle", turn: null });
  await settle();
  expect(last().isWorking).toBe(false);
  expect(typing(last())).toBe(false);
  client.close();
});

test("a chat opened after its turn ended reads no turn, whatever its records opened", async () => {
  const daemon = fakeDaemon([prompt, started, ["in", "tool_call", tool]], "idle", { turn: null });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(false);
  expect(typing(last())).toBe(false);
  client.close();
});

test("a turn accepted while its agent starts stays open before its status reads running", async () => {
  // acpmux logs turn_started before the prompt goes out and the status turns running.
  const daemon = fakeDaemon([prompt, started], "ready", { turn: running });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  expect(typing(last())).toBe(true);
  daemon.change({ status: "running" });
  await settle();
  expect(last().isWorking).toBe(true);
  client.close();
});

test("a restart that adopts the running host opens the turn again, with no new start record", async () => {
  const daemon = fakeDaemon([status("running"), prompt, started], "running", { turn: running });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);

  // The old daemon hands the turn on (hub/shutdown.rs): idle, no turn.
  daemon.push(status("idle"));
  daemon.change({ status: "idle", turn: null });
  await settle();
  expect(last().isWorking).toBe(false);

  // The next daemon adopts the host and goes on with the same turn (hub/hosts.rs).
  daemon.push(status("running"), ["in", "tool_call", tool]);
  daemon.change({ status: "running", turn: running });
  await settle();
  expect(last().isWorking).toBe(true);
  expect(typing(last())).toBe(true);

  daemon.push(
    ["mux", "turn_end", { turnId: "t1", stopReason: "end_turn" }],
    ["mux", "turn_result", { turnId: "t1", promptId: "p1", status: "completed", stopReason: "end_turn" }],
  );
  daemon.change({ status: "ready", turn: null });
  await settle();
  expect(last().isWorking).toBe(false);
  expect(last().rows.some((row) => row.kind === "turnSummary")).toBe(true);

  // A summary that still names the ended turn never opens it again.
  daemon.change({ status: "ready", turn: running });
  await settle();
  expect(last().isWorking).toBe(false);
  client.close();
});

test("a watched chat's open turn stays open: acpmux holds none of the other app's turns", async () => {
  // hub/watch.rs logs the other app's turns as records; acpmux's summary names no turn.
  const daemon = fakeDaemon([prompt, started], "idle", { watching: "claude", turn: null });
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  daemon.change({ status: "idle" });
  await settle();
  expect(last().isWorking).toBe(true);
  client.close();
});

test("a summary that does not say which turn runs leaves the pane's fold as it was", async () => {
  // An older acpmux or peer: no `turn` key.
  const daemon = fakeDaemon([prompt, started], "idle");
  const { client, last } = await connect(daemon);
  expect(last().isWorking).toBe(true);
  client.close();
});
