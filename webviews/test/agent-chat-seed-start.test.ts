// l10n-allow-file: public fixture hosts and models.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "../src/agent-session/acpmux/direct";

// The fake daemon creates a session from the real client's session/new and returns that
// session through attach. Assert the selected chat's state, not the seed or catalog schema.
async function start(seed: Partial<AcpmuxHostConfig>) {
  let socket: any;
  let session: any;
  let snapshot: any;
  let starts = 0;
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: session ? [session] : [] };
      case "session/new": {
        starts++;
        const { harness, model, peer } = params._meta.acpmux;
        session = { sessionId: "seeded-chat", harness, model, peer, cwd: params.cwd, status: "ready", turnCount: 0 };
        return { sessionId: session.sessionId };
      }
      case "_acpmux/attach":
        return { session, events: [], lastSeq: 0 };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", newSession: true, ...seed },
    (value) => { snapshot = value; },
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id !== undefined) queueMicrotask(() => socket.onmessage?.({
            data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }),
          }));
        },
        close() {},
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
  );
  return { client, snapshot: () => snapshot, starts: () => starts };
}

test("explicit harness and model survive first-send creation at the requested cwd", async () => {
  const run = await start({ cwd: "/tmp", harness: "fake", model: "fixture-model" } as Partial<AcpmuxHostConfig>);
  try {
    expect(run.starts()).toBe(0);
    await run.client.ensureSession();
    expect(run.snapshot().summary).toMatchObject({ cwd: "/tmp", harness: "fake", model: "fixture-model" });
  } finally { run.client.close(); }
});

test("a model-only seed remains sessionless until send and keeps the requested folder", async () => {
  const run = await start({ cwd: "/tmp", model: "fixture-model" });
  try {
    expect(run.starts()).toBe(0);
    await run.client.ensureSession();
    expect(run.snapshot().summary).toMatchObject({ cwd: "/tmp", model: "fixture-model" });
    await run.client.ensureSession();
    expect(run.starts()).toBe(1);
  } finally { run.client.close(); }
});

test("peer creation records the remote folder and all explicit startup picks", async () => {
  const run = await start({ cwd: "/local/unused" });
  try {
    await run.client.create("fake", "/remote/project", "dev-box", false, "fixture-model");
    expect(run.snapshot().summary).toMatchObject({ cwd: "/remote/project", peer: "dev-box", harness: "fake", model: "fixture-model" });
    await run.client.ensureSession();
    expect(run.starts()).toBe(1);
  } finally { run.client.close(); }
});
