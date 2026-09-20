import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { V2DashboardController } from "../app/[locale]/dashboard/mobile-devices/v2-dashboard-controller";

const originalFetch = globalThis.fetch;
const originalSocket = globalThis.WebSocket;

class FakeSocket {
  static instances: FakeSocket[] = [];
  static OPEN = 1;
  static created: ((socket: FakeSocket) => void) | undefined;
  private sentWaiters = new Map<number, (body: string) => void>();
  static waitForInstance(): Promise<FakeSocket> {
    return FakeSocket.instances[0]
      ? Promise.resolve(FakeSocket.instances[0])
      : new Promise(resolve => { FakeSocket.created = resolve; });
  }
  waitForSent(index: number): Promise<string> {
    return this.sent[index] !== undefined
      ? Promise.resolve(this.sent[index])
      : new Promise(resolve => { this.sentWaiters.set(index, resolve); });
  }
  readonly OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  sent: string[] = [];
  protocols: string | string[];
  constructor(_url: string, protocols: string | string[]) { this.protocols = protocols; FakeSocket.instances.push(this); FakeSocket.created?.(this); }
  send(body: string) {
    const index = this.sent.push(body) - 1;
    this.sentWaiters.get(index)?.(body);
    this.sentWaiters.delete(index);
  }
  close() { this.readyState = 3; this.onclose?.({ code: 1000 } as CloseEvent); }
  open() { this.readyState = 1; this.onopen?.(); this.message({ schemaId: "dashboard.connected.v1", requestId: "connected", sessionId: "s", teamRevision: 1, expiresAt: 99 }); }
  message(value: unknown) { this.onmessage?.({ data: JSON.stringify(value) } as MessageEvent); }
}

describe("Mobile devices controller", () => {
  afterEach(() => { globalThis.fetch = originalFetch; globalThis.WebSocket = originalSocket; FakeSocket.instances = []; FakeSocket.created = undefined; });

  test("uses Stack bearer only to open a session and keeps ticket out of the URL", async () => {
    const calls: Request[] = [];
    globalThis.fetch = (async (input, init) => { calls.push(new Request(input, init)); return Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "body.signature", expiresAt: 3600, refreshAfter: 3300 } }); }) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "stack-token", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitForInstance();
    expect(calls[0]?.headers.get("authorization")).toBe("Bearer stack-token");
    expect(calls[0]?.url).toBe("https://cmux-iroh-v2-staging.debussy.workers.dev/v2/dashboard/session");
    expect(socket?.protocols).toEqual(["cmux-v2-dashboard", "ticket.body.signature"]);
    socket?.open();
    await pending;
    expect(socket?.sent.some(body => body.includes("directory.request.v1"))).toBe(true);
    await controller.stop();
  });

  test("acknowledges delivery receipts without opening another request", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitForInstance(); socket.open();
    socket.message({ schemaId: "directory.changed.v1", teamId: "t", revision: 1, deliveryReceipt: { sequence: 7, token: "receipt" } });
    const acknowledgement = JSON.parse(socket.sent.find(body => body.includes("session.ack.v1"))!);
    expect(acknowledgement).toMatchObject({ schemaId: "session.ack.v1", sequence: 7, token: "receipt" });
    await pending; await controller.stop();
  });

  test("applies directory frames and sends a revoke mutation", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const directories: unknown[] = [];
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: value => directories.push(value), onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitForInstance(); socket.open();
    const directoryRequest = JSON.parse(await socket.waitForSent(0));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: directoryRequest.requestId, directory: { teamId: "t", revision: 1, devices: [], relayURLs: [], issuedAt: 1, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await pending; expect(directories).toHaveLength(1);
    const revoke = controller.revoke("device");
    const revokeRequest = JSON.parse(await socket.waitForSent(1));
    socket.message({ schemaId: "operation.completed.v1", requestId: revokeRequest.requestId, revision: 2 });
    // The post-mutation directory request is sent after the acknowledgement.
    const refresh = JSON.parse(await socket.waitForSent(2));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: refresh.requestId, directory: { teamId: "t", revision: 2, devices: [], relayURLs: [], issuedAt: 2, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await revoke; await controller.stop();
  });

  test("uses the cursor for paged directories and sends expected revision for settings", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const directories: any[] = [];
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: value => directories.push(value), onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitForInstance(); socket.open();
    const first = JSON.parse(await socket.waitForSent(0));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: first.requestId, directory: { teamId: "t", revision: 4, devices: [{ deviceRecordId: "d1" }], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: "cursor-1", canManageTeam: true, managedDeviceIds: ["d1"] } });
    const second = JSON.parse(await socket.waitForSent(1));
    expect(second.cursor).toBe("cursor-1");
    socket.message({ schemaId: "dashboard.directory.v1", requestId: second.requestId, directory: { teamId: "t", revision: 4, devices: [{ deviceRecordId: "d2" }], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: null, canManageTeam: true, managedDeviceIds: ["d2"] } });
    await pending;
    expect(directories).toHaveLength(1);
    expect(directories[0].devices.map((device: any) => device.deviceRecordId)).toEqual(["d1", "d2"]);
    expect(directories[0].managedDeviceIds).toEqual(["d1", "d2"]);
    const update = controller.updateRelayPreferences(["https://relay.example"]);
    const updateRequest = JSON.parse(await socket.waitForSent(2));
    expect(updateRequest.expectedRevision).toBe(4);
    socket.message({ schemaId: "operation.completed.v1", requestId: updateRequest.requestId, revision: 5 });
    const refresh = JSON.parse(await socket.waitForSent(3));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: refresh.requestId, directory: { teamId: "t", revision: 5, devices: [], relayURLs: ["https://relay.example"], issuedAt: 2, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await update; await controller.stop();
  });

  test("rejects an unapproved worker origin before creating a socket", () => {
    expect(() => new V2DashboardController({ origin: "https://example.com", environment: "production", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} })).toThrow("approved device service");
  });
});

