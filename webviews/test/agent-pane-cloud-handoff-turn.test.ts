// l10n-allow-file: test fixture prompts, not shipped UI.
// A chat on a Cloud machine sends each prompt that starts a turn under the hand-off turn the app
// opened for it (`handoff-<turn>-<id>`, cloudHandoffTurn.ts), so acpmux on the machine reports that
// turn (cmux-tui acpmux daemon/cloud_handoff.rs). A steer, a prompt that already names a turn (a
// Retry) and a page with no hand-off ask go under their own id, and nothing is asked for them.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000e1";
const START = Date.UTC(2026, 9, 28, 10, 0, 0);

/// A daemon with one idle chat that records every prompt it gets.
function fakeDaemon(prompts: Record<string, unknown>[]) {
  let socket: any;
  const session = {
    sessionId: CHAT,
    cwd: "/home/cmux/work/paint-33f597",
    title: "paint",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: Record<string, unknown>) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        prompts.push(params);
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  };
  return () => {
    socket = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        queueMicrotask(() =>
          socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }),
        );
      },
      close() {},
    };
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

async function client(prompts: Record<string, unknown>[]) {
  const connected = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => undefined,
    undefined,
    fakeDaemon(prompts),
  );
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  return connected;
}

const promptIdOf = (params: Record<string, unknown> | undefined) =>
  (params?._meta as { acpmux?: { promptId?: string } } | undefined)?.acpmux?.promptId;

test("a prompt that starts a turn goes under the hand-off turn the app opened, for this chat", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  const asked: string[] = [];
  chat.handoffTurn = async (sessionId) => (asked.push(sessionId), 3);
  await chat.send("fix the build", [], "p-1");
  expect(asked).toEqual([CHAT]);
  expect(promptIdOf(prompts[0])).toBe("handoff-3-p-1");
});

test("no turn from the app: the prompt goes under its own id", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  chat.handoffTurn = async () => undefined;
  await chat.send("fix the build", [], "p-2");
  expect(promptIdOf(prompts[0])).toBe("p-2");
});

test("a page with no hand-off ask, a steer, and a Retry's id that names a turn ask nothing", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  await chat.send("plain", [], "p-3");
  let asks = 0;
  chat.handoffTurn = async () => (asks++, 9);
  await chat.send("steer it", [], "p-4", undefined, undefined, true);
  await chat.send("again", [], "handoff-2-p-5");
  expect(asks).toBe(0);
  expect(prompts.map(promptIdOf)).toEqual(["p-3", "p-4", "handoff-2-p-5"]);
});

test("an id that only starts with the prefix names no turn: its send asks for one", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  chat.handoffTurn = async () => 4;
  await chat.send("note", [], "handoff-note");
  await chat.send("zero", [], "handoff-0-p-6");
  expect(prompts.map(promptIdOf)).toEqual(["handoff-4-handoff-note", "handoff-4-handoff-0-p-6"]);
});

test("a send while the chat's ask is out asks nothing, goes behind it and under its own id", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  let asks = 0;
  let answer: (turn: number) => void = () => undefined;
  chat.handoffTurn = () => (asks++, new Promise<number>((resolve) => (answer = resolve)));
  const first = chat.send("first", [], "p-7");
  const second = chat.send("second", [], "p-8");
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  expect(asks).toBe(1);
  expect(prompts).toEqual([]);
  answer(5);
  await Promise.all([first, second]);
  expect(prompts.map(promptIdOf)).toEqual(["handoff-5-p-7", "p-8"]);
});

test("the chat changing while the ask is out hands the prompt back: nothing is sent or drawn", async () => {
  const prompts: Record<string, unknown>[] = [];
  const chat = await client(prompts);
  let answer: (turn: number) => void = () => undefined;
  chat.handoffTurn = () => new Promise<number>((resolve) => (answer = resolve));
  const sent = chat.send("moved", [], "p-9", () => undefined);
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  (chat as unknown as { selectionGeneration: number }).selectionGeneration += 1;
  answer(6);
  await expect(sent).rejects.toThrow();
  expect(prompts).toEqual([]);
  expect((chat as unknown as { rows: Map<string, unknown> }).rows.has("local-p-9")).toBe(false);
});
