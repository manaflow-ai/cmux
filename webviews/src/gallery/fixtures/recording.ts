// Real-shaped transcripts: a recorded acpmux session, anonymized (scripts/gallery/anonymize-recording.ts),
// turned into the pane's rows by the pane's own client, as acpmux serves it on an attach. Leo,
// 2026-11-01: "how about like the apparatuses for improving ui verification? let's examine what we
// can do better for our workflows". A gallery state built this way has the long tool runs, steers,
// agent inbox messages and outputs of every length a real chat has, so a rule that holds on the
// synthetic fixtures but breaks on a real chat (a reply off the icon column, a fold that moves rows)
// shows in the gallery too. The same replay as webviews/test/transcript-claude-turn-groups.test.ts.
import { AcpmuxDirectClient } from "../../agent-session/acpmux/direct";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";

export type Recording = {
  /** The anonymized ndjson (one acpmux event a line). */
  events: () => Promise<string>;
  harness: "claude" | "codex";
};

type Event = { sessionId: string; seq: number; at: number };

/** The rows the pane's client makes of a recording, attached as acpmux serves it. */
export async function rowsFromRecording(text: string, harness: string): Promise<AcpmuxRow[]> {
  const events = text
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as Event);
  const last = events.at(-1);
  const sessionId = events[0]?.sessionId ?? "0190a000-0000-7000-8000-0000000000d1";
  const session = {
    sessionId,
    cwd: "/home/dev/project",
    title: "Recorded chat",
    harness,
    family: harness,
    status: "ready",
    steering: false,
    turnCount: 1,
    updatedAt: last?.at ?? 0,
  };
  const lastSeq = last?.seq ?? 0;
  const answer = (method: string) => {
    if (method === "initialize")
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    if (method === "_acpmux/watch") return { sessions: [session] };
    if (method === "_acpmux/attach") return { session, lastSeq, events, hasMore: false };
    if (method === "_acpmux/events") return { events: [], hasMore: false, more: false, lastSeq };
    return null;
  };
  type FakeSocket = {
    readyState: number;
    onopen?: () => void;
    onmessage?: (event: { data: string }) => void;
    send(raw: string): void;
    close(): void;
  };
  const open = () => {
    const socket: FakeSocket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw) as { id?: number; method: string };
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
    return socket as unknown as WebSocket;
  };
  let rows: AcpmuxRow[] = [];
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId },
    (snapshot) => {
      rows = (snapshot as { rows: AcpmuxRow[] }).rows;
    },
    undefined,
    open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  client.close();
  return rows;
}
