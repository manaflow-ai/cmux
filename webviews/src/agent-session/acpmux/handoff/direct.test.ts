import { expect, test } from "bun:test";
import { AcpmuxDirectClient } from "../direct";
import { MockAcpmuxSocket, mockHost } from "../mock";
import type { AcpmuxSnapshot } from "../model";
import { HANDOFF_OPS } from "./protocol";
class RecordingSocket extends MockAcpmuxSocket {
  calls: { method: string; params: any }[] = [];
  override send(raw: string) {
    this.calls.push(JSON.parse(raw));
    super.send(raw);
  }
}
const connect = async (socket = new RecordingSocket(() => Promise.resolve())) => {
  (globalThis as any).window ??= globalThis;
  const snapshots: AcpmuxSnapshot[] = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (s) => snapshots.push(s),
    undefined,
    () => socket as unknown as WebSocket,
  );
  return { client, socket, current: () => snapshots.at(-1)! };
};
test("Claude to Codex and back require review, preserve cwd and leave source intact", async () => {
  const { client, socket, current } = await connect();
  try {
    await client.create("claude");
    await client.send("Fix the dirty repository, retaining the user edits.");
    const sourceId = current().sessionId;
    const cwd = current().summary?.cwd;
    const sourceRows = current().rows;
    socket.calls.length = 0;
    await client.continueIn("codex");
    const record = current().handoff!.record!;
    expect(record.source.sessionId).toBe(sourceId!);
    expect(current().summary?.cwd).toBe(cwd);
    expect(current().summary?.harness).toBe("codex");
    expect(current().rows).toHaveLength(0);
    expect(socket.calls.some((call) => call.method === "session/prompt")).toBe(false);
    await expect(client.send("bypass review")).rejects.toThrow("Review");
    const review = {
      capsule: "Reviewed task and preserved edits",
      checkpoint: { reference: "backup-1", confirmed: true },
      approvedMemoryReferences: ["project/rules"],
    };
    await client.startHandoff(review);
    expect(current().handoff?.record?.state).toBe("started");
    expect(socket.calls.filter((call) => call.method === HANDOFF_OPS.start)).toHaveLength(1);
    await client.select(sourceId!);
    expect(current().rows).toEqual(sourceRows);
    await client.select(record.target.sessionId);
    await client.continueIn("claude");
    expect(current().summary?.cwd).toBe(cwd);
    expect(current().summary?.harness).toBe("claude");
    expect(current().handoff?.record?.source.harness).toBe("codex");
    const unusedTarget = current().sessionId;
    const returned = await client.discardHandoff();
    expect(returned).toBe(record.target.sessionId);
    expect(current().sessions.some((s) => s.sessionId === unusedTarget)).toBe(false);
    expect(current().sessions.some((s) => s.sessionId === sourceId)).toBe(true);
  } finally {
    client.close();
  }
});
class UnsupportedSocket extends RecordingSocket {
  override send(raw: string) {
    const call = JSON.parse(raw);
    if (call.method === "initialize") {
      this.calls.push(call);
      return (this as any).deliver({ id: call.id, result: { protocolVersion: 1 } });
    }
    super.send(raw);
  }
}
test("unsupported daemons are never asked for handoffs", async () => {
  const { client, socket, current } = await connect(new UnsupportedSocket(() => Promise.resolve()));
  try {
    await client.create("claude");
    expect(current().canHandoff).toBe(false);
    await client.continueIn("codex");
    expect(socket.calls.some((call) => call.method.startsWith("_acpmux/handoff_"))).toBe(false);
  } finally {
    client.close();
  }
});
