// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-12, on a running turn whose live line read "Sending message to ad472b98… 1m 39s" long
// after Claude Code's SendMessage had answered "queued" in under a second: "NO MESSAGES DISPLAYED?".
// The line names a send only while its call runs: once the call's result arrives, the line moves
// on, whatever comes next (more work, a steer, the turn's end and a carried turn). The records are
// shaped as acpmux logged that SendMessage on 2026-11-12 (claude_stdio: a pending call with no
// input, its input on an in_progress update, then the result as a completed update).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: "window" in scope,
  document: "document" in scope,
  values: { window: scope.window, document: scope.document },
};

beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (saved[key]) scope[key] = saved.values[key];
    else delete scope[key];
});

type Daemon = {
  record: (target: string, step: unknown, at?: number) => unknown;
  emit: (target: string, step: unknown, at?: number) => void;
};
type Row = { id: string; kind: string; doingSendTo?: string; doing?: string; text?: string };

const AGENT = "ad472b98b4b82cf54";
const CALL = "toolu_send_1";
const sendPending = {
  update: {
    sessionUpdate: "tool_call",
    toolCallId: CALL,
    title: "SendMessage",
    kind: "other",
    status: "pending",
    _meta: { claude: { tool: "SendMessage" } },
  },
};
const sendInput = {
  update: {
    sessionUpdate: "tool_call_update",
    toolCallId: CALL,
    title: "SendMessage",
    kind: "other",
    status: "in_progress",
    rawInput: {
      to: AGENT,
      recipient: AGENT,
      recipient_kind: "agent",
      type: "message",
      summary: "Add the meta-problem",
      message: "Add the meta-problem: how did each base red reach base?",
      content: "Add the meta-problem: how did each base red reach base?",
    },
    _meta: { claude: { tool: "SendMessage" } },
  },
};
const sendResult = {
  update: {
    sessionUpdate: "tool_call_update",
    toolCallId: CALL,
    status: "completed",
    content: [
      {
        type: "content",
        content: {
          type: "text",
          text: JSON.stringify({
            success: true,
            message: `Message queued for delivery to ${AGENT} at its next tool round.`,
            pin: { id: AGENT, name: AGENT, ref: "9a32e0" },
          }),
        },
      },
    ],
  },
};
const say = (text: string) => ({ update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } });

/// What the live line of the turn names as going out, as the pane draws the chat (App.tsx `turnView`).
const sending = (rows: Row[]) =>
  turnView(rows as unknown as AcpmuxRow[], new Set(), { now: Date.now(), working: true })
    .filter((row) => row.doingSendTo !== undefined)
    .map((row) => row.doingSendTo);

test("a SendMessage's live line ends when its result arrives, through a steer and a carried turn", async () => {
  const { AcpmuxDirectClient } = await import("../direct");
  const { MockAcpmuxSocket, mockHost } = await import("../mock");
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const daemon = socket as unknown as Daemon;
  const chat = mockHost.sessionId!;
  daemon.record(chat, { mux: "user_message", msg: { text: "Tell the base-red helper to add the meta-problem" } });
  daemon.record(chat, { mux: "turn_started", msg: {} });
  let rows: Row[] = [];
  const snapshots: Array<() => void> = [];
  const until = async (check: () => boolean) => {
    for (let tries = 0; !check(); tries += 1) {
      if (tries > 200) throw new Error(`timed out; rows: ${JSON.stringify(rows.map((row) => row.kind))}`);
      await new Promise<void>((resolve) => {
        snapshots.push(resolve);
        setTimeout(resolve, 20);
      });
    }
  };
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      rows = snapshot.rows as Row[];
      for (const wake of snapshots.splice(0)) wake();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    await until(() => rows.some((row) => row.kind === "user"));
    daemon.emit(chat, sendPending);
    daemon.emit(chat, sendInput);
    await until(() => rows.some((row) => row.kind === "activity" && JSON.stringify(row).includes(CALL)));
    await until(() => sending(rows).length > 0);
    expect(sending(rows)).toEqual([`${AGENT.slice(0, 8)}…`]);

    daemon.emit(chat, sendResult);
    await until(() => sending(rows).length === 0);

    // More of the turn, a steer, the turn's end and the turn it carries: never "Sending" again.
    daemon.emit(chat, say("Sent. "));
    daemon.emit(chat, { mux: "user_message", msg: { text: "Why is this still happening", steer: true } });
    daemon.emit(chat, { mux: "turn_end", msg: { stopReason: "end_turn" } });
    daemon.emit(chat, { mux: "turn_result", msg: { status: "completed" } });
    daemon.emit(chat, { mux: "turn_started", msg: { carried: { promptIds: ["p2"] } } });
    daemon.emit(chat, say("Looking at the base reds now."));
    await until(() => rows.some((row) => row.text?.includes("Looking at the base reds")));
    expect(sending(rows)).toEqual([]);
  } finally {
    client.close?.();
  }
});
