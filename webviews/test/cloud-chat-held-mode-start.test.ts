// l10n-allow-file: test fixtures.
// A chat on a Cloud (or other remote) machine starts with its first send. A permission mode picked
// before then (Leo 2026-11-01: "i couldn't even pick a mode for this kind aqua sandpaper one") is
// held by the client and goes to the session that send starts, before the prompt, with the pick's
// gesture ticket; a start the machine refuses keeps it for the next send.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../src/agent-session/acpmux/direct";

async function cloud(options: { failStarts?: number } = {}) {
  let socket: any;
  let session: any;
  let starts = 0;
  let failures = options.failStarts ?? 0;
  const wire: string[] = [];
  // Another chat on the machine the person can switch to.
  const other = { sessionId: "other-chat", harness: "claude", status: "ready", turnCount: 3 };
  const answer = (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "remote", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: session ? [session, other] : [other] };
      case "session/new": {
        starts++;
        wire.push("session/new");
        if (failures > 0) {
          failures--;
          return { __error: { code: -32001, message: "kind-aqua-sandpiper refused to start the agent chat" } };
        }
        session = { sessionId: `cloud-${starts}`, harness: "claude", status: "ready", turnCount: 0 };
        return { sessionId: session.sessionId };
      }
      case "session/set_mode":
        wire.push(`set_mode ${params.sessionId} ${params.modeId} ${params._meta?.cmuxGesture ?? "-"}`);
        return {};
      case "_acpmux/attach":
        return { session: params.sessionId === other.sessionId ? other : session, events: [], lastSeq: 0 };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  };
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", newSession: true },
    () => undefined,
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id !== undefined)
            queueMicrotask(() => {
              const value = answer(message.method, message.params);
              socket.onmessage?.({
                data: JSON.stringify(
                  value?.__error
                    ? { jsonrpc: "2.0", id: message.id, error: value.__error }
                    : { jsonrpc: "2.0", id: message.id, result: value },
                ),
              });
            });
        },
        close() {},
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
  );
  return { client, wire };
}

test("a mode held before a Cloud chat's first send goes to the session that send starts", async () => {
  const run = await cloud();
  try {
    expect(run.client.startsOnSend).toBe(true);
    run.client.holdStartMode("bypassPermissions", Promise.resolve("gesture-1"));
    expect(run.wire).toEqual([]);
    const sessionId = await run.client.ensureSession();
    expect(sessionId).toBe("cloud-1");
    expect(run.wire).toEqual(["session/new", "set_mode cloud-1 bypassPermissions gesture-1"]);
    // Applied once: the chat's later sends set nothing again.
    await run.client.ensureSession();
    expect(run.wire).toHaveLength(2);
  } finally {
    run.client.close();
  }
});

test("a start the Cloud machine refuses keeps the held mode for the next send", async () => {
  const run = await cloud({ failStarts: 1 });
  try {
    run.client.holdStartMode("acceptEdits");
    await expect(run.client.ensureSession()).rejects.toThrow("refused to start");
    expect(run.wire).toEqual(["session/new"]);
    await run.client.ensureSession();
    expect(run.wire).toEqual(["session/new", "session/new", "set_mode cloud-2 acceptEdits -"]);
  } finally {
    run.client.close();
  }
});

test("a held mode goes to the session its start made, even when another chat is selected before its ticket resolves", async () => {
  const run = await cloud();
  try {
    let resolveTicket!: (ticket: string) => void;
    const pending = new Promise<string>((resolve) => (resolveTicket = resolve));
    // The start awaits the ticket only once its session is made: that is the moment to switch chats.
    let awaited = false;
    const ticket = { catch: (onError: (error: unknown) => string) => ((awaited = true), pending.catch(onError)) };
    run.client.holdStartMode("bypassPermissions", ticket as unknown as Promise<string>);
    const started = run.client.ensureSession();
    for (let turn = 0; turn < 200 && !awaited; turn += 1) await Promise.resolve();
    expect(awaited).toBe(true);
    await run.client.select("other-chat");
    expect(run.client.selectedSession).toBe("other-chat");
    resolveTicket("gesture-2");
    expect(await started).toBe("cloud-1");
    expect(run.wire.filter((line) => line.startsWith("set_mode"))).toEqual([
      "set_mode cloud-1 bypassPermissions gesture-2",
    ]);
  } finally {
    run.client.close();
  }
});

test("a mode picked while the start is pending is the one its session takes", async () => {
  const run = await cloud();
  try {
    run.client.holdStartMode("acceptEdits");
    const started = run.client.ensureSession();
    run.client.holdStartMode("bypassPermissions");
    await started;
    expect(run.wire.filter((line) => line.startsWith("set_mode"))).toEqual(["set_mode cloud-1 bypassPermissions -"]);
  } finally {
    run.client.close();
  }
});

test("a mode picked after the start selected its new session, before the start returned, is still its own", async () => {
  const run = await cloud();
  try {
    const started = run.client.ensureSession();
    for (let turn = 0; turn < 200 && run.client.selectedSession !== "cloud-1"; turn += 1) await Promise.resolve();
    expect(run.client.selectedSession).toBe("cloud-1");
    run.client.holdStartMode("acceptEdits");
    expect(await started).toBe("cloud-1");
    expect(run.wire.filter((line) => line.startsWith("set_mode"))).toEqual(["set_mode cloud-1 acceptEdits -"]);
  } finally {
    run.client.close();
  }
});
