// l10n-allow-file: test fixtures, not shipped UI.
// A lost connection hands the chat to the client the page connects next (direct.ts `CarriedChat`):
// its records, row ids and rows on screen, so a reconnect redraws nothing (agent-pane-settled-load).
// Review of cmux#41540: that hand-over must carry where the records run and which session they are
// of, so the reconnect resumes after them and a session acpmux recreated under the same id while
// the page was away drops them instead of merging them into the new session's transcript. And a
// reply acpmux split in two segments (a cut between them) keeps two rows under one messageId.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type CarriedChat } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000d7";
const START = Date.UTC(2026, 10, 11, 23, 0, 0);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

const user = (seq: number, text: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});
const chunk = (seq: number, text: string, messageId: string, segment?: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: "agent_message_chunk",
  msg: {
    method: "session/update",
    params: {
      sessionId: CHAT,
      update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
      ...(segment ? { _meta: { acpmux: { segment } } } : {}),
    },
  },
});

/// A daemon holding one session (`createdAt` names which), whose log is `history`. Records what
/// each attach asked and how each socket can be dropped.
function fakeDaemon(history: Record<string, any>[], createdAt: number) {
  // `attachFrom`: the first seq an attach with no cursor answers (a page that starts mid-chat); the
  // records before it come with an older page (`_acpmux/events` `beforeSeq`).
  const state = {
    history,
    createdAt,
    attachFrom: 0,
    attaches: [] as Record<string, unknown>[],
    sockets: [] as any[],
  };
  const session = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
    createdAt: state.createdAt,
  });
  const lastSeq = () => Number(state.history.at(-1)?.seq ?? 0);
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session()] };
      case "_acpmux/attach": {
        state.attaches.push(params ?? {});
        const after = Math.max(Number(params?.afterSeq ?? 0), state.attachFrom - 1);
        return {
          session: session(),
          lastSeq: lastSeq(),
          events: state.history.filter((event) => event.seq > after),
          // Older records left than the page holds.
          hasMore: state.history.some((event) => event.seq <= after && event.seq < state.attachFrom),
        };
      }
      case "_acpmux/events": {
        if (typeof params?.beforeSeq === "number") {
          if (params.promptIndex) return { events: [], hasMore: false, lastSeq: lastSeq() };
          return { events: state.history.filter((event) => event.seq < params.beforeSeq), hasMore: false };
        }
        const after = Number(params?.afterSeq ?? 0);
        return { events: state.history.filter((event) => event.seq > after), hasMore: false, lastSeq: lastSeq() };
      }
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
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
    state.sockets.push(socket);
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const drop = () => {
    const socket = state.sockets.at(-1);
    socket.readyState = 3;
    socket.onclose?.({ code: 4000, reason: "", wasClean: false });
  };
  /// A record streamed live to the connected page.
  const push = (event: Record<string, any>) => {
    state.history.push(event);
    state.sockets
      .at(-1)
      ?.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { state, open, drop, push };
}

/// Connects as App.tsx does: a lost client's chat goes to the client connected next.
async function page(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: any[] = [];
  let carried: CarriedChat | undefined;
  let client: AcpmuxDirectClient | undefined;
  let lost: Promise<void> = Promise.resolve();
  const host = {
    protocolVersion: 1,
    transport: "acpmux-websocket",
    endpoint: "ws://127.0.0.1:1/",
    token: "t",
    sessionId: CHAT,
  } as const;
  const connect = async () => {
    client = await AcpmuxDirectClient.connect(
      host,
      (snapshot: any) => (rows = snapshot.rows ?? rows),
      () => {
        carried = client?.takeCarried() ?? carried;
        lost = connect();
      },
      daemon.open,
      undefined,
      undefined,
      carried,
    );
    carried = undefined;
    await tick();
  };
  await connect();
  return {
    rows: () => rows,
    older: async () => {
      await client!.loadOlder();
      await tick();
    },
    text: () => rows.filter((row) => row.kind === "user" || row.kind === "assistant").map((row) => row.text),
    reconnected: async () => {
      await lost;
      await tick();
    },
  };
}

