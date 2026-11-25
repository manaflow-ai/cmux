// l10n-allow-file: test fixtures, not shipped UI.
// Leo, 2026-11-22: "get that gui agent chat sped up to be nearly as fast as the terminal coming back". A
// relaunched chat shows its live page only once the composer read the chat's saved draft (draftSettleHold.ts),
// and that read went out after the attach answered: a third round trip after the socket opened. The open now asks
// the draft with the attach (direct.ts `earlyDraft`), and the composer's first read takes that answer.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

const CHAT = "0190a000-0000-7000-8000-0000000000d7";
const START = Date.UTC(2026, 10, 22, 1, 0, 0);

function fakeDaemon() {
  const asked: { method: string; params: any; afterAttachAnswered: boolean }[] = [];
  let attachAnswered = false;
  let draft = "kept draft";
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/x",
    title: "x",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: 1,
    updatedAt: START,
  };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        attachAnswered = true;
        return { session, lastSeq: 0, events: [], hasMore: false };
      case "_acpmux/draft_get":
        return { draft };
      case "_acpmux/draft_set":
        draft = params.text;
        return null;
      case "_acpmux/events":
        return { events: [], hasMore: false, more: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const open = () => {
    const socket: any = {
      readyState: 1,
      send(raw: string) {
        const message = JSON.parse(raw);
        asked.push({ method: message.method, params: message.params, afterAttachAnswered: attachAnswered });
        if (message.id !== undefined)
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
  return { open, asked, drafts: () => asked.filter((entry) => entry.method === "_acpmux/draft_get") };
}

async function connect(daemon: ReturnType<typeof fakeDaemon>) {
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", token: "t", sessionId: CHAT },
    () => undefined,
    undefined,
    daemon.open,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  return client;
}

test("the open asks the chat's draft with its attach, and the composer's first read takes that answer", async () => {
  const daemon = fakeDaemon();
  const client = await connect(daemon);
  expect(daemon.drafts().map((entry) => [entry.params.sessionId, entry.afterAttachAnswered])).toEqual([[CHAT, false]]);
  expect(await client.readDraft(CHAT)).toEqual({ draft: "kept draft" });
  expect(daemon.drafts()).toHaveLength(1);
  // Taken once: a later read asks acpmux again.
  await client.readDraft(CHAT);
  expect(daemon.drafts()).toHaveLength(2);
  client.close();
});

test("a draft written after the open's read is never answered from it", async () => {
  const daemon = fakeDaemon();
  const client = await connect(daemon);
  await client.writeDraft(CHAT, "typed since");
  expect(await client.readDraft(CHAT)).toEqual({ draft: "typed since" });
  expect(daemon.drafts()).toHaveLength(2);
  client.close();
});

test("an early answer older than its bound is never taken", async () => {
  const daemon = fakeDaemon();
  const client = await connect(daemon);
  const realNow = Date.now;
  Date.now = () => realNow() + 60_000;
  try {
    await client.readDraft(CHAT);
  } finally {
    Date.now = realNow;
  }
  expect(daemon.drafts()).toHaveLength(2);
  client.close();
});

test("a read of another chat asks acpmux for that chat", async () => {
  const daemon = fakeDaemon();
  const client = await connect(daemon);
  const other = "0190a000-0000-7000-8000-0000000000d8";
  await client.readDraft(other);
  expect(daemon.drafts().map((entry) => entry.params.sessionId)).toEqual([CHAT, other]);
  client.close();
});
