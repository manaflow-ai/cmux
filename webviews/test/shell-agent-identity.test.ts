// l10n-allow-file: recorded protocol shapes with synthetic commands and output, not shipped UI.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const REVIEW = `reach review-router 'codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh "Review the branch"'`;
const OUTPUT =
  'OpenAI Codex\nmodel: gpt-6-astra\nhost: review-router\n{"session_id":"codex-session","harness":"codex"}\nVERDICT: SHIP';
const CHAT = "shell-identity-chat";

/// Replay the same ACP records the transcript consumes, rather than constructing a rendered row.
async function transcript(command: string | string[], structured = false, harness: string | undefined = "claude") {
  const session = { sessionId: CHAT, cwd: "/tmp/demo", title: "Review", harness, status: "done", updatedAt: 1000 };
  const update = (update: Record<string, unknown>, acpmux?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: CHAT, update, ...(acpmux && { _meta: { acpmux } }) },
  });
  const steps = [
    { dir: "mux", kind: "user_message", msg: { text: "Review the branch" } },
    { dir: "mux", kind: "turn_started", msg: {} },
    {
      dir: "in",
      kind: "tool_call",
      msg: update({
        sessionUpdate: "tool_call",
        toolCallId: "bash-review",
        title: "Bash",
        kind: "execute",
        status: "in_progress",
        rawInput: { command, description: "Run the review command" },
      }),
    },
    {
      dir: "in",
      kind: "tool_call_update",
      msg: update({
        sessionUpdate: "tool_call_update",
        toolCallId: "bash-review",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: OUTPUT } }],
      }),
    },
    ...(structured
      ? [
          {
            dir: "in",
            kind: "subagent_spawned",
            msg: update(
              { sessionUpdate: "subagent_spawned" },
              { subagents: [{ id: "actual-agent", parent: null, name: "Protocol reviewer", state: "running" }] },
            ),
          },
        ]
      : []),
    { dir: "mux", kind: "turn_result", msg: { status: "completed" } },
  ];
  const events = steps.map((step, index) => ({ ...step, sessionId: CHAT, seq: index + 1, at: (index + 1) * 1000 }));
  let socket: any;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: events.length };
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
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  let ready!: (rows: AcpmuxRow[]) => void;
  const rendered = new Promise<AcpmuxRow[]>((resolve) => {
    ready = resolve;
  });
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "fixture",
      sessionId: CHAT,
    },
    (snapshot) => {
      if (snapshot.rows.some((row) => row.kind === "subagents" || row.items?.some((item) => item.tool)))
        ready(snapshot.rows);
    },
    undefined,
    open,
  );
  try {
    return await rendered;
  } finally {
    client.close();
  }
}

for (const command of [
  REVIEW,
  `codex exec "Review the branch"`,
  `claude -p "Review the branch"`,
  `acpmux run -m codex "Review the branch"`,
  ["bash", "-lc", REVIEW],
]) {
  test(`shell command keeps its tool row: ${JSON.stringify(command)}`, async () => {
    const rows = await transcript(
      command,
      false,
      typeof command === "string" && command.startsWith("claude") ? "codex" : "claude",
    );
    expect(rows.flatMap((row) => row.subagents ?? [])).toEqual([]);
    const tools = rows.flatMap((row) => row.items?.flatMap((item) => (item.tool ? [item.tool] : [])) ?? []);
    expect(tools).toHaveLength(1);
    expect(tools[0]).toMatchObject({ id: "bash-review", kind: "execute", status: "completed", output: OUTPUT });
    expect(tools[0]!.command).toBe(typeof command === "string" ? command : command[2]);
  });
}

test("structured subagent metadata still creates a subagent beside an ordinary shell call", async () => {
  const rows = await transcript(REVIEW, true);
  expect(rows.flatMap((row) => row.subagents ?? []).map((agent) => agent.id)).toEqual(["actual-agent"]);
  expect(rows.flatMap((row) => row.items ?? []).some((item) => item.tool?.id === "bash-review")).toBe(true);
});
