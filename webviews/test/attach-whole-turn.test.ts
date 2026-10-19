// l10n-allow-file: test fixtures, not shipped UI.
// Lucas 2026-10-19: a chart reply drew fine while it streamed, then after a relaunch showed its HTML
// as text and an empty code card. Opening a chat loads only its newest records, and a long reply
// (hundreds of chunks) put the start of that page inside the reply's ```cmux-render fence: the tail
// drew as a whole reply. The open now reaches back to the turn's start, as older pages do.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000d3";
const START = Date.UTC(2026, 9, 19, 9, 0, 0);
const record = (seq: number, dir: string, kind: string, msg: Record<string, unknown>) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir,
  kind,
  msg,
});
const chunk = (seq: number, text: string) =>
  record(seq, "in", "agent_message_chunk", {
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
// One turn whose reply carries a render fence, split across many chunks.
const REPLY = [
  "Here is the chart.\n\n",
  "```cmux-render\n",
  "<div id='c'></div>\n",
  "<table><tr><td>RAV4</td></tr></table>\n",
  "<script>cmux.chart(document.getElementById('c'), {type:'line'})</script>\n",
  "```\n",
];
const history = [
  record(1, "mux", "user_message", { text: "Show me a chart" }),
  record(2, "mux", "turn_started", {}),
  ...REPLY.map((text, index) => chunk(3 + index, text)),
  record(3 + REPLY.length, "mux", "turn_result", { status: "completed" }),
];
/// Where the daemon's open page starts: inside the fence, as a byte-capped newest page can.
const OPEN_FROM = 5;

function fakeDaemon() {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "codex",
    family: "codex",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
  };
  const lastSeq = Number(history.at(-1)!.seq);
  const answer = (method: string, params: Record<string, unknown>) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq, events: history.filter((event) => event.seq >= OPEN_FROM), hasMore: true };
      case "_acpmux/events": {
        const before = Number(params.beforeSeq ?? Infinity);
        const events = history.filter((event) => event.seq < before);
        return { events, hasMore: false, more: false, lastSeq };
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
                result: answer(message.method, message.params ?? {}),
              }),
            }),
          );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  return { open };
}

test("a chat whose open page starts inside a reply shows the whole reply, fence and all", async () => {
  let rows: any[] = [];
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (rows = snapshot.rows),
    undefined,
    fakeDaemon().open,
  );
  for (let tick = 0; tick < 5; tick++) await new Promise((resolve) => setTimeout(resolve, 0));
  const replies = rows.filter((row) => row.kind === "assistant");
  expect(replies.length).toBe(1);
  expect(replies[0].text).toBe(REPLY.join(""));
  expect(rows.some((row) => row.kind === "user" && row.text === "Show me a chart")).toBe(true);
});
