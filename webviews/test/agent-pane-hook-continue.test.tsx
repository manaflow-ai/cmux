// l10n-allow-file: test fixture prompts and a hook's reason, not shipped UI.
// A Stop hook that blocks makes Claude Code go on with the hook's reason as a new input, in the same
// turn: acpmux sends it as `hook_feedback` (claude_stdio/hook_feedback.rs). Without a mark the text
// after it read as a second answer (Leo, 2026-11-22: "if you did get hooked, i think it should get
// displayed better"); the pane draws one note where the turn went on, between the two replies.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { HookContinueNote } from "../src/agent-session/acpmux/conversation/HookContinueNote";
import { HOOK_CONTINUE } from "../src/agent-session/acpmux/conversation/hookContinueKind";

const CHAT = "0190a000-0000-7000-8000-0000000000e7";
const START = Date.UTC(2026, 10, 22, 8, 0, 0);
type Step = [dir: string, kind: string, msg: Record<string, unknown>];
const record = (steps: Step[], from = 1) =>
  steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: from + index,
    at: START + (from + index) * 1000,
    dir,
    kind,
    msg,
  }));
type Recorded = ReturnType<typeof record>[number];

/// A daemon over a fake socket for a chat on `harness`: attach answers with `history`.
function fakeDaemon(history: Recorded[], harness: string, family: string) {
  let socket: any;
  const session = { sessionId: CHAT, cwd: "/Users/dev/app", title: "x", harness, family, status: "idle" };
  const lastSeq = () => history.at(-1)?.seq ?? 0;
  const answer = (method: string) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: lastSeq(), events: history, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: lastSeq() };
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
  return { open };
}

/// Yields until `ready()` holds; fails after 2 s with what it waited for.
async function until(ready: () => boolean, what: string) {
  const deadline = performance.now() + 2_000;
  while (!ready()) {
    if (performance.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
}

const REASON = "Save one note before you stop.";
const say = (text: string, messageId: string) => ({
  method: "session/update",
  params: {
    sessionId: CHAT,
    update: { sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } },
  },
});

test("a Stop hook's continuation is marked between the reply and the text after it", async () => {
  const daemon = fakeDaemon(
    record([
      ["mux", "user_message", { text: "land it" }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", say("Merged #4112.", "m1")],
      [
        "in",
        "hook_feedback",
        {
          method: "session/update",
          params: { sessionId: CHAT, update: { sessionUpdate: "hook_feedback", hookEvent: "Stop", text: REASON } },
        },
      ],
      ["in", "agent_message_chunk", say("Saved a note.", "m2")],
    ]),
    "claude",
    "claude",
  );
  let snapshot: any;
  let attached = false;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (next: any) => {
      snapshot = next;
      attached ||= next.connection === "connected";
    },
    undefined,
    daemon.open,
  );
  try {
    await until(() => attached, "the attach");
    const order = (snapshot.rows as AcpmuxRow[])
      .filter((row) => row.kind === "assistant" || row.kind === HOOK_CONTINUE)
      .map((row) => (row.kind === "assistant" ? row.text : `hook: ${row.hookContinue?.reason}`));
    expect(order).toEqual(["Merged #4112.", `hook: ${REASON}`, "Saved a note."]);
  } finally {
    client.close();
  }
});

test("the note says a Stop hook asked to continue, with the reason in reach", () => {
  const html = renderToStaticMarkup(<HookContinueNote note={{ event: "Stop", reason: REASON }} />);
  expect(html).toContain("Stop hook asked to continue");
  expect(html).toContain(REASON);
});
