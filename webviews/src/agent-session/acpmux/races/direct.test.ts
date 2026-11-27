import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../direct";
import { raceFixture } from "./fixtures";
import type { RaceRecord } from "./model";

test("race RPCs preserve parent scope and live race records reach subscribers until removal", async () => {
  let socket!: { onopen?: () => void; onmessage?: (event: { data: string }) => void };
  const requests: { method: string; params: Record<string, unknown> }[] = [];
  let connected!: () => void;
  const ready = new Promise<void>((resolve) => {
    connected = resolve;
  });
  const session = { sessionId: raceFixture.parent, cwd: "/project", title: "Race", harness: "codex", status: "idle" };
  const client = await AcpmuxDirectClient.connect(
    {
      protocolVersion: 1,
      transport: "acpmux-websocket",
      endpoint: "ws://127.0.0.1:1/",
      token: "test",
      sessionId: raceFixture.parent,
    },
    (snapshot) => {
      if (snapshot.connection === "connected") connected();
    },
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          requests.push(message);
          const result =
            message.method === "initialize"
              ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } }
              : message.method === "_acpmux/watch"
                ? { sessions: [session] }
                : message.method === "_acpmux/attach"
                  ? { session, lastSeq: 0, events: [], hasMore: false }
                  : message.method === "_acpmux/race/list"
                    ? { races: [raceFixture] }
                    : message.method.startsWith("_acpmux/race/")
                      ? raceFixture
                      : null;
          if (message.id !== undefined)
            queueMicrotask(() =>
              socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }),
            );
        },
        close() {},
      } as typeof socket;
      queueMicrotask(() => socket.onopen?.());
      return socket as unknown as WebSocket;
    },
  );
  try {
    await ready;
    const seen: RaceRecord[] = [];
    const remove = client.watchRaces((race) => seen.push(race));
    expect(await client.listRaces(raceFixture.parent)).toEqual([raceFixture]);
    expect(await client.getRace(raceFixture.parent, raceFixture.id)).toEqual(raceFixture);
    const start = client.startRace({
      parent: raceFixture.parent,
      prompt: "task",
      candidates: raceFixture.candidates.map((c) => c.target),
      reviewer: { harness: "claude", model: "opus" },
    });
    // A write sends during the click, before yielding, preserving native gesture authorization.
    expect(requests.at(-1)?.method).toBe("_acpmux/race/start");
    await start;
    await client.cancelRace(raceFixture.parent, raceFixture.id);
    expect(requests.find((r) => r.method === "_acpmux/race/get")?.params).toEqual({
      parent: raceFixture.parent,
      raceId: raceFixture.id,
    });
    expect(requests.find((r) => r.method === "_acpmux/race/start")?.params.parent).toBe(raceFixture.parent);
    const emit = (seq: number) =>
      socket.onmessage?.({
        data: JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/event",
          params: {
            sessionId: raceFixture.parent,
            seq,
            at: raceFixture.updatedAt,
            dir: "mux",
            kind: "race",
            msg: raceFixture,
          },
        }),
      });
    emit(1);
    expect(seen).toEqual([raceFixture]);
    remove();
    emit(2);
    expect(seen).toHaveLength(1);
  } finally {
    client.close();
  }
});
