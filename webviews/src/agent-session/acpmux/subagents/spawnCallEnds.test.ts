// l10n-allow-file: synthetic chat fixtures, not shipped UI.
// An Agent call ends whichever order acpmux names its subagent in. When the Agent `tool_call`
// draws its row before the `subagent_spawned` record names it (`toolCallId`), the fold then held
// that call as its subagent's and swallowed its later updates, its end too: the card stayed
// running forever and ticked every second (AgentCallCard.tsx `usePageNow`), 151 such cards in a
// long coordinator chat ("chats flat at any length"). Named first, the call draws no row of its
// own (its subagent's group row stands for it), and its end draws none either.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import type { AcpmuxRow } from "../model";

let seq = 0;
const event = (kind: string, dir: "mux" | "in", msg: EventRecord["msg"]): EventRecord => ({
  seq: (seq += 1),
  kind,
  dir,
  msg,
  sessionId: "coord",
  at: 1794473499000 + seq * 400,
});
const update = (data: Record<string, unknown>, acpmux?: Record<string, unknown>) =>
  event(String(data.sessionUpdate), "in", {
    method: "session/update",
    params: { update: data, ...(acpmux ? { _meta: { acpmux } } : {}) },
  });
const agentCall = () =>
  update({
    sessionUpdate: "tool_call",
    toolCallId: "agent-1",
    title: "Agent",
    kind: "think",
    status: "in_progress",
    rawInput: { description: "Review the diff", prompt: "Review the diff.", subagent_type: "general-purpose" },
  });
const spawned = () =>
  update(
    { sessionUpdate: "subagent_spawned", subagentSessionId: "sub-1" },
    {
      subagents: [
        {
          id: "sub-1",
          parent: null,
          name: "reviewer",
          task: "Review the diff",
          state: "running",
          toolCallId: "agent-1",
        },
      ],
    },
  );
const finished = () =>
  update({
    sessionUpdate: "tool_call_update",
    toolCallId: "agent-1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "Reviewed: no findings.\nagentId: sub-1" } }],
  });

function replay(events: EventRecord[]): AcpmuxRow[] {
  let rows: readonly AcpmuxRow[] = [];
  const client = AcpmuxDirectClient.replay("coord", events, (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    client.seekReplay(events.at(-1)!.seq);
  } finally {
    client.close();
  }
  return [...rows];
}
const calls = (rows: AcpmuxRow[]) =>
  rows.flatMap((row) => row.items ?? []).flatMap((item) => (item.tool?.id === "agent-1" ? [item.tool] : []));
const turn = (middle: EventRecord[]) => [
  event("user_message", "mux", { text: "Review it" }),
  event("turn_started", "mux", {}),
  ...middle,
  event("turn_result", "mux", { status: "completed" }),
];

test("an Agent call that drew its row before its subagent was named ends completed, never running", () => {
  const rows = replay(turn([agentCall(), spawned(), finished()]));
  const drawn = calls(rows);
  expect(drawn).toHaveLength(1);
  expect(drawn[0]!.status).toBe("completed");
  // Its subagent still draws as its group row.
  expect(rows.some((row) => row.subagents?.some((agent) => agent.id === "sub-1"))).toBe(true);
});

test("an Agent call named first draws only its subagent's group row, its end included", () => {
  const rows = replay(turn([spawned(), agentCall(), finished()]));
  expect(calls(rows)).toHaveLength(0);
  expect(rows.some((row) => row.subagents?.some((agent) => agent.id === "sub-1"))).toBe(true);
});
