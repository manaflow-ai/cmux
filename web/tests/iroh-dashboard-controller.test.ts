import { afterEach, describe, expect, test } from "bun:test";
import { V2DashboardController } from "../app/[locale]/dashboard/iroh/v2-dashboard-controller";

const originalFetch = globalThis.fetch;
const originalSocket = globalThis.WebSocket;

class FakeSocket {
  static instances: FakeSocket[] = [];
  static OPEN = 1;
  readonly OPEN = 1;
  readyState = 0;
  onopen: (() => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: ((event: CloseEvent) => void) | null = null;
  sent: string[] = [];
  protocols: string | string[];
  constructor(_url: string, protocols: string | string[]) { this.protocols = protocols; FakeSocket.instances.push(this); }
  send(body: string) { this.sent.push(body); }
  close() { this.readyState = 3; this.onclose?.({ code: 1000 } as CloseEvent); }
  open() { this.readyState = 1; this.onopen?.(); this.message({ schemaId: "dashboard.connected.v1", requestId: "connected", sessionId: "s", teamRevision: 1, expiresAt: 99 }); }
  message(value: unknown) { this.onmessage?.({ data: JSON.stringify(value) } as MessageEvent); }
}

describe("IROH Dashboard v2 controller", () => {
  afterEach(() => { globalThis.fetch = originalFetch; globalThis.WebSocket = originalSocket; FakeSocket.instances = []; });

  test("uses Stack bearer only to open a session and keeps ticket out of the URL", async () => {
    const calls: Request[] = [];
    globalThis.fetch = (async (input, init) => { calls.push(new Request(input, init)); return Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "body.signature", expiresAt: 3600, refreshAfter: 3300 } }); }) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "stack-token", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start();
    await new Promise(resolve => setTimeout(resolve, 0));
    const socket = FakeSocket.instances[0];
    expect(calls[0]?.headers.get("authorization")).toBe("Bearer stack-token");
    expect(calls[0]?.url).toBe("https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev/v2/dashboard/session");
    expect(socket?.protocols).toEqual(["cmux-v2-dashboard", "ticket.body.signature"]);
    socket?.open();
    await pending;
    expect(socket?.sent.some(body => body.includes("directory.request.v1"))).toBe(true);
    await controller.stop();
  });

  test("acknowledges delivery receipts without opening another request", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start(); await new Promise(resolve => setTimeout(resolve, 0));
    const socket = FakeSocket.instances[0]!; socket.open();
    socket.message({ schemaId: "directory.changed.v1", teamId: "t", revision: 1, deliveryReceipt: { sequence: 7, token: "receipt" } });
    const acknowledgement = JSON.parse(socket.sent.find(body => body.includes("session.ack.v1"))!);
    expect(acknowledgement).toMatchObject({ schemaId: "session.ack.v1", sequence: 7, token: "receipt" });
    await pending; await controller.stop();
  });

  test("applies directory frames and sends a revoke mutation", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const directories: unknown[] = [];
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: value => directories.push(value), onError: () => {} });
    const pending = controller.start(); await new Promise(resolve => setTimeout(resolve, 0));
    const socket = FakeSocket.instances[0]!; socket.open();
    await new Promise(resolve => setTimeout(resolve, 0));
    const directoryRequest = JSON.parse(socket.sent[0]!);
    socket.message({ schemaId: "dashboard.directory.v1", requestId: directoryRequest.requestId, directory: { teamId: "t", revision: 1, devices: [], relayURLs: [], issuedAt: 1, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await pending; expect(directories).toHaveLength(1);
    const revoke = controller.revoke("device");
    const revokeRequest = JSON.parse(socket.sent[1]!);
    socket.message({ schemaId: "operation.completed.v1", requestId: revokeRequest.requestId, revision: 2 });
    await new Promise(resolve => setTimeout(resolve, 0));
    // The post-mutation directory request is sent after the acknowledgement.
    const refresh = JSON.parse(socket.sent[2]!);
    socket.message({ schemaId: "dashboard.directory.v1", requestId: refresh.requestId, directory: { teamId: "t", revision: 2, devices: [], relayURLs: [], issuedAt: 2, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await revoke; await controller.stop();
  });

  test("uses the cursor for paged directories and sends expected revision for settings", async () => {
    globalThis.fetch = (async () => Response.json({ schemaId: "dashboard.ready.v1", requestId: "r", ticket: { token: "t.s", expiresAt: 3600, refreshAfter: 3300 } })) as typeof fetch;
    globalThis.WebSocket = FakeSocket as unknown as typeof WebSocket;
    const controller = new V2DashboardController({ origin: "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev", environment: "staging", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} });
    const pending = controller.start(); await new Promise(resolve => setTimeout(resolve, 0));
    const socket = FakeSocket.instances[0]!; socket.open();
    await new Promise(resolve => setTimeout(resolve, 0));
    const first = JSON.parse(socket.sent[0]!);
    socket.message({ schemaId: "dashboard.directory.v1", requestId: first.requestId, directory: { teamId: "t", revision: 4, devices: [], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: "cursor-1", canManageTeam: true, managedDeviceIds: [] } });
    await new Promise(resolve => setTimeout(resolve, 0));
    const second = JSON.parse(socket.sent[1]!);
    expect(second.cursor).toBe("cursor-1");
    socket.message({ schemaId: "dashboard.directory.v1", requestId: second.requestId, directory: { teamId: "t", revision: 4, devices: [], relayURLs: ["https://relay.example"], issuedAt: 1, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await pending;
    const update = controller.updateRelayPreferences(["https://relay.example"]);
    const updateRequest = JSON.parse(socket.sent[2]!);
    expect(updateRequest.expectedRevision).toBe(4);
    socket.message({ schemaId: "operation.completed.v1", requestId: updateRequest.requestId, revision: 5 });
    await new Promise(resolve => setTimeout(resolve, 0));
    const refresh = JSON.parse(socket.sent[3]!);
    socket.message({ schemaId: "dashboard.directory.v1", requestId: refresh.requestId, directory: { teamId: "t", revision: 5, devices: [], relayURLs: ["https://relay.example"], issuedAt: 2, nextCursor: null, canManageTeam: true, managedDeviceIds: [] } });
    await update; await controller.stop();
  });

  test("rejects an unapproved worker origin before creating a socket", () => {
    expect(() => new V2DashboardController({ origin: "https://example.com", environment: "production", projectId: "p", userId: "u", teamId: "t", getStackToken: async () => "s", onDirectory: () => {}, onError: () => {} })).toThrow("approved Cloudflare Worker");
  });
});
