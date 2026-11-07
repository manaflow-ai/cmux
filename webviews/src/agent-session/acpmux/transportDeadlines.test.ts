import { afterEach, expect, test } from "bun:test";

const fixture = globalThis as {
  cmuxAcpmuxMockSlowMethod?: string;
  cmuxAcpmuxMockSlowMs?: number;
};

/** The mock's delay for the slow method: only this one is held; every other mock delay is instant. */
const SLOW_MS = 600;

afterEach(() => {
  delete fixture.cmuxAcpmuxMockSlowMethod;
  delete fixture.cmuxAcpmuxMockSlowMs;
});

test("a slow but open daemon answers after the request progress threshold", async () => {
  const { AcpmuxDirectClient } = await import("./direct");
  const { MockAcpmuxSocket, mockHost } = await import("./mock");
  fixture.cmuxAcpmuxMockSlowMethod = "_acpmux/process/kill";
  fixture.cmuxAcpmuxMockSlowMs = SLOW_MS;
  // The daemon's reply waits until the test releases it, so it arrives after the request's
  // deadline on any machine, however slow, with no wall-clock wait.
  let releaseReply = () => {};
  const replyHeld = new Promise<void>((resolve) => {
    releaseReply = resolve;
  });
  const socket = new MockAcpmuxSocket((ms) => (ms === SLOW_MS ? replyHeld : Promise.resolve()));
  let sawWaiting = () => {};
  const waiting = new Promise<void>((resolve) => {
    sawWaiting = resolve;
  });
  let latest: { daemonWaitingSince?: number } | undefined;
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      latest = snapshot;
      if (snapshot.daemonWaitingSince !== undefined) sawWaiting();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const request = (
      client as unknown as {
        request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
      }
    ).request(
      "_acpmux/process/kill",
      { sessionId: mockHost.sessionId, processId: `${mockHost.sessionId}/process` },
      20,
    );
    // The 20 ms deadline passes while the reply is held. On an open socket it is a progress
    // threshold: the pane shows the daemon is waiting, and the request stays pending. A deadline
    // that fails the request settles it here instead, and the test fails with that error.
    await Promise.race([
      waiting,
      request.then(() => {
        throw new Error("the request settled before the daemon replied");
      }),
    ]);
    releaseReply();
    await expect(request).resolves.toEqual({});
    // The reply clears the waiting state.
    expect(latest?.daemonWaitingSince).toBeUndefined();
  } finally {
    releaseReply();
    client.close();
  }
});
