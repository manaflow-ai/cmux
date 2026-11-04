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
  fixture.cmuxAcpmuxMockSlowMs = 600;
  const socket = new MockAcpmuxSocket(() => Promise.resolve());
  const client = await AcpmuxDirectClient.connect(
    mockHost,
    () => undefined,
    undefined,
    () => socket as unknown as WebSocket,
  );
  try {
    const started = performance.now();
    const request = (client as unknown as {
      request(method: string, params: Record<string, unknown>, deadline: number): Promise<unknown>;
    }).request("_acpmux/process/kill", { sessionId: mockHost.sessionId, processId: `${mockHost.sessionId}/process` }, 20);
    // The client holds the first attach snapshot briefly; observe after that hold while the
    // deliberately slow reply is still outstanding.
    await wait(350);
    await expect(request).resolves.toEqual({});
    expect(performance.now() - started).toBeGreaterThan(20);
  } finally {
    client.close();
  }
});
