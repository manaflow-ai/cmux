import { describe, expect, it } from "bun:test";
import {
  decideConnect,
  forwardMessage,
  isValidMacDeviceId,
  MAX_RELAY_FRAME_BYTES,
  type MprAttachment,
  type MprSocket,
} from "../src/mobilePairingRelay";

class FakeSocket implements MprSocket {
  sent: (string | ArrayBuffer)[] = [];
  closed: { code?: number; reason?: string } | null = null;
  private attachment: MprAttachment | null = null;

  send(data: string | ArrayBuffer): void {
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closed = { code, reason };
  }

  getAttachment(): MprAttachment | null {
    return this.attachment;
  }

  setAttachment(attachment: MprAttachment): void {
    this.attachment = attachment;
  }
}

function attached(role: "host" | "client", accountId: string): FakeSocket {
  const socket = new FakeSocket();
  socket.setAttachment({ role, accountId });
  return socket;
}

describe("isValidMacDeviceId", () => {
  it("accepts a UUID-shaped device id", () => {
    expect(isValidMacDeviceId("11111111-2222-4333-8444-555555555555")).toBe(true);
  });

  it("rejects a path-separator-carrying id", () => {
    expect(isValidMacDeviceId("../etc/passwd")).toBe(false);
  });

  it("rejects an empty or oversized id", () => {
    expect(isValidMacDeviceId("")).toBe(false);
    expect(isValidMacDeviceId("a".repeat(129))).toBe(false);
  });
});

describe("decideConnect", () => {
  it("accepts the first host with no peer connected", () => {
    const decision = decideConnect([], "host", "user-1");
    expect(decision.ok).toBe(true);
    expect(decision.toEvict).toEqual([]);
  });

  it("evicts an existing same-role socket instead of stacking it", () => {
    const stale = attached("host", "user-1");
    const decision = decideConnect([stale], "host", "user-1");
    expect(decision.ok).toBe(true);
    expect(decision.toEvict).toEqual([stale]);
  });

  it("accepts a client whose account matches the connected host", () => {
    const host = attached("host", "user-1");
    const decision = decideConnect([host], "client", "user-1");
    expect(decision.ok).toBe(true);
    expect(decision.toEvict).toEqual([]);
  });

  it("rejects a client whose account does not match the connected host", () => {
    const host = attached("host", "user-1");
    const decision = decideConnect([host], "client", "user-2");
    expect(decision.ok).toBe(false);
    expect(decision.toEvict).toEqual([]);
  });

  it("ignores sockets with no attachment yet", () => {
    const unattached = new FakeSocket();
    const decision = decideConnect([unattached], "host", "user-1");
    expect(decision.ok).toBe(true);
    expect(decision.toEvict).toEqual([]);
  });
});

describe("forwardMessage", () => {
  it("relays a binary frame from host to client", () => {
    const host = attached("host", "user-1");
    const client = attached("client", "user-1");
    const frame = new TextEncoder().encode("frame-bytes").buffer;
    forwardMessage([host, client], host, frame);
    expect(client.sent).toEqual([frame]);
  });

  it("relays a binary frame from client to host", () => {
    const host = attached("host", "user-1");
    const client = attached("client", "user-1");
    const frame = new TextEncoder().encode("frame-bytes").buffer;
    forwardMessage([host, client], client, frame);
    expect(host.sent).toEqual([frame]);
  });

  it("drops a binary frame when no peer is connected yet", () => {
    const host = attached("host", "user-1");
    const frame = new TextEncoder().encode("frame-bytes").buffer;
    expect(() => forwardMessage([host], host, frame)).not.toThrow();
  });

  it("never forwards to a same-role or different-account socket", () => {
    const host = attached("host", "user-1");
    const otherHost = attached("host", "user-1");
    const wrongAccountClient = attached("client", "user-2");
    const frame = new TextEncoder().encode("frame-bytes").buffer;
    forwardMessage([host, otherHost, wrongAccountClient], host, frame);
    expect(otherHost.sent).toEqual([]);
    expect(wrongAccountClient.sent).toEqual([]);
  });

  it("closes the sender instead of forwarding an oversized frame", () => {
    const host = attached("host", "user-1");
    const client = attached("client", "user-1");
    const oversized = new ArrayBuffer(MAX_RELAY_FRAME_BYTES + 1);
    forwardMessage([host, client], host, oversized);
    expect(client.sent).toEqual([]);
    expect(host.closed).toEqual({ code: 1009, reason: "frame too large" });
  });

  it("answers a ping heartbeat directly without forwarding it", () => {
    const host = attached("host", "user-1");
    const client = attached("client", "user-1");
    forwardMessage([host, client], host, JSON.stringify({ type: "ping" }));
    expect(host.sent).toEqual([JSON.stringify({ type: "pong" })]);
    expect(client.sent).toEqual([]);
  });

  it("ignores a message from an unattached sender", () => {
    const sender = new FakeSocket();
    const frame = new TextEncoder().encode("frame-bytes").buffer;
    expect(() => forwardMessage([sender], sender, frame)).not.toThrow();
    expect(sender.sent).toEqual([]);
  });
});