test("stopping during session issuance never opens a stale socket", async () => {
  let finishSession!: (response: Response) => void;
  const original = globalThis.fetch;
  const originalWS = globalThis.WebSocket;
  globalThis.fetch = (() => new Promise<Response>(resolve => { finishSession = resolve; })) as typeof fetch;
  globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
  FakeSocket.instances = [];
  const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => { throw new Error("stopped controller reported an error"); } });
  try {
    const started = controller.start();
    await Promise.resolve();
    await controller.stop();
    finishSession(Response.json({ schemaId: "dashboard.ready.v1", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } }));
    await started;
    expect(FakeSocket.instances).toHaveLength(0);
  } finally { await controller.stop(); globalThis.fetch = original; globalThis.WebSocket = originalWS; FakeSocket.instances = []; }
});

test("a failed initial socket retries and receives a device directory", async () => {
  const original = globalThis.fetch;
  const originalWS = globalThis.WebSocket;
  FakeSocket.instances = [];
  let opened = 0;
  globalThis.fetch = (async () => { opened++; return Response.json({ schemaId: "dashboard.ready.v1", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } }); }) as typeof fetch;
  globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
  const directories: unknown[] = [], errors: string[] = [];
  const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: value => directories.push(value), onError: value => errors.push(value) });
  try {
    const started = controller.start();
    const first = await FakeSocket.waitForInstance();
    first.onerror?.();
    await started;
    expect(errors).toEqual(["Dashboard socket failed"]);
    const replacement = new Promise<FakeSocket>(resolve => { FakeSocket.created = resolve; });
    const socket = await replacement;
    socket.open();
    const request = JSON.parse(await socket.waitForSent(0));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: request.requestId, directory: { teamId: "t", revision: 1, devices: [], relayURLs: [], issuedAt: 1, nextCursor: null, canManageTeam: false, managedDeviceIds: [] } });
    await Promise.resolve();
    expect(opened).toBe(2);
    expect(directories).toHaveLength(1);
  } finally { await controller.stop(); globalThis.fetch = original; globalThis.WebSocket = originalWS; FakeSocket.instances = []; FakeSocket.created = undefined; }
});

test("permanent authorization failures do not schedule another session", async () => {
  const original = globalThis.fetch;
  const timers = spyOn(globalThis, "setTimeout");
  let requests = 0;
  const errors: string[] = [];
  globalThis.fetch = (async () => { requests++; return Response.json({ schemaId: "error.v1", code: "team_access_revoked", retryable: false }, { status: 403 }); }) as typeof fetch;
  const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: value => errors.push(value) });
  try {
    await controller.start();
    expect(timers).not.toHaveBeenCalled();
    expect(requests).toBe(1);
    expect(errors).toEqual(["Team access was removed"]);
  } finally { await controller.stop(); globalThis.fetch = original; timers.mockRestore(); }
});
