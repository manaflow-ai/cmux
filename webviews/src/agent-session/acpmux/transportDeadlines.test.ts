import { afterEach, expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "./model";

const fixture = globalThis as {
  cmuxAcpmuxMockSlowMethod?: string;
  cmuxAcpmuxMockSlowMs?: number;
};

afterEach(() => {
  delete fixture.cmuxAcpmuxMockSlowMethod;
  delete fixture.cmuxAcpmuxMockSlowMs;
});

test("a slow but open daemon answers after the request progress threshold", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  const SLOW_MS = 600;
  fixture.cmuxAcpmuxMockSlowMethod = "_acpmux/process/kill";
  fixture.cmuxAcpmuxMockSlowMs = SLOW_MS;
  // The slow reply goes only when the test releases it; every other mock delay resolves at once.
  let release!: () => void;
  const slowReply = new Promise<void>((resolve) => (release = resolve));
  const socket = new MockAcpmuxSocket((ms) => (ms === SLOW_MS ? slowReply : Promise.resolve()));
  let sawWaiting!: () => void;
  const waiting = new Promise<void>((resolve) => (sawWaiting = resolve));
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot: AcpmuxSnapshot) => {
      if (snapshot.daemonWaitingSince !== undefined) sawWaiting();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    let settled = false;
    const request = (
      client as unknown as {
        request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
      }
    )
      .request("_acpmux/process/kill", { sessionId: mockHost.sessionId, processId: `${mockHost.sessionId}/process` }, 20)
      .finally(() => (settled = true));
    // The 20 ms threshold passes with the reply still held: the pane is told the daemon is slow,
    // and the request stays pending instead of failing as timed out.
    await waiting;
    expect(settled).toBe(false);
    release();
    await expect(request).resolves.toEqual({});
  } finally {
    client.close();
  }
});
