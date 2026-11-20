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

test("a slow but open daemon answers after the request progress threshold, and the pane never says it waits on the service", async () => {
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
  let saidWaiting = false;
  let latest: { daemonWaitingSince?: number } | undefined;
  // The request crossing its threshold emits a snapshot ("waiting: daemon"); this resolves on it.
  let client: Awaited<ReturnType<typeof AcpmuxDirectClient.connect>> | undefined;
  let sawCrossing = () => {};
  const crossed = new Promise<void>((resolve) => {
    sawCrossing = resolve;
  });
  const waitingRequests = () => (client as unknown as { waitingRequests?: number } | undefined)?.waitingRequests ?? 0;
  const connected = await AcpmuxDirectClient.connect(
    mockHost,
    (snapshot) => {
      latest = snapshot;
      if (snapshot.daemonWaitingSince !== undefined) saidWaiting = true;
      if (waitingRequests() > 0) sawCrossing();
    },
    undefined,
    () => socket as unknown as WebSocket,
  );
  client = connected;
  try {
    const request = (
      connected as unknown as {
        request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
      }
    ).request(
      "_acpmux/process/kill",
      { sessionId: mockHost.sessionId, processId: `${mockHost.sessionId}/process` },
      20,
    );
    // The 20 ms deadline passes while the reply is held. On an open socket it is a progress
    // threshold: the request stays pending, and a deadline that failed it would settle it here.
    // The daemon owes no answer yet (no probe is out), so the pane does not say it waits on the
    // service: a long chat that is slow to read is not a service that is down.
    await Promise.race([
      crossed,
      request.then(() => {
        throw new Error("the request settled before the daemon replied");
      }),
    ]);
    expect(saidWaiting).toBe(false);
    releaseReply();
    await expect(request).resolves.toEqual({});
    expect(latest?.daemonWaitingSince).toBeUndefined();
    expect(saidWaiting).toBe(false);
  } finally {
    releaseReply();
    connected.close();
  }
});