test("a reconnect keeps the carried rows and adds what came while it was away", async () => {
  const daemon = fakeDaemon([user(1, "first prompt"), chunk(2, "first reply", "m1", "t1.1")], 1000);
  const pane = await page(daemon);
  expect(pane.text()).toEqual(["first prompt", "first reply"]);
  daemon.state.history.push(user(3, "second prompt"));
  daemon.drop();
  await pane.reconnected();
  expect(daemon.state.attaches.length).toBe(2);
  expect(pane.text()).toEqual(["first prompt", "first reply", "second prompt"]);
});

test("a session recreated under the same id while the page was away drops the carried rows", async () => {
  const daemon = fakeDaemon([user(1, "old session prompt"), chunk(2, "old session reply", "m1", "t1.1")], 1000);
  const pane = await page(daemon);
  expect(pane.text()).toEqual(["old session prompt", "old session reply"]);
  // The daemon recreated the session: same id, a new `createdAt`, its own log from seq 1.
  daemon.state.createdAt = 2000;
  daemon.state.history = [user(1, "new session prompt")];
  daemon.drop();
  await pane.reconnected();
  expect(pane.text()).toEqual(["new session prompt"]);
});

test("a reply acpmux split into two segments under one messageId draws two rows", async () => {
  const daemon = fakeDaemon(
    [
      user(1, "go"),
      chunk(2, "before the cut", "m1", "t1.1"),
      // The record the cut was at is not on this page: only the segment says the run of text ended.
      chunk(4, "after the cut", "m1", "t1.2"),
    ],
    1000,
  );
  const pane = await page(daemon);
  const replies = pane.rows().filter((row) => row.kind === "assistant");
  expect(replies.map((row) => row.id)).toEqual(["assistant-t1.1", "assistant-t1.2"]);
});

// Review of cmux#41540 at 360e73b7: the pane keeps one message in one row across a background
// task's note, a subagent's update, a plumbing call and a plan call (Leo, 2026-11-03: "this chat's
// text stream got cut in the middle by a tool call which is weird"), and acpmux stamps one segment
// across them (hub/stream.rs): the message stays one row under its segment's id.
const update = (seq: number, body: Record<string, unknown>) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: String(body.sessionUpdate),
  msg: { method: "session/update", params: { sessionId: CHAT, update: body } },
});
test.each([
  [
    "a background task's note",
    [update(3, { sessionUpdate: "background_task_update", toolCallId: "bg-1", state: "completed" })],
  ],
  [
    "a subagent's update",
    [
      update(3, { sessionUpdate: "subagent_spawned", subagentSessionId: "child-1", name: "Look", task: "Look" }),
      update(4, { sessionUpdate: "subagent_state_update", subagentSessionId: "child-1", state: "completed" }),
    ],
  ],
  [
    "a plumbing call",
    [
      update(3, {
        sessionUpdate: "tool_call",
        toolCallId: "ts-1",
        title: "ToolSearch",
        kind: "other",
        status: "completed",
        _meta: { claudeCode: { toolName: "ToolSearch" } },
      }),
    ],
  ],
  [
    "a plan call",
    [
      update(3, {
        sessionUpdate: "tool_call",
        toolCallId: "plan-1",
        title: "todo_write",
        kind: "other",
        status: "completed",
        _meta: { acpmux: { planTool: true } },
      }),
    ],
  ],
] as const)("one message streamed across %s stays one row", async (_name, between) => {
  const daemon = fakeDaemon(
    [user(1, "go"), chunk(2, "first half, ", "m1", "t1.x.1"), ...between, chunk(9, "second half", "m1", "t1.x.1")],
    1000,
  );
  const pane = await page(daemon);
  const replies = pane.rows().filter((row) => row.kind === "assistant");
  expect(replies.map((row) => [row.id, row.text])).toEqual([["assistant-t1.x.1", "first half, second half"]]);
});

