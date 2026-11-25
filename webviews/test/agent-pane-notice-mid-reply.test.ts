// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A background shell's end noted while a reply streams never splits the reply (Leo, 2026-11-03: "this
// chat's text stream got cut in the middle by a tool call which is weird"). His chat read "...so it's
// once per machine," then "Background task finished: Wait for remote CI run", then "not once per
// chat." as a second message. The shell's call was on a page not loaded, so the end is noted on its
// own row (direct.ts `background_task_update`): that row goes after the message, which keeps its
// words in one row. The mock chat `mock-notice-mid-reply` (mockFixture.ts) draws the same scene.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import { mockSessions, sessionHistory } from "../src/agent-session/acpmux/mockFixture";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";
const START = Date.UTC(2026, 10, 3, 4, 0, 0);

/// The mock chat's own history, as acpmux records it.
function history() {
  const scene = mockSessions.find((session) => session.sessionId === "mock-notice-mid-reply")!;
  return sessionHistory(scene).map((step, index) => {
    const seq = index + 1;
    const base = { sessionId: CHAT, seq, at: START + seq * 1000 };
    if ("update" in step) {
      const kind = String(step.update.sessionUpdate);
      return {
        ...base,
        dir: "in",
        kind,
        msg: { method: "session/update", params: { sessionId: "agent-1", update: step.update } },
      };
    }
    return { ...base, dir: "mux", kind: step.mux, msg: step.msg ?? {} };
  });
}

function fakeDaemon(events: ReturnType<typeof history>) {
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness: "claude", status: "idle" };
  const lastSeq = events.at(-1)!.seq;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq };
      default:
        return null;
    }
  };
  return () => {
    const socket: any = {
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
}

test("a background task's end noted mid-reply goes after the reply, never inside it", async () => {
  let snapshot: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
    },
    undefined,
    fakeDaemon(history()),
  );
  try {
    const deadline = performance.now() + 2_000;
    while (!snapshot?.rows?.some((row: any) => row.kind === "backgroundTask")) {
      if (performance.now() > deadline) throw new Error("timed out waiting for the note");
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    const kinds = snapshot.rows.map((row: any) => row.kind).filter((kind: string) => kind !== "turnSummary");
    const replies = snapshot.rows.filter((row: any) => row.kind === "assistant");
    expect(replies).toHaveLength(1);
    expect(replies[0].text).toContain("once per machine, not once per chat.");
    // The note sits after the reply, not between its two halves.
    expect(kinds.indexOf("backgroundTask")).toBeGreaterThan(kinds.indexOf("assistant"));
  } finally {
    client.close();
  }
});
