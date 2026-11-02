// l10n-allow-file: synthetic parent and helper transcript fixtures, not shipped UI.
// An attach page can begin after a helper's spawn. Its owner tags still identify its work;
// missing lifecycle metadata must not turn that work into the parent's messages or tools.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const CHAT = "0190a000-0000-7000-8000-0000000000d5";
const ROOT = "parent-thread";
const HELPER = "helper-thread";
const START = Date.UTC(2026, 9, 31, 12);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];

function update(body: Record<string, unknown>, owner?: string): Step {
  return [
    "in",
    String(body.sessionUpdate),
    {
      method: "session/update",
      params: {
        sessionId: ROOT,
        update: body,
        ...(owner ? { _meta: { acpmux: { subagent: owner } } } : {}),
      },
    },
  ];
}

const say = (text: string, owner?: string) =>
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }, owner);
const think = (text: string, owner?: string) =>
  update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }, owner);
const init = (model: string, owner?: string) =>
  update(
    {
      sessionUpdate: "session_info_update",
      title: null,
      _meta: { claude: { tools: [], mcp_servers: [], plugins: [], skills: [], model, version: "2.1.303" } },
    },
    owner,
  );
const tool = (id: string, title: string, owner?: string) =>
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "read", status: "in_progress" }, owner);
const record = (steps: Step[], from: number) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));

function fakeDaemon(steps: Step[]) {
  // The omitted beginning held the helper's spawn; attach starts in the middle of its work.
  const history = record(steps, 100);
  let socket: any;
  const session = {
    sessionId: CHAT,
    agentSessionId: ROOT,
    cwd: "/home/dev/project",
    title: "Parent chat",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: history.at(-1)!.seq, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: history.at(-1)!.seq };
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
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const push = (...steps: Step[]) => {
    for (const event of record(steps, history.at(-1)!.seq + 1)) {
      history.push(event);
      socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let snapshot: Pick<AcpmuxSnapshot, "rows" | "subagentViews"> = { rows: [] };
  const waiters = new Set<() => void>();
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
      for (const wake of waiters) wake();
    },
    undefined,
    daemon.open,
  );
  const until = (holds: (value: typeof snapshot) => boolean) =>
    new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        waiters.delete(wake);
        reject(new Error("Expected transcript snapshot did not arrive"));
      }, 2000);
      const wake = () => {
        if (!holds(snapshot)) return;
        clearTimeout(timeout);
        waiters.delete(wake);
        resolve();
      };
      waiters.add(wake);
      wake();
    });
  return { client, snapshot: () => snapshot, until };
}

const replies = (rows: readonly AcpmuxRow[]) => rows.filter((row) => row.kind === "assistant").map((row) => row.text);
const tools = (rows: readonly AcpmuxRow[]) =>
  rows.flatMap((row) => row.items?.flatMap((item) => item.tool ?? []) ?? []);
const thoughts = (rows: readonly AcpmuxRow[]) =>
  rows.flatMap((row) => row.items?.filter((item) => !item.tool).map((item) => item.text) ?? []);

test("helper activity stays in its own chat when attach starts after its spawn, through live updates", async () => {
  const daemon = fakeDaemon([
    init("parent-model"),
    init("helper-model", HELPER),
    say("Helper replay reply", HELPER),
    think("Helper replay thought", HELPER),
    tool("helper-read", "Read helper.ts", HELPER),
    say("Parent replay reply"),
    tool("parent-read", "Read parent.ts"),
  ]);
  const { client, snapshot, until } = await connect(daemon);
  try {
    await until(({ rows }) => tools(rows).some((entry) => entry.id === "parent-read"));
    expect(replies(snapshot().rows)).toEqual(["Parent replay reply"]);
    expect(thoughts(snapshot().rows)).toEqual([]);
    expect(tools(snapshot().rows).map((entry) => entry.id)).toEqual(["parent-read"]);
    expect(
      snapshot()
        .rows.filter((row) => row.kind === "sessionStart")
        .map((row) => row.sessionStart?.model),
    ).toEqual(["parent-model"]);

    daemon.push(
      init("helper-live-model", HELPER),
      say("Helper live reply", HELPER),
      think("Helper live thought", HELPER),
      tool("helper-live-read", "Read helper-live.ts", HELPER),
      say("Parent live reply"),
      tool("parent-live-read", "Read parent-live.ts"),
    );
    await until(({ rows }) => tools(rows).some((entry) => entry.id === "parent-live-read"));
    expect(replies(snapshot().rows)).toEqual(["Parent replay reply", "Parent live reply"]);
    expect(thoughts(snapshot().rows)).toEqual([]);
    expect(tools(snapshot().rows).map((entry) => entry.id)).toEqual(["parent-read", "parent-live-read"]);
    expect(
      snapshot()
        .rows.filter((row) => row.kind === "sessionStart")
        .map((row) => row.sessionStart?.model),
    ).toEqual(["parent-model"]);

    // Lifecycle metadata arriving later names the helper without losing its earlier work.
    daemon.push([
      "in",
      "subagent_progress",
      {
        method: "session/update",
        params: {
          sessionId: ROOT,
          update: { sessionUpdate: "subagent_progress", subagentSessionId: HELPER },
          _meta: { acpmux: { subagents: [{ id: HELPER, parent: null, name: "Reviewer", state: "running" }] } },
        },
      },
    ]);
    await until(({ rows }) => rows.some((row) => row.subagents?.some((agent) => agent.name === "Reviewer")));
    const child = snapshot().subagentViews?.[HELPER] ?? [];
    expect(replies(child)).toEqual(["Helper replay reply", "Helper live reply"]);
    expect(thoughts(child)).toEqual(["Helper replay thought", "Helper live thought"]);
    expect(tools(child).map((entry) => entry.id)).toEqual(["helper-read", "helper-live-read"]);
    expect(replies(snapshot().rows)).toEqual(["Parent replay reply", "Parent live reply"]);

    // A report explicitly addressed to the parent remains a received message in that chat.
    daemon.push([
      "mux",
      "user_message",
      {
        text: "The helper's report for the parent",
        promptId: "helper-report",
        steer: true,
        _meta: {
          provenance: { kind: "agent_message", from: `acp:${HELPER}`, fromName: "Reviewer", msgId: "report-1" },
        },
      },
    ]);
    await until(({ rows }) => rows.some((row) => row.text === "The helper's report for the parent"));
    expect(snapshot().rows.find((row) => row.text === "The helper's report for the parent")?.incoming).toMatchObject({
      kind: "message",
      message: { name: "Reviewer", text: "The helper's report for the parent" },
    });
    expect(tools(snapshot().rows).map((entry) => entry.id)).toEqual(["parent-read", "parent-live-read"]);
  } finally {
    client.close();
  }
});
