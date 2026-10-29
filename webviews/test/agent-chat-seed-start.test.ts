// l10n-allow-file: public fixture hosts and models.
import { expect, test } from "bun:test";
import { AcpmuxDirectClient, type AcpmuxHostConfig } from "../src/agent-session/acpmux/direct";

// The fake daemon creates a session from the real client's session/new and returns that
// session through attach. Assert the selected chat's state, not the seed or catalog schema.
async function start(seed: Partial<AcpmuxHostConfig>, options: { failStarts?: number; holdPeerStart?: boolean } = {}) {
  let socket: any;
  let session: any;
  let snapshot: any;
  let starts = 0;
  let failures = options.failStarts ?? 0;
  const created: any[] = [];
  const trustRequests: { method: string; params: any }[] = [];
  let releasePeer = () => {};
  const peerGate = options.holdPeerStart
    ? new Promise<void>((resolve) => {
        releasePeer = resolve;
      })
    : undefined;
  let peerStarted = () => {};
  const peerStart = new Promise<void>((resolve) => {
    peerStarted = resolve;
  });
  const answer = async (method: string, params: any) => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "acp.trust.get":
      case "acp.trust.set":
        trustRequests.push({ method, params });
        return { cwd: params.cwd, level: "unknown" };
      case "_acpmux/watch":
        return { sessions: session ? [session] : [] };
      case "session/new": {
        if (params._meta?.acpmux?.peer) {
          peerStarted();
          await peerGate;
        }
        starts++;
        if (failures > 0) {
          failures--;
          return { __error: { code: -32001, message: "fixture start failed" } };
        }
        const { harness, model, peer } = params._meta.acpmux;
        session = {
          sessionId: `seeded-chat-${starts}`,
          harness,
          model,
          peer,
          cwd: params.cwd,
          status: "ready",
          turnCount: 0,
        };
        created.push({ ...session });
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
    (value) => {
      snapshot = value;
    },
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id !== undefined)
            queueMicrotask(async () => {
              const value = await answer(message.method, message.params);
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
  return {
    client,
    snapshot: () => snapshot,
    starts: () => starts,
    created: () => created.slice(),
    failNext: () => {
      failures = 1;
    },
    trustRequests,
    peerStart,
    releasePeer: () => releasePeer(),
  };
}

test("explicit harness and model survive first-send creation at the requested cwd", async () => {
  const run = await start({ cwd: "/tmp", harness: "fake", model: "fixture-model" } as Partial<AcpmuxHostConfig>);
  try {
    expect(run.starts()).toBe(0);
    await run.client.ensureSession();
    expect(run.snapshot().summary).toMatchObject({ cwd: "/tmp", harness: "fake", model: "fixture-model" });
  } finally {
    run.client.close();
  }
});

test("a model-only seed remains sessionless until send and keeps the requested folder", async () => {
  const run = await start({ cwd: "/tmp", model: "fixture-model" });
  try {
    expect(run.starts()).toBe(0);
    await run.client.ensureSession();
    expect(run.snapshot().summary).toMatchObject({ cwd: "/tmp", model: "fixture-model" });
    await run.client.ensureSession();
    expect(run.starts()).toBe(1);
  } finally {
    run.client.close();
  }
});

test("peer creation records the remote folder and all explicit startup picks", async () => {
  const run = await start({ cwd: "/local/unused" });
  try {
    await run.client.create("fake", "/remote/project", "dev-box", false, "fixture-model");
    expect(run.snapshot().summary).toMatchObject({
      cwd: "/remote/project",
      peer: "dev-box",
      harness: "fake",
      model: "fixture-model",
    });
    await run.client.ensureSession();
    expect(run.starts()).toBe(1);
  } finally {
    run.client.close();
  }
});

test("successful seeded creation consumes harness and model defaults", async () => {
  const run = await start({ cwd: "/tmp", harness: "fake", model: "fixture-model" });
  try {
    await run.client.create();
    await run.client.create("other", "/tmp/other");
    expect(run.created()).toMatchObject([
      { harness: "fake", model: "fixture-model", cwd: "/tmp" },
      { harness: "other", cwd: "/tmp/other" },
    ]);
    expect(run.created()[1]?.model).toBeUndefined();
  } finally {
    run.client.close();
  }
});

test("a failed create retains startup defaults for its retry", async () => {
  const run = await start({ cwd: "/tmp", harness: "fake", model: "fixture-model" }, { failStarts: 1 });
  try {
    await expect(run.client.create()).rejects.toThrow("fixture start failed");
    await run.client.create();
    expect(run.created()).toMatchObject([{ harness: "fake", model: "fixture-model", cwd: "/tmp" }]);
  } finally {
    run.client.close();
  }
});

test("direct startSession success clears startup defaults after explicit creation", async () => {
  const run = await start({ cwd: "/tmp", harness: "fake", model: "fixture-model" });
  try {
    await run.client.startSession("fake", "/tmp", undefined, undefined, false, "fixture-model");
    await run.client.create("other", "/tmp/other");
    expect(run.created()).toMatchObject([
      { harness: "fake", model: "fixture-model", cwd: "/tmp" },
      { harness: "other", cwd: "/tmp/other" },
    ]);
    expect(run.created()[1]?.model).toBeUndefined();
  } finally {
    run.client.close();
  }
});

test("a rejected peer start retries on that peer when the first send asks for a session", async () => {
  const run = await start(
    { cwd: "/remote/project", peer: "dev-box", harness: "fake", model: "fixture-model" },
    { failStarts: 1 },
  );
  try {
    await expect(run.client.create("fake", "/remote/project", "dev-box", false, "fixture-model")).rejects.toThrow(
      "fixture start failed",
    );
    await run.client.ensureSession();
    expect(run.created()).toMatchObject([
      { cwd: "/remote/project", peer: "dev-box", harness: "fake", model: "fixture-model" },
    ]);
    // The peer was a startup choice, so a later explicitly local chat does not inherit it.
    await run.client.create("other", "/local/project");
    expect(run.created()[1]?.peer).toBeUndefined();
  } finally {
    run.client.close();
  }
});

for (const firstSend of [false, true]) {
  test(`successful peer startup does not lend its folder to the next local chat (firstSend=${firstSend})`, async () => {
    const run = await start({ cwd: "/remote/project", peer: "dev-box", harness: "fake", model: "fixture-model" });
    try {
      if (firstSend) await run.client.ensureSession();
      else await run.client.create("fake", "/remote/project", "dev-box", false, "fixture-model");
      await run.client.create("other");
      expect(run.created()[0]).toMatchObject({ cwd: "/remote/project", peer: "dev-box" });
      expect(run.created()[1]).toMatchObject({ harness: "other" });
      expect(run.created()[1]?.cwd).toBeUndefined();
      expect(run.created()[1]?.peer).toBeUndefined();
    } finally {
      run.client.close();
    }
  });
}

test("an explicitly started local chat keeps the existing local folder inheritance", async () => {
  const run = await start({ cwd: "/local/project", harness: "fake" });
  try {
    await run.client.create("fake", "/local/project");
    await run.client.create("other");
    expect(run.created()[1]).toMatchObject({ cwd: "/local/project", harness: "other" });
    expect(run.created()[1]?.peer).toBeUndefined();
  } finally {
    run.client.close();
  }
});

for (const abandoned of [false, true]) {
  test(`a failed peer start cannot retarget the displayed chat's trust (abandoned=${abandoned})`, async () => {
    const run = await start({ cwd: "/local/project" });
    try {
      await run.client.create("fake", "/local/project");
      const original = run.snapshot().sessionId;
      run.failNext();
      await expect(run.client.create("fake", "/remote/project", "other-box")).rejects.toThrow(
        "fixture start failed",
      );
      expect(run.snapshot().sessionId).toBe(original);
      expect(run.client.trustPeer).toBeUndefined();
      if (abandoned) run.client.leave();
      await run.client.trustGet("/local/project");
      await run.client.trustSet("/local/project", "trusted");
      const target = abandoned ? {} : { sessionId: original };
      expect(run.trustRequests).toEqual([
        { method: "acp.trust.get", params: { cwd: "/local/project", ...target } },
        { method: "acp.trust.set", params: { cwd: "/local/project", level: "trusted", ...target } },
      ]);
    } finally {
      run.client.close();
    }
  });
}

for (const existing of [false, true]) {
  test(`leaving an in-flight peer start clears its trust route (existing=${existing})`, async () => {
    const run = await start({ cwd: "/local/project" }, { holdPeerStart: true });
    try {
      if (existing) await run.client.create("fake", "/local/project");
      const creating = run.client.create("fake", "/remote/project", "other-box");
      await run.peerStart;
      // The existing chat owns Trust even while the new peer's start has not answered.
      if (existing) {
        await run.client.trustGet("/local/project");
        expect(run.trustRequests[0]?.params).toEqual({
          cwd: "/local/project",
          sessionId: run.snapshot().sessionId,
        });
      }
      run.client.leave();
      expect(run.client.trustPeer).toBeUndefined();
      await run.client.trustGet("/local/project");
      expect(run.trustRequests.at(-1)?.params).toEqual({ cwd: "/local/project" });
      run.releasePeer();
      expect(await creating).toBeUndefined();
      expect(run.snapshot().sessionId).toBeUndefined();
      expect(run.client.trustPeer).toBeUndefined();
    } finally {
      run.releasePeer();
      run.client.close();
    }
  });
}

test("a failed sessionless peer start drops its trust route", async () => {
  const run = await start({ cwd: "/local/project" }, { failStarts: 1 });
  try {
    await expect(run.client.create("fake", "/remote/project", "other-box")).rejects.toThrow(
      "fixture start failed",
    );
    expect(run.client.trustPeer).toBeUndefined();
    await run.client.trustGet("/local/project");
    await run.client.trustSet("/local/project", "unknown");
    expect(run.trustRequests).toEqual([
      { method: "acp.trust.get", params: { cwd: "/local/project" } },
      { method: "acp.trust.set", params: { cwd: "/local/project", level: "unknown" } },
    ]);
  } finally {
    run.client.close();
  }
});
