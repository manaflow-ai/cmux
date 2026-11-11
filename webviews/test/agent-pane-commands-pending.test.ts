// l10n-allow-file: test fixture prompts, not shipped UI.
// The `/` menu says "Loading commands…" until the chat's own command list is read, never "No
// commands" before it (ui-state-fixes M7). The direct client names that window `commandsPending`:
// set from the attach until the log's command list is read back, cleared by that read whether it
// finds a list or none. A read that failed, or a link that went down before the list came, is
// `commandsFailed` ("Couldn't load commands." with Try Again), never loading and never empty;
// `retryCommands` asks again.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const dom = new JSDOM("<!doctype html>", { url: "http://localhost/" });
const scope = globalThis as Record<string, unknown>;
const had = { window: scope.window, document: scope.document };
beforeAll(() => {
  scope.window = dom.window;
  scope.document = dom.window.document;
});
afterAll(() => {
  for (const key of ["window", "document"] as const)
    if (had[key] === undefined) delete scope[key];
    else scope[key] = had[key];
});

const CHAT = "0190a000-0000-7000-8000-0000000000c7";
const START = Date.UTC(2026, 10, 9, 9, 0, 0);

type FakeSocket = { readyState: number; onclose?: (event?: unknown) => void };
type CommandsRead = { resolve: (events: unknown[]) => void; reject: (error: Error) => void };

/// A daemon with one existing chat whose log holds a finished turn and no command list in its
/// attach page; its read back of the command list (`_acpmux/events` with `kinds`) waits for the test.
function fakeDaemon(reads: CommandsRead[], sockets: FakeSocket[] = []) {
  const events = [
    { kind: "user_message", msg: { text: "Fix the build", promptId: "p-1", turnId: "turn-1" } },
    { kind: "turn_started", msg: { promptId: "p-1", turnId: "turn-1" } },
    { kind: "turn_result", msg: { promptId: "p-1", turnId: "turn-1", status: "completed" } },
  ].map((step, index) => ({ sessionId: CHAT, seq: index + 1, at: START + index * 1000, dir: "mux", ...step }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: Record<string, unknown>): Promise<unknown> | unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        if (Array.isArray(params.kinds) && params.kinds.includes("available_commands_update"))
          return new Promise((resolve, reject) =>
            reads.push({
              resolve: (found) => resolve({ events: found, hasMore: false, lastSeq: events.length }),
              reject,
            }),
          );
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };
  return () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        if (message.id === undefined) return;
        void Promise.resolve(answer(message.method, message.params ?? {})).then(
          (result) => socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }),
          (error: Error) =>
            socket.onmessage?.({
              data: JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: error.message } }),
            }),
        );
      },
      close() {},
    };
    sockets.push(socket);
    queueMicrotask(() => socket.onopen?.());
    return socket as WebSocket;
  };
}

const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

async function open() {
  const { AcpmuxDirectClient } = await import("../src/agent-session/acpmux/direct");
  const reads: CommandsRead[] = [];
  const sockets: FakeSocket[] = [];
  let shown: AcpmuxSnapshot | undefined;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    (snapshot: AcpmuxSnapshot) => (shown = snapshot),
    undefined,
    fakeDaemon(reads, sockets),
  );
  await settle();
  return { client, reads, sockets, shown: () => shown };
}

test("an attached chat's commands are pending until the log's list is read, then listed", async () => {
  const { client, reads, shown } = await open();
  expect(shown()?.chatRead).toBe(true);
  expect(reads).toHaveLength(1);
  // Attached, rows drawn, command list not read yet: `/` must not say "No commands".
  expect(shown()?.commandsPending).toBe(true);
  reads[0]!.resolve([
    {
      sessionId: CHAT,
      seq: 1,
      at: START,
      dir: "in",
      kind: "available_commands_update",
      msg: {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "available_commands_update",
            availableCommands: [{ name: "review", description: "Review the diff" }],
          },
        },
      },
    },
  ]);
  await settle();
  expect(shown()?.commandsPending).toBeUndefined();
  expect(shown()?.commands?.map((command) => command.name)).toEqual(["review"]);
  client.close?.();
});

test("a read that finds no list ends the wait: the chat has no commands", async () => {
  const { client, reads, shown } = await open();
  expect(shown()?.commandsPending).toBe(true);
  reads[0]!.resolve([]);
  await settle();
  expect(shown()?.commandsPending).toBeUndefined();
  expect(shown()?.commands).toEqual([]);
  client.close?.();
});

const REVIEW_LIST = [
  {
    sessionId: CHAT,
    seq: 1,
    at: START,
    dir: "in",
    kind: "available_commands_update",
    msg: {
      method: "session/update",
      params: {
        sessionId: "agent-1",
        update: {
          sessionUpdate: "available_commands_update",
          availableCommands: [{ name: "review", description: "Review the diff" }],
        },
      },
    },
  },
];

// Round 4 (verifier M7): a failed read set the list read, so `/` said "No commands" for an agent
// whose list was never read. It is a failure with Try Again; Try Again reads again and the list
// it finds replaces the error.
test("a failed read is a failure with Try Again, never loading and never No commands", async () => {
  const { slashMenuEmptyLabel } = await import("../src/agent-session/acpmux/composerModel");
  const { client, reads, shown } = await open();
  expect(shown()?.commandsPending).toBe(true);
  reads[0]!.reject(new Error("events read failed"));
  await settle();
  expect(shown()?.commandsPending).toBeUndefined();
  expect(shown()?.commandsFailed).toBe(true);
  expect(slashMenuEmptyLabel(shown()?.commands, shown()?.commandsPending, shown()?.commandsFailed)).toBe(
    "composer.loadCommandsFailed",
  );

  client.retryCommands();
  await settle();
  expect(reads).toHaveLength(2);
  expect(shown()?.commandsFailed).toBeUndefined();
  expect(shown()?.commandsPending).toBe(true);
  reads[1]!.resolve(REVIEW_LIST);
  await settle();
  expect(shown()?.commandsFailed).toBeUndefined();
  expect(shown()?.commandsPending).toBeUndefined();
  expect(shown()?.commands?.map((command) => command.name)).toEqual(["review"]);
  client.close?.();
});

test("a link that goes down before the list came is a failure, not No commands", async () => {
  const { slashMenuEmptyLabel } = await import("../src/agent-session/acpmux/composerModel");
  const { client, sockets, shown } = await open();
  expect(shown()?.commandsPending).toBe(true);
  const socket = sockets.at(-1)!;
  socket.readyState = 3;
  socket.onclose?.({ code: 1006, reason: "", wasClean: false });
  await settle();
  expect(shown()?.commandsPending).toBeUndefined();
  expect(shown()?.commandsFailed).toBe(true);
  expect(slashMenuEmptyLabel(shown()?.commands, shown()?.commandsPending, shown()?.commandsFailed)).toBe(
    "composer.loadCommandsFailed",
  );
  client.close?.();
});
