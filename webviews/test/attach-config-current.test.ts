// l10n-allow-file: test fixtures, not shipped UI.
// Leo 2026-10-18: a chat moved from Low to High came back on Low after a relaunch. acpmux's attach
// names the session's current options; the replayed history holds the chat's older
// config_option_update events, and replaying them must not take the current value back.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000c2";
const START = Date.UTC(2026, 9, 18, 9, 0, 0);
const effort = (value: string) => ({
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  type: "select",
  currentValue: value,
  options: ["low", "medium", "high"].map((level) => ({ value: level, name: level })),
});
const configEvent = (seq: number, value: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "in",
  kind: "config_option_update",
  msg: {
    method: "session/update",
    params: { sessionId: CHAT, update: { sessionUpdate: "config_option_update", configOptions: [effort(value)] } },
  },
});
const userEvent = (seq: number, text: string) => ({
  sessionId: CHAT,
  seq,
  at: START + seq * 1000,
  dir: "mux",
  kind: "user_message",
  msg: { text },
});

/// A daemon whose session now runs `current`, with `history` (oldest first) as its replay.
function fakeDaemon(current: string, history: Record<string, unknown>[], extra: Record<string, unknown> = {}) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
    configOptions: [effort(current)],
    ...extra,
  };
  const lastSeq = () => Number(history.at(-1)?.seq ?? 0);
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
  const push = (event: Record<string, unknown>) => {
    history.push(event);
    socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }) });
  };
  return { open, push };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  let summary: any;
  await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: any) => (summary = snapshot.summary),
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  const shownEffort = () =>
    (summary?.configOptions ?? []).find((option: { id: string }) => option.id === "effort")?.currentValue;
  return { shownEffort, shownGoal: () => summary?.goal };
}

test("a reopened goal uses its persisted state, then follows completion and clearing", async () => {
  const goal = (status: string) => ({ objective: "Ship the fix", status });
  const event = (seq: number, value: unknown) => ({
    sessionId: CHAT,
    seq,
    at: START + seq * 1000,
    dir: "in",
    kind: "session_info_update",
    msg: {
      method: "session/update",
      params: { sessionId: CHAT, update: { sessionUpdate: "session_info_update", _meta: { goal: value } } },
    },
  });
  const daemon = fakeDaemon("high", [event(1, goal("active")), userEvent(2, "hi")], { goal: goal("paused") });
  const { shownGoal } = await connect(daemon);
  expect(shownGoal()?.status).toBe("paused");
  daemon.push(event(3, goal("complete")));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(shownGoal()?.status).toBe("complete");
  daemon.push(event(4, null));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(shownGoal()).toBeUndefined();
});

test("an attached chat shows the effort it runs now, not the one its history started on", async () => {
  const daemon = fakeDaemon("high", [configEvent(1, "low"), userEvent(2, "second chat")]);
  const { shownEffort } = await connect(daemon);
  expect(shownEffort()).toBe("high");

  // A change after the attach still lands.
  daemon.push(configEvent(3, "medium"));
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(shownEffort()).toBe("medium");
});

// Review of #21685: acpmux numbers a config update's event before it writes the session's options,
// so an attach in between names the old options with that event as its last. The event at the
// attach's own lastSeq is newer than or as new as the options it names: it applies.
test("an attach that names the old options with the change as its last event shows the change", async () => {
  const daemon = fakeDaemon("medium", [userEvent(1, "hi"), configEvent(2, "high")]);
  const { shownEffort } = await connect(daemon);
  expect(shownEffort()).toBe("high");
});
