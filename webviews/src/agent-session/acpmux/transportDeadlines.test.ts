import { afterEach, expect, test } from "bun:test";

const fixture = globalThis as {
  cmuxAcpmuxMockSlowMethod?: string;
  cmuxAcpmuxMockSlowMs?: number;
};

const wait = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

afterEach(() => {
  delete fixture.cmuxAcpmuxMockSlowMethod;
  delete fixture.cmuxAcpmuxMockSlowMs;
});

test("a slow but open daemon answers after the request progress threshold", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  fixture.cmuxAcpmuxMockSlowMethod = "_acpmux/process/kill";
  fixture.cmuxAcpmuxMockSlowMs = 200;
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const snapshots: Array<{ daemonWaitingSince?: number }> = [];
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => snapshots.push(snapshot as { daemonWaitingSince?: number }),
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const request = (client as unknown as {
      request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
    }).request("_acpmux/process/kill", { sessionId: mockHost.sessionId, processId: `${mockHost.sessionId}/process` }, 20);
    await wait(80);
    expect(snapshots.some((snapshot) => snapshot.daemonWaitingSince !== undefined)).toBe(true);
    await expect(request).resolves.toEqual({});
  } finally {
    client.close();
  }
});
