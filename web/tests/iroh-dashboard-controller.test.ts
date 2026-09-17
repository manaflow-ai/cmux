import { afterEach, describe, expect, test } from "bun:test";
import { V2DashboardController, type DashboardDirectory } from "../app/[locale]/dashboard/iroh/v2-dashboard-controller";

const originalFetch = globalThis.fetch;
const originalSocket = globalThis.WebSocket;

class FakeSocket {
  static instances: FakeSocket[] = [];
  static OPEN = 1;
  static created = new Map<number, (socket: FakeSocket) => void>();
  static waitFor(index: number): Promise<FakeSocket> {
    return FakeSocket.instances[index] ? Promise.resolve(FakeSocket.instances[index]!) : new Promise(resolve => FakeSocket.created.set(index, resolve));
  }
  readonly OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  sent: string[] = [];
  protocols: string | string[];
  private sentWaiters = new Map<number, (body: string) => void>();
  constructor(_url: string, protocols: string | string[]) { this.protocols = protocols; FakeSocket.instances.push(this); FakeSocket.created.get(FakeSocket.instances.length - 1)?.(this); }
  send(body: string) {
    const index = this.sent.push(body) - 1;
    this.sentWaiters.get(index)?.(body);
    this.sentWaiters.delete(index);
  }
  waitForSent(index: number): Promise<string> {
    return this.sent[index] !== undefined ? Promise.resolve(this.sent[index]!) : new Promise(resolve => this.sentWaiters.set(index, resolve));
  }
  close() { this.readyState = 3; this.onclose?.({ code: 1000 } as CloseEvent); }
  open() { this.readyState = 1; this.onopen?.(); this.message({ schemaId: "dashboard.connected.v1", requestId: "connected", sessionId: "s", teamRevision: 1, expiresAt: 99 }); }
  message(value: unknown) { this.onmessage?.({ data: JSON.stringify(value) } as MessageEvent); }
}

class ManualClock {
  private time = 0;
  private timers = new Map<() => void | Promise<void>, number>();
  now = () => this.time;
  schedule = (delay: number, callback: () => void | Promise<void>) => {
    this.timers.set(callback, delay);
    return () => { this.timers.delete(callback); };
  };
  delays() { return [...this.timers.values()]; }
  async fire(delay: number) {
    const entry = [...this.timers.entries()].find(([, value]) => value === delay);
    if (!entry) throw new Error(`No timer scheduled for ${delay}ms`);
    this.timers.delete(entry[0]);
    this.time += delay;
    await entry[0]();
  }
}

describe("IROH Dashboard v2 controller", () => {
  afterEach(() => { globalThis.fetch = originalFetch; globalThis.WebSocket = originalSocket; FakeSocket.instances = []; FakeSocket.created.clear(); });

  test("uses Stack bearer only to open a session and keeps ticket out of the URL", async () => {
    const calls: Request[] = [];
    globalThis.fetch = (async (input, init) => { calls.push(new Request(input, init)); return Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "body.signature", expiresAt: 3600, refreshAfter: 3300 } }); }) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "stack-token", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitFor(0);
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
    const socket = await FakeSocket.waitFor(0); socket.open();
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
    const socket = await FakeSocket.waitFor(0); socket.open();
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
    const directories: DashboardDirectory[] = [];
    const received = Promise.withResolvers<void>();
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: value => { directories.push(value); received.resolve(); }, onError: () => {} });
    const pending = controller.start();
    const socket = await FakeSocket.waitFor(0); socket.open();
    const first = JSON.parse(await socket.waitForSent(0));
    socket.message({ schemaId: "dashboard.directory.v1", requestId: first.requestId, directory: { teamId: "t", revision: 4, devices: [{ deviceRecordId: "d1" }], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: "cursor-1", canManageTeam: true, managedDeviceIds: ["d1"] } });
    const second = JSON.parse(await socket.waitForSent(1));
    expect(second.cursor).toBe("cursor-1");
    socket.message({ schemaId: "dashboard.directory.v1", requestId: second.requestId, directory: { teamId: "t", revision: 4, devices: [{ deviceRecordId: "d2" }], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: null, canManageTeam: true, managedDeviceIds: ["d2"] } });
    await pending;
    await received.promise;
    expect(directories).toHaveLength(1);
    expect(directories[0].devices.map(device => device.deviceRecordId)).toEqual(["d1", "d2"]);
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
    expect(() => new V2DashboardController({ origin: "https://example.com", environment: "production", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} })).toThrow("approved Cloudflare Worker");
  });

  test("retries a failed initial socket and loads the directory", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const retryClock = new ManualClock();
    const received = Promise.withResolvers<void>();
    const controller = new V2DashboardController({ retryClock, origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => received.resolve(), onError: () => {} });
    try {
      const pending = controller.start();
      const initial = await FakeSocket.waitFor(0);
      initial.onerror?.();
      await pending;
      expect(retryClock.delays()).toEqual([1000]);
      const retry = retryClock.fire(1000);
      const replacement = await FakeSocket.waitFor(1);
      replacement.open();
      const request = JSON.parse(await replacement.waitForSent(0));
      replacement.message({ schemaId: "dashboard.directory.v1", requestId: request.requestId, directory: { teamId: "t", revision: 1, devices: [], relayURLs: [], issuedAt: 1, nextCursor: null, canManageTeam: false, managedDeviceIds: [] } });
      await received.promise;
      await retry;
      expect(FakeSocket.instances).toHaveLength(2);
    } finally { await controller.stop(); }
    expect(retryClock.delays()).toEqual([]);
  });

  test("refresh failures retry on the clock and cancellation removes the retry", async () => {
    const retryClock = new ManualClock();
    let attempts = 0;
    globalThis.fetch = (async () => {
      attempts += 1;
      if (attempts === 2 || attempts === 4) throw new Error("offline");
      return Response.json({ schemaId: "dashboard.ready.v1", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 30 } });
    }) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ retryClock, origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} });
    try {
      const pending = controller.start();
      const initial = await FakeSocket.waitFor(0);
      initial.open();
      await pending;
      expect(retryClock.delays()).toEqual([30_000]);
      await retryClock.fire(30_000);
      expect(attempts).toBe(2);
      expect(initial.readyState).toBe(FakeSocket.OPEN);
      expect(retryClock.delays()).toEqual([60_000]);
      const retry = retryClock.fire(60_000);
      const replacement = await FakeSocket.waitFor(1);
      replacement.open();
      await retry;
      expect(initial.readyState).toBe(3);
      expect(retryClock.delays()).toEqual([10_000]);
      await retryClock.fire(10_000);
      expect(retryClock.delays()).toEqual([60_000]);
    } finally { await controller.stop(); }
    expect(retryClock.delays()).toEqual([]);
    expect(attempts).toBe(4);
  });

  test("stopping while authentication is pending never opens a stale team socket", async () => {
    let resolveToken!: (value: string) => void;
    const token = new Promise<string>(resolve => { resolveToken = resolve; });
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.debussy.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "old-team", getStackToken: () => token, onDirectory: () => {}, onError: () => {} });
    const pending = controller.start();
    await controller.stop();
    resolveToken("s");
    await pending;
    await controller.stop();
    expect(FakeSocket.instances).toHaveLength(0);
  });
});
