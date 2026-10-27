// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// A background shell's state goes on the "Ran" row of the call that started it (Leo 2026-10-20:
// "'Background task finished: <same raw command>' must merge into the 'Ran <command>' row it
// belongs to … never a second row"). acpmux's `background_task_update` says `running` when the shell
// goes to the background and `completed`, `failed` or `stopped` when it ends, often turns later.
// Before, every end added its own "Background task finished: <raw command>" row under the call's.
import { expect, test } from "bun:test";
import { sessionSummary } from "../src/agent-session/acpmux/summary/sessionSummary";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnViewFrom, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const CHAT = "0190a000-0000-7000-8000-0000000000b9";
const START = Date.UTC(2026, 9, 20, 9, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const update = (update: Record<string, unknown>) => ({ method: "session/update", params: { update } });
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

const LONG =
  'export PATH="/Applications/cmux NIGHTLY.app/Contents/Resources/bin:$PATH"; B=~/Projects/x; cmux browser open https://example.com';

/// A Bash call Claude ran in the background: its result is only the launch.
const backgroundCall = (id: string, command: string): Step[] => [
  [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command, run_in_background: true },
    }),
  ],
  ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" })],
];
const task = (id: string, command: string, state: string, extra: object = {}): Step => [
  "in",
  "background_task_update",
  update({ sessionUpdate: "background_task_update", taskId: `task-${id}`, toolCallId: id, command, state, ...extra }),
];

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events, an older read
/// with the ones before; `push` sends live ones.
function fakeDaemon(history: ReturnType<typeof record>, page = history.length) {
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
        return { session, lastSeq: history.at(-1)?.seq ?? 0, events: history.slice(-page) };
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
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}

const callOf = (rows: AcpmuxRow[], id: string) => {
  const row = rows.find((candidate) => candidate.items?.some((item) => item.tool?.id === id));
  return { row, tool: row?.items?.find((item) => item.tool?.id === id)?.tool };
};

test("background completion invalidates a mixed streaming activity summary", async () => {
  const thought = update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } });
  const daemon = fakeDaemon(record([...backgroundCall("bg", "npm run dev"), ["in", "agent_thought_chunk", thought]]));
  const { client, rows } = await connect(daemon);
  try {
    expect(sessionSummary(rows()).backgroundTasks[0]?.state).toBe("running");
    daemon.push(record([task("bg", "npm run dev", "completed")], 4));
    expect(sessionSummary(rows()).backgroundTasks[0]?.state).toBe("completed");
  } finally {
    client.close();
  }
});

test("a background shell's states land on its call's row, a later turn's end included", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Start the dev server" }],
      ["mux", "turn_started", {}],
      ...backgroundCall("bg1", "npm run dev"),
      task("bg1", "npm run dev", "running", { origin: "background" }),
      [
        "in",
        "agent_message_chunk",
        update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Running." } }),
      ],
      ["mux", "turn_result", { status: "completed" }],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(rows().some((row) => row.kind === "backgroundTask")).toBe(false);
  const running = callOf(rows(), "bg1");
  expect(running.tool?.background).toEqual({ state: "running" });

  // The turn as drawn, its fold open, so the call's row is drawn.
  const expanded = new Set(
    rows()
      .filter((row) => row.kind === "user")
      .map((row) => `${WORKED}-${row.id}`),
  );
  const before = turnViewFrom(rows(), expanded, { now: START + 60_000 });
  const drawnBefore = before.rows.find((row) => row.id === running.row!.id)!;
  expect(drawnBefore.items?.[0]?.tool?.background?.state).toBe("running");

  // The next turn: the shell ends while it runs.
  daemon.push(
    record(
      [
        ["mux", "user_message", { text: "Is it up?" }],
        ["mux", "turn_started", {}],
        task("bg1", "npm run dev", "completed"),
      ],
      7,
    ),
  );
  expect(rows().filter((row) => row.kind === "backgroundTask")).toEqual([]);
  const ended = callOf(rows(), "bg1");
  expect(ended.row!.id).toBe(running.row!.id);
  expect(ended.row!.version).toBeGreaterThan(running.row!.version);
  expect(ended.tool?.background).toEqual({ state: "completed", endedAt: START + 9 * 1000 });

  // The earlier, ended turn draws the new state: its row is a new version, not the cached one.
  const expandedNow = new Set(
    rows()
      .filter((row) => row.kind === "user")
      .map((row) => `${WORKED}-${row.id}`),
  );
  const after = turnViewFrom(rows(), expandedNow, { now: START + 60_000 }, before);
  const drawnAfter = after.rows.find((row) => row.id === running.row!.id)!;
  expect(drawnAfter.version).not.toBe(drawnBefore.version);
  expect(drawnAfter.items?.[0]?.tool?.background?.state).toBe("completed");

  // A late `running` does not bring an ended shell back.
  daemon.push(record([task("bg1", "npm run dev", "running")], 10));
  expect(callOf(rows(), "bg1").tool?.background?.state).toBe("completed");
});

test("the call's own result keeps its background state", async () => {
  // Ctrl-B or Claude's auto-background: the shell goes to the background before its call returns.
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "Run the suite" }],
      ["mux", "turn_started", {}],
      [
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: "bg2",
          title: "cargo test",
          kind: "execute",
          status: "in_progress",
          rawInput: { command: "cargo test" },
        }),
      ],
      task("bg2", "cargo test", "running", { origin: "auto_backgrounded" }),
      ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: "bg2", status: "completed" })],
    ]),
  );
  const { rows } = await connect(daemon);
  const { tool } = callOf(rows(), "bg2");
  expect(tool?.status).toBe("completed");
  expect(tool?.background).toEqual({ state: "running" });
  daemon.push(record([task("bg2", "cargo test", "failed")], 6));
  expect(callOf(rows(), "bg2").tool?.background?.state).toBe("failed");
  expect(rows().some((row) => row.kind === "backgroundTask")).toBe(false);
});

test("a shell whose call is not in the transcript is one row, and joins its call once that loads", async () => {
  const history = record([
    ["mux", "user_message", { text: "Open the page" }],
    ["mux", "turn_started", {}],
    ...backgroundCall("bg3", LONG),
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Done?" }],
    ["mux", "turn_started", {}],
    task("bg3", LONG, "completed"),
    task("bg4", "pytest -x", "running"),
  ]);
  // The first page starts at the second prompt: the call is not loaded.
  const daemon = fakeDaemon(history, 4);
  const { client, rows } = await connect(daemon);
  const notes = () => rows().filter((row) => row.kind === "backgroundTask");
  // A running update without its call draws nothing; an end draws one row.
  expect(notes().map((row) => row.backgroundTask)).toEqual([{ toolCallId: "bg3", command: LONG, state: "completed" }]);

  // The older page brings the call: the end moves onto its row, and the separate row goes.
  await client.loadOlder();
  expect(callOf(rows(), "bg3").tool?.background?.state).toBe("completed");
  expect(notes()).toEqual([]);
});
