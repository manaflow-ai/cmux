// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A compaction and a failover are noted in the transcript where they happened. Before, acpmux's
// Claude translator dropped `compact_boundary` (only the context ring reset) and no client drew
// acpmux's `failover` record, so a chat that compacted, or moved to another harness after a usage
// limit, went on with nothing in the transcript saying so.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { compactTokens } from "../src/agent-session/acpmux/conversation/CompactionNote";

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const START = Date.UTC(2026, 9, 18, 9, 0, 0);
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

/// A daemon over a fake socket: attach answers with `history`'s newest `page` events; `push` sends live ones.
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
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
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
              data: JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params),
              }),
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
      socket.onmessage?.({
        data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }),
      });
    }
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "t",
      sessionId: CHAT,
    },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return { client, rows: () => rows };
}
test("a compaction is one row: running, then how it ended", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "go on" }],
      ["mux", "turn_started", {}],
      ["in", "compaction", update({ sessionUpdate: "compaction", state: "running", reason: "account_switch" })],
    ]),
  );
  const { rows } = await connect(daemon);
  const compactions = () => rows().filter((row) => row.kind === "compaction");
  expect(compactions().map((row) => row.compaction)).toEqual([{ state: "running", reason: "account_switch" }]);
  const id = compactions()[0]!.id;
  daemon.push(
    record(
      [
        [
          "in",
          "compaction",
          update({
            sessionUpdate: "compaction",
            state: "completed",
            trigger: "manual",
            reason: "account_switch",
            preTokens: 27183,
            postTokens: 2047,
          }),
        ],
        // The summary is context for a handoff, not a row.
        ["in", "compaction_summary", update({ sessionUpdate: "compaction_summary", text: "Summary: PLUM-42" })],
      ],
      4,
    ),
  );
  expect(compactions().map((row) => [row.id, row.compaction])).toEqual([
    [id, { state: "completed", reason: "account_switch", preTokens: 27183, postTokens: 2047 }],
  ]);
  expect(rows().some((row) => (row.text ?? "").includes("PLUM-42"))).toBe(false);

  // The next compaction gets its own row.
  daemon.push(record([["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })]], 6));
  expect(compactions().map((row) => row.compaction?.state)).toEqual(["completed", "running"]);
});

test("a failover to the fallback harness is noted", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "keep going" }],
      ["mux", "turn_started", {}],
      ["mux", "failover", { from: "claude-sr2", to: "codex", reason: "Claude AI usage limit reached", turnId: "t1" }],
    ]),
  );
  const { rows } = await connect(daemon);
  expect(
    rows()
      .filter((row) => row.kind === "failover")
      .map((row) => row.failover),
  ).toEqual([{ from: "claude-sr2", to: "codex" }]);
});

test("token counts read as thousands", () => {
  expect([27183, 2047, 999, 1000, 412000].map(compactTokens)).toEqual(["27k", "2k", "999", "1k", "412k"]);
});