// Review of cmux#41540 at 360e73b7 (Codex F1, F2): paging into the middle of a reply. The attach's
// page starts inside a reply named by its segment; the older page brings its first chunks. The reply
// stays one row under the id it was drawn with, its text in order, never twice.
test("an older page that brings the start of a reply the page cut keeps one row, its text in order", async () => {
  const daemon = fakeDaemon(
    [
      user(1, "go"),
      chunk(2, "one ", "m1", "t1.x.1"),
      chunk(3, "two ", "m1", "t1.x.1"),
      chunk(4, "three", "m1", "t1.x.1"),
    ],
    1000,
  );
  daemon.state.attachFrom = 3;
  const pane = await page(daemon);
  expect(
    pane
      .rows()
      .filter((row) => row.kind === "assistant")
      .map((row) => [row.id, row.text]),
  ).toEqual([["assistant-t1.x.1", "two three"]]);
  await pane.older();
  expect(pane.text()).toEqual(["go", "one two three"]);
  expect(
    pane
      .rows()
      .filter((row) => row.kind === "assistant")
      .map((row) => [row.id, row.text]),
  ).toEqual([["assistant-t1.x.1", "one two three"]]);
});

// An older page folded above the held turn (`foldOlder`) leaves the live reply's segment as it was:
// a chunk of the reply's next segment (a cut between, under the same messageId) still starts its
// own row, not the text of the older page's last reply.
test("a folded older page keeps the live reply's segment", async () => {
  const daemon = fakeDaemon(
    [user(1, "old prompt"), chunk(2, "old reply", "m0", "t0.x.1"), user(3, "go"), chunk(4, "before", "m1", "t1.x.1")],
    1000,
  );
  daemon.state.attachFrom = 3;
  const pane = await page(daemon);
  await pane.older();
  expect(pane.text()).toEqual(["old prompt", "old reply", "go", "before"]);
  daemon.push(chunk(5, " the cut", "m1", "t1.x.1"));
  daemon.push(chunk(6, "after", "m1", "t1.x.2"));
  await tick();
  expect(
    pane
      .rows()
      .filter((row) => row.kind === "assistant")
      .map((row) => [row.id, row.text]),
  ).toEqual([
    ["assistant-t0.x.1", "old reply"],
    ["assistant-t1.x.1", "before the cut"],
    ["assistant-t1.x.2", "after"],
  ]);
});

// A message the pane cuts at a tool call the person sees: acpmux ends the segment there too
// (hub/stream.rs `cuts_reply`), so each part is named by its own segment, the same whether the page
// starts before the first part or between them, and an older page that brings the first part leaves
// the second where it was.
test("a reply cut at a visible tool call keeps both parts' ids when the older page comes in", async () => {
  const daemon = fakeDaemon(
    [
      user(1, "go"),
      chunk(2, "first part", "m1", "t1.x.1"),
      update(3, { sessionUpdate: "tool_call", toolCallId: "ls-1", title: "ls", kind: "read", status: "completed" }),
      chunk(4, "second part", "m1", "t1.x.2"),
    ],
    1000,
  );
  daemon.state.attachFrom = 3;
  const pane = await page(daemon);
  const replies = () =>
    pane
      .rows()
      .filter((row) => row.kind === "assistant")
      .map((row) => [row.id, row.text]);
  expect(replies()).toEqual([["assistant-t1.x.2", "second part"]]);
  const second = pane.rows().find((row) => row.id === "assistant-t1.x.2");
  await pane.older();
  expect(replies()).toEqual([
    ["assistant-t1.x.1", "first part"],
    ["assistant-t1.x.2", "second part"],
  ]);
  expect(pane.rows().find((row) => row.id === "assistant-t1.x.2")?.text).toBe(second?.text);
});
