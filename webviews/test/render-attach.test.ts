// l10n-allow-file: test fixtures, not shipped UI.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";

const chunk = (seq: number, text: string) => ({
  sessionId: "chat-1", seq, at: seq, dir: "in", kind: "agent_message_chunk",
  msg: { method: "session/update", params: { update: { content: { type: "text", text } } } },
});

test("attach and replay cannot authorize a render, even in an unfinished turn", async () => {
  let socket: any;
  let rows: AcpmuxRow[] = [];
  const session = { sessionId: "chat-1", cwd: "/tmp/project", harness: "claude", title: "Chat", status: "running", updatedAt: 1 };
  const history = [chunk(1, "```cmux-render\n<script>while(1){}</script>\n```")];
  const open = () => {
    socket = {
      readyState: 1,
      close() {},
      send(raw: string) {
        const { id, method } = JSON.parse(raw);
        const result = method === "initialize" ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } }
          : method === "_acpmux/watch" ? { sessions: [session] }
          : method === "_acpmux/attach" ? { session, lastSeq: 1, events: history }
          : null;
        if (id !== undefined) queueMicrotask(() => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id, result }) }));
      },
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", sessionId: "chat-1" },
    (snapshot) => { rows = snapshot.rows; }, undefined, open,
  );
  try {
    await client.select("chat-1");
    const attached = rows.find((row) => row.kind === "assistant")!;
    expect(attached.streaming).toBe(true);
    expect(attached.renderLive).toBe(false);
    const emit = (event: Record<string, unknown>) => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
    // More tokens cannot reauthorize the page already loaded from history.
    emit(chunk(2, "\nMore text"));
    expect(rows.find((row) => row.kind === "assistant")!.renderLive).toBe(false);
    emit({ sessionId: "chat-1", seq: 3, at: 3, dir: "mux", kind: "turn_result", msg: { status: "completed" } });
    emit(chunk(4, "```cmux-render\n<p>New live page</p>\n```"));
    expect(rows.find((row) => row.id === "assistant-4")!.renderLive).toBe(true);
  } finally {
    client.close();
  }
});
