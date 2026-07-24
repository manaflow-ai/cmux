// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  canReserveDeliveryCredit,
  createSocketAttachment,
  DELIVERY_FAILURE_CLOSE_CODE,
  DELIVERY_FAILURE_CLOSE_REASON,
  deliveryCreditBytes,
  dispatchEffects,
  MAX_SOCKET_OUTSTANDING_BYTES,
  MAX_SOCKET_OUTSTANDING_ENTRIES,
  MAX_NONCE_GENERATION_ATTEMPTS,
  outstandingDeliveryBytes,
  parseSocketAttachment,
  releaseDeliveryCredit,
  serializeSocketAttachment,
  SERVER_MESSAGE_TOO_LARGE_CLOSE_CODE,
  SERVER_MESSAGE_TOO_LARGE_CLOSE_REASON,
  type OutboundEffectRuntime,
  type OutboundSocket,
  type ShareSocketAttachment,
  SLOW_CLIENT_CLOSE_CODE,
  SLOW_CLIENT_CLOSE_REASON,
} from "../src/outbound";
import {
  BINARY_KIND_GRID,
  encodeBinaryHeader,
  MAX_BINARY_FRAME_BYTES,
  MAX_SERVER_JSON_FRAME_BYTES,
  PROTO_VERSION,
  utf8ByteLength,
} from "../src/protocol";
import type { Effect, PersistedSession } from "../src/session";
import { MAX_GRANTS_PER_SESSION, ShareSessionCore } from "../src/session";

const T0 = 1_700_000_000_000;
const HOST = { user: "u-host", email: "host@cmux.com", hostToken: true };
const SLOW = { user: "u-slow", email: "slow@example.com", hostToken: false };
const HEALTHY = { user: "u-healthy", email: "healthy@example.com", hostToken: false };
const encoder = new TextEncoder();

function uuid(index: number): string {
  return `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`;
}

type Failure = "serialize" | "payload-send" | "ack-send" | null;

class FakeSocket implements OutboundSocket {
  readonly sent: Array<string | ArrayBuffer | ArrayBufferView> = [];
  readonly sendAttempts: Array<string | ArrayBuffer | ArrayBufferView> = [];
  readonly serialized: unknown[] = [];
  readonly closes: Array<{ code?: number; reason?: string }> = [];

  constructor(private readonly failure: Failure = null) {}

  serializeAttachment(value: unknown): void {
    if (this.failure === "serialize") throw new Error("serialize failed");
    this.serialized.push(structuredClone(value));
  }

  send(data: string | ArrayBuffer | ArrayBufferView): void {
    this.sendAttempts.push(data);
    if (this.failure === "payload-send" && this.sendAttempts.length === 1) {
      throw new Error("payload failed");
    }
    if (this.failure === "ack-send" && this.sendAttempts.length === 2) {
      throw new Error("ack failed");
    }
    this.sent.push(data);
  }

  close(code?: number, reason?: string): void {
    this.closes.push({ code, reason });
  }
}

interface Harness {
  runtime: OutboundEffectRuntime<FakeSocket>;
  logs: Array<{ event: string; details: Readonly<Record<string, number | string>> }>;
  storageDeletes: { count: number };
}

function harness(
  core: ShareSessionCore | null,
  sockets: Map<string, FakeSocket>,
  attachments: Map<string, ShareSocketAttachment>,
): Harness {
  let nonceIndex = 1;
  const logs: Harness["logs"] = [];
  const storageDeletes = { count: 0 };
  return {
    runtime: {
      core,
      sockets,
      attachments,
      now: () => T0,
      randomUUID: () => uuid(nonceIndex++),
      persist: async (_session: PersistedSession) => {},
      setAlarm: async (_at: number) => {},
      clearAlarm: async () => {},
      deleteAllStorage: async () => {
        storageDeletes.count += 1;
      },
      removeSocketState: (_id: string) => {},
      logInvariant: (event, details) => logs.push({ event, details }),
    },
    logs,
    storageDeletes,
  };
}

function attachment(id: string, user = id): ShareSocketAttachment {
  return createSocketAttachment({
    connId: id,
    user,
    email: `${user}@example.com`,
    host: id === "c-host",
  });
}

function bootedCore(): ShareSessionCore {
  const core = new ShareSessionCore(
    ShareSessionCore.create("code123", { user: HOST.user, email: HOST.email }, T0),
  );
  core.connect("c-host", HOST, T0);
  core.handleHost("c-host", {
    t: "hello",
    proto: PROTO_VERSION,
    shared: [{ id: "workspace:1", title: "main" }],
    layouts: [
      {
        ws: "workspace:1",
        tree: { kind: "pane", pane: "surface:1", content: "terminal", cols: 80, rows: 24 },
      },
    ],
  });
  for (const [id, identity] of [
    ["c-slow", SLOW],
    ["c-healthy", HEALTHY],
  ] as const) {
    core.connect(id, identity, T0);
    core.handleHost("c-host", { t: "approve", user: identity.user, role: "editor" });
    core.handleGuest(id, { t: "sub", ws: "workspace:1", pane: "surface:1" });
  }
  return core;
}

function errorEffect(to: string, message: string): Effect {
  return { kind: "send", to, msg: { t: "error", code: "test", message } };
}

function exactJsonMessage(targetBytes: number): string {
  const empty = JSON.stringify({ t: "error", code: "test", message: "" });
  const fixedBytes = utf8ByteLength(empty);
  if (targetBytes < fixedBytes) throw new Error("target too small");
  return "x".repeat(targetBytes - fixedBytes);
}

function ackNonceFrom(socket: FakeSocket, from = 0): string {
  for (let index = from; index < socket.sent.length; index += 1) {
    const value = socket.sent[index];
    if (typeof value !== "string") continue;
    const parsed = JSON.parse(value) as { t?: string; nonce?: string };
    if (parsed.t === "ack-request" && typeof parsed.nonce === "string") return parsed.nonce;
  }
  throw new Error("missing ack request");
}

describe("serialized delivery credit", () => {
  it("round-trips a compact worst-case 128-entry attachment below 16 KiB", () => {
    const source = createSocketAttachment({
      connId: "c".repeat(256),
      user: "u".repeat(256),
      email: `${"e".repeat(308)}@example.com`,
      host: false,
    });
    source.outstanding = Array.from({ length: MAX_SOCKET_OUTSTANDING_ENTRIES }, (_, index) => ({
      nonce: uuid(index),
      bytes: 1,
    }));
    const serialized = serializeSocketAttachment(source);
    expect(utf8ByteLength(JSON.stringify(serialized))).toBeLessThan(16_384);
    expect(parseSocketAttachment(structuredClone(serialized))).toEqual(source);

    const overEntries = {
      ...serialized,
      w: [...serialized.w, [uuid(129), 1] as [string, number]],
    };
    expect(parseSocketAttachment(overEntries)).toBeNull();
  });

  it("accepts prospective bytes at 2 MiB - 1 and rejects exactly 2 MiB", () => {
    const nonce = uuid(1);
    const charge = deliveryCreditBytes(1, nonce);
    const accepted = attachment("accepted");
    accepted.outstanding = [{ nonce: uuid(2), bytes: MAX_SOCKET_OUTSTANDING_BYTES - charge - 1 }];
    const rejected = attachment("rejected");
    rejected.outstanding = [{ nonce: uuid(2), bytes: MAX_SOCKET_OUTSTANDING_BYTES - charge }];

    expect(canReserveDeliveryCredit(accepted, charge)).toBe(true);
    expect(canReserveDeliveryCredit(rejected, charge)).toBe(false);
  });

  it("accepts entry 128 from a 127-entry window and closes on prospective entry 129", async () => {
    const socket = new FakeSocket();
    const credit = attachment("socket");
    credit.outstanding = Array.from({ length: 127 }, (_, index) => ({
      nonce: uuid(index + 10),
      bytes: 1,
    }));
    const sockets = new Map([["socket", socket]]);
    const attachments = new Map([["socket", credit]]);
    const { runtime } = harness(null, sockets, attachments);

    await dispatchEffects([errorEffect("socket", "entry 128")], runtime);
    expect(credit.outstanding).toHaveLength(128);
    expect(socket.sent).toHaveLength(2);

    await dispatchEffects([errorEffect("socket", "entry 129")], runtime);
    expect(socket.sent).toHaveLength(2);
    expect(socket.closes).toEqual([
      { code: SLOW_CLIENT_CLOSE_CODE, reason: SLOW_CLIENT_CLOSE_REASON },
    ]);
    expect(sockets.has("socket")).toBe(false);
    expect(attachments.has("socket")).toBe(false);
  });

  it("frees credit only for the exact same-socket nonce", async () => {
    const firstSocket = new FakeSocket();
    const secondSocket = new FakeSocket();
    const first = attachment("first");
    const second = attachment("second");
    const sockets = new Map([
      ["first", firstSocket],
      ["second", secondSocket],
    ]);
    const attachments = new Map([
      ["first", first],
      ["second", second],
    ]);
    const { runtime } = harness(null, sockets, attachments);
    await dispatchEffects(
      [errorEffect("first", "one"), errorEffect("second", "two")],
      runtime,
    );

    const firstNonce = first.outstanding[0]?.nonce;
    const secondNonce = second.outstanding[0]?.nonce;
    if (!firstNonce || !secondNonce) throw new Error("missing credit");
    const firstBytes = outstandingDeliveryBytes(first);
    const secondBytes = outstandingDeliveryBytes(second);

    expect(releaseDeliveryCredit(secondSocket, second, firstNonce)).toBe("ignored");
    expect(outstandingDeliveryBytes(second)).toBe(secondBytes);
    expect(releaseDeliveryCredit(firstSocket, first, "unknown")).toBe("ignored");
    expect(outstandingDeliveryBytes(first)).toBe(firstBytes);
    expect(releaseDeliveryCredit(firstSocket, first, firstNonce)).toBe("released");
    expect(outstandingDeliveryBytes(first)).toBe(0);
    expect(releaseDeliveryCredit(firstSocket, first, firstNonce)).toBe("ignored");
    expect(outstandingDeliveryBytes(first)).toBe(0);
    expect(releaseDeliveryCredit(secondSocket, second, secondNonce)).toBe("released");
  });

  it("restores a full attachment and releases a pre-wake nonce afterward", () => {
    const before = attachment("socket");
    before.outstanding = Array.from({ length: 128 }, (_, index) => ({
      nonce: uuid(index),
      bytes: index + 1,
    }));
    const afterWake = parseSocketAttachment(
      structuredClone(serializeSocketAttachment(before)),
    );
    if (!afterWake) throw new Error("failed to restore attachment");
    const socket = new FakeSocket();

    expect(releaseDeliveryCredit(socket, afterWake, uuid(64))).toBe("released");
    expect(afterWake.outstanding).toHaveLength(127);
    const persisted = parseSocketAttachment(socket.serialized.at(-1));
    expect(persisted?.outstanding).toHaveLength(127);
    expect(persisted?.outstanding.some((entry) => entry.nonce === uuid(64))).toBe(false);
  });

  it("retries a nonce collision and fails closed after bounded repeated collisions", async () => {
    const colliding = uuid(1);

    const retrySocket = new FakeSocket();
    const retryCredit = attachment("retry");
    retryCredit.outstanding = [{ nonce: colliding, bytes: 1 }];
    const retryHarness = harness(
      null,
      new Map([["retry", retrySocket]]),
      new Map([["retry", retryCredit]]),
    );
    const candidates = [colliding, uuid(2)];
    retryHarness.runtime.randomUUID = () => candidates.shift() ?? uuid(3);
    await dispatchEffects([errorEffect("retry", "retry")], retryHarness.runtime);
    expect(retryCredit.outstanding.map((entry) => entry.nonce)).toEqual([
      colliding,
      uuid(2),
    ]);
    expect(retrySocket.sent).toHaveLength(2);

    const failedSocket = new FakeSocket();
    const failedCredit = attachment("failed");
    failedCredit.outstanding = [{ nonce: colliding, bytes: 1 }];
    let attempts = 0;
    const failedHarness = harness(
      null,
      new Map([["failed", failedSocket]]),
      new Map([["failed", failedCredit]]),
    );
    failedHarness.runtime.randomUUID = () => {
      attempts += 1;
      return colliding;
    };
    await dispatchEffects([errorEffect("failed", "must not send")], failedHarness.runtime);
    expect(attempts).toBe(MAX_NONCE_GENERATION_ATTEMPTS);
    expect(failedSocket.serialized).toEqual([]);
    expect(failedSocket.sendAttempts).toEqual([]);
    expect(failedSocket.closes).toEqual([
      { code: DELIVERY_FAILURE_CLOSE_CODE, reason: DELIVERY_FAILURE_CLOSE_REASON },
    ]);
    expect(failedHarness.logs.map((entry) => entry.event)).toContain(
      "delivery_nonce_collision",
    );
  });

  it("releases a waking ACK before restore messages reserve new credit", async () => {
    const withheld = uuid(99);
    const socket = new FakeSocket();
    const credit = attachment("socket");
    credit.outstanding = [
      { nonce: withheld, bytes: MAX_SOCKET_OUTSTANDING_BYTES - 1 },
    ];
    const sockets = new Map([["socket", socket]]);
    const attachments = new Map([["socket", credit]]);
    const { runtime } = harness(null, sockets, attachments);

    expect(canReserveDeliveryCredit(credit, deliveryCreditBytes(1, uuid(1)))).toBe(false);
    expect(releaseDeliveryCredit(socket, credit, withheld)).toBe("released");
    await dispatchEffects(
      [
        errorEffect("socket", "restored snapshot"),
        { kind: "send", to: "socket", msg: { t: "resync" } },
      ],
      runtime,
    );

    expect(socket.closes).toEqual([]);
    expect(socket.sent).toHaveLength(4);
    expect(
      socket.sent
        .filter((message): message is string => typeof message === "string")
        .map((message) => JSON.parse(message) as Record<string, unknown>)
        .some((message) => message.t === "resync"),
    ).toBe(true);
    expect(credit.outstanding).toHaveLength(2);
  });
});

describe("failure-safe delivery ordering", () => {
  it("dispatches a tombstone cleanup as one all-storage deletion", async () => {
    const { runtime, storageDeletes } = harness(null, new Map(), new Map());
    await dispatchEffects([{ kind: "deleteAllStorage" }], runtime);
    expect(storageDeletes.count).toBe(1);
  });

  for (const [failure, expectedAttempts, expectedSent, event] of [
    ["serialize", 0, 0, "delivery_attachment_serialize_failed"],
    ["payload-send", 1, 0, "delivery_payload_send_failed"],
    ["ack-send", 2, 1, "delivery_ack_request_send_failed"],
  ] as const) {
    it(`closes and disconnects after ${failure} without continuing untracked`, async () => {
      const socket = new FakeSocket(failure);
      const sockets = new Map([["socket", socket]]);
      const attachments = new Map([["socket", attachment("socket")]]);
      const { runtime, logs } = harness(null, sockets, attachments);

      await dispatchEffects([errorEffect("socket", "secret payload")], runtime);

      expect(socket.sendAttempts).toHaveLength(expectedAttempts);
      expect(socket.sent).toHaveLength(expectedSent);
      expect(socket.closes).toEqual([
        { code: DELIVERY_FAILURE_CLOSE_CODE, reason: DELIVERY_FAILURE_CLOSE_REASON },
      ]);
      expect(sockets.has("socket")).toBe(false);
      expect(attachments.has("socket")).toBe(false);
      expect(logs.map((entry) => entry.event)).toContain(event);
      expect(JSON.stringify(logs)).not.toContain("secret payload");
    });
  }

  it("persists reservation before payload, then sends payload before ACK request", async () => {
    const socket = new FakeSocket();
    const credit = attachment("socket");
    const sockets = new Map([["socket", socket]]);
    const attachments = new Map([["socket", credit]]);
    const { runtime } = harness(null, sockets, attachments);
    await dispatchEffects([errorEffect("socket", "ordered")], runtime);

    expect(socket.serialized).toHaveLength(1);
    expect(socket.sent).toHaveLength(2);
    expect(JSON.parse(socket.sent[0] as string)).toEqual({
      t: "error",
      code: "test",
      message: "ordered",
    });
    expect(JSON.parse(socket.sent[1] as string)).toEqual({
      t: "ack-request",
      nonce: credit.outstanding[0]?.nonce,
    });
  });
});

describe("outbound JSON and combined credit bounds", () => {
  it("sends 1 MiB - 1 JSON and closes only the target at 1 MiB", async () => {
    const acceptedSocket = new FakeSocket();
    const rejectedSocket = new FakeSocket();
    const healthySocket = new FakeSocket();
    const sockets = new Map([
      ["accepted", acceptedSocket],
      ["rejected", rejectedSocket],
      ["healthy", healthySocket],
    ]);
    const attachments = new Map([
      ["accepted", attachment("accepted")],
      ["rejected", attachment("rejected")],
      ["healthy", attachment("healthy")],
    ]);
    const { runtime, logs } = harness(null, sockets, attachments);

    await dispatchEffects(
      [
        errorEffect("accepted", exactJsonMessage(MAX_SERVER_JSON_FRAME_BYTES - 1)),
        errorEffect("rejected", exactJsonMessage(MAX_SERVER_JSON_FRAME_BYTES)),
        errorEffect("healthy", "still healthy"),
      ],
      runtime,
    );

    expect(utf8ByteLength(acceptedSocket.sent[0] as string)).toBe(
      MAX_SERVER_JSON_FRAME_BYTES - 1,
    );
    expect(acceptedSocket.closes).toEqual([]);
    expect(rejectedSocket.sendAttempts).toEqual([]);
    expect(rejectedSocket.serialized).toEqual([]);
    expect(rejectedSocket.closes).toEqual([
      {
        code: SERVER_MESSAGE_TOO_LARGE_CLOSE_CODE,
        reason: SERVER_MESSAGE_TOO_LARGE_CLOSE_REASON,
      },
    ]);
    expect(healthySocket.sent).toHaveLength(2);
    expect(sockets.has("accepted")).toBe(true);
    expect(sockets.has("healthy")).toBe(true);
    expect(logs).toContainEqual({
      event: "server_json_too_large",
      details: { bytes: MAX_SERVER_JSON_FRAME_BYTES },
    });
    expect(JSON.stringify(logs)).not.toContain("xxxxxxxx");
  });

  it("accounts for payload, exact ACK request, and both frame allowances", async () => {
    const nonce = uuid(1);
    const payload = new Uint8Array([42]);
    const charge = deliveryCreditBytes(payload.byteLength, nonce);

    const acceptedSocket = new FakeSocket();
    const rejectedSocket = new FakeSocket();
    const acceptedCredit = attachment("accepted");
    acceptedCredit.outstanding = [
      { nonce: uuid(100), bytes: MAX_SOCKET_OUTSTANDING_BYTES - charge - 1 },
    ];
    const rejectedCredit = attachment("rejected");
    rejectedCredit.outstanding = [
      { nonce: uuid(101), bytes: MAX_SOCKET_OUTSTANDING_BYTES - charge },
    ];
    const sockets = new Map([
      ["accepted", acceptedSocket],
      ["rejected", rejectedSocket],
    ]);
    const attachments = new Map([
      ["accepted", acceptedCredit],
      ["rejected", rejectedCredit],
    ]);
    const { runtime } = harness(null, sockets, attachments);
    await dispatchEffects(
      [
        { kind: "sendBinary", to: "accepted", data: payload },
        { kind: "sendBinary", to: "rejected", data: payload },
      ],
      runtime,
    );

    expect(acceptedSocket.sent).toHaveLength(2);
    expect(outstandingDeliveryBytes(acceptedCredit)).toBe(
      MAX_SOCKET_OUTSTANDING_BYTES - 1,
    );
    expect(rejectedSocket.sent).toEqual([]);
    expect(rejectedSocket.closes).toEqual([
      { code: SLOW_CLIENT_CLOSE_CODE, reason: SLOW_CLIENT_CLOSE_REASON },
    ]);
  });

  it("sends binary at 1 MiB - 1 and closes only exact/over targets with redacted logs", async () => {
    const acceptedSocket = new FakeSocket();
    const exactSocket = new FakeSocket();
    const overSocket = new FakeSocket();
    const healthySocket = new FakeSocket();
    const sockets = new Map([
      ["accepted", acceptedSocket],
      ["exact", exactSocket],
      ["over", overSocket],
      ["healthy", healthySocket],
    ]);
    const attachments = new Map(
      [...sockets.keys()].map((id) => [id, attachment(id)] as const),
    );
    const { runtime, logs } = harness(null, sockets, attachments);
    await dispatchEffects(
      [
        {
          kind: "sendBinary",
          to: "accepted",
          data: new Uint8Array(MAX_BINARY_FRAME_BYTES - 1),
        },
        {
          kind: "sendBinary",
          to: "exact",
          data: new Uint8Array(MAX_BINARY_FRAME_BYTES),
        },
        {
          kind: "sendBinary",
          to: "over",
          data: new Uint8Array(MAX_BINARY_FRAME_BYTES + 1),
        },
        errorEffect("healthy", "unrelated healthy target"),
      ],
      runtime,
    );

    expect((acceptedSocket.sent[0] as Uint8Array).byteLength).toBe(
      MAX_BINARY_FRAME_BYTES - 1,
    );
    for (const socket of [exactSocket, overSocket]) {
      expect(socket.serialized).toEqual([]);
      expect(socket.sendAttempts).toEqual([]);
      expect(socket.closes).toEqual([
        {
          code: SERVER_MESSAGE_TOO_LARGE_CLOSE_CODE,
          reason: SERVER_MESSAGE_TOO_LARGE_CLOSE_REASON,
        },
      ]);
    }
    expect(healthySocket.sent).toHaveLength(2);
    expect(logs).toContainEqual({
      event: "server_binary_too_large",
      details: { bytes: MAX_BINARY_FRAME_BYTES },
    });
    expect(logs).toContainEqual({
      event: "server_binary_too_large",
      details: { bytes: MAX_BINARY_FRAME_BYTES + 1 },
    });
    expect(JSON.stringify(logs)).not.toContain("unrelated healthy target");
  });
});

describe("slow-client isolation", () => {
  it("fans out a real 1 MiB - 1 grid frame and releases its exact ACK credit", async () => {
    const core = bootedCore();
    const fixedHeaderBytes =
      3 + encoder.encode("workspace:1").byteLength + encoder.encode("surface:1").byteLength;
    const frame = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "workspace:1",
      "surface:1",
      new Uint8Array(MAX_BINARY_FRAME_BYTES - fixedHeaderBytes - 1),
    );
    expect(frame.byteLength).toBe(MAX_BINARY_FRAME_BYTES - 1);
    const guestSocket = new FakeSocket();
    const guestCredit = attachment("c-healthy", HEALTHY.user);
    const sockets = new Map([["c-healthy", guestSocket]]);
    const attachments = new Map([["c-healthy", guestCredit]]);
    const { runtime } = harness(core, sockets, attachments);

    await dispatchEffects(
      core.routeBinary("c-host", "workspace:1", "surface:1", frame, BINARY_KIND_GRID),
      runtime,
    );

    expect(guestSocket.sent[0]).toEqual(frame);
    expect(guestCredit.outstanding).toHaveLength(1);
    const reserved = outstandingDeliveryBytes(guestCredit);
    const nonce = ackNonceFrom(guestSocket);
    expect(reserved).toBe(deliveryCreditBytes(frame.byteLength, nonce));
    expect(releaseDeliveryCredit(guestSocket, guestCredit, nonce)).toBe("released");
    expect(outstandingDeliveryBytes(guestCredit)).toBe(0);
  });

  it("orders a maximum-participant snapshot before a near-limit healthy grid", async () => {
    const persisted = ShareSessionCore.create(
      "code-max",
      { user: HOST.user, email: HOST.email },
      T0,
    );
    persisted.shared = [{ id: "workspace:1", title: "t".repeat(512) }];
    persisted.layouts = [
      {
        ws: "workspace:1",
        tree: {
          kind: "pane",
          pane: "surface:1",
          content: "terminal",
          cols: 10_000,
          rows: 10_000,
          title: "t".repeat(512),
        },
      },
    ];
    persisted.grants = Array.from({ length: MAX_GRANTS_PER_SESSION }, (_, index) => ({
      user: `u-${index.toString().padStart(3, "0")}-${"u".repeat(248)}`,
      email: `e-${index.toString().padStart(3, "0")}-${"e".repeat(312)}`,
      role: "editor" as const,
      color: index % 8,
    }));
    persisted.chat = Array.from({ length: 50 }, (_, index) => ({
      id: `chat-${index}`,
      user: HOST.user,
      text: `${index}:${"x".repeat(3_900)}`,
      ts: T0 + index,
    }));
    const target = persisted.grants[0]!;
    const core = new ShareSessionCore(persisted);
    core.connect("c-host", HOST, T0);
    const connectEffects = core.connect(
      "c-target",
      { user: target.user, email: target.email, hostToken: false },
      T0,
    );
    core.handleGuest(
      "c-target",
      { t: "sub", ws: "workspace:1", pane: "surface:1" },
      T0,
    );
    const fixedHeaderBytes =
      3 + encoder.encode("workspace:1").byteLength + encoder.encode("surface:1").byteLength;
    const frame = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "workspace:1",
      "surface:1",
      new Uint8Array(MAX_BINARY_FRAME_BYTES - fixedHeaderBytes - 1),
    );
    const snapshotEffect = connectEffects.find(
      (effect): effect is Extract<Effect, { kind: "send" }> =>
        effect.kind === "send" &&
        effect.to === "c-target" &&
        effect.msg.t === "session-state",
    );
    if (!snapshotEffect || snapshotEffect.msg.t !== "session-state") {
      throw new Error("missing maximum-participant snapshot");
    }
    expect(snapshotEffect.msg.participants).toHaveLength(MAX_GRANTS_PER_SESSION + 1);
    const binaryEffect = core.routeBinary(
      "c-host",
      "workspace:1",
      "surface:1",
      frame,
      BINARY_KIND_GRID,
    )[0];
    if (!binaryEffect || binaryEffect.kind !== "sendBinary") {
      throw new Error("missing near-limit grid fan-out");
    }

    const socket = new FakeSocket();
    const credit = attachment("c-target", target.user);
    const sockets = new Map([["c-target", socket]]);
    const attachments = new Map([["c-target", credit]]);
    const { runtime } = harness(core, sockets, attachments);
    await dispatchEffects([snapshotEffect, binaryEffect], runtime);

    expect(JSON.parse(socket.sent[0] as string)).toHaveProperty("t", "session-state");
    expect(JSON.parse(socket.sent[1] as string)).toHaveProperty("t", "ack-request");
    expect(socket.sent[2]).toEqual(frame);
    expect(JSON.parse(socket.sent[3] as string)).toHaveProperty("t", "ack-request");
    const firstNonce = ackNonceFrom(socket, 0);
    const secondNonce = ackNonceFrom(socket, 2);
    expect(releaseDeliveryCredit(socket, credit, firstNonce)).toBe("released");
    expect(releaseDeliveryCredit(socket, credit, secondNonce)).toBe("released");
    expect(outstandingDeliveryBytes(credit)).toBe(0);
    expect(socket.closes).toEqual([]);
  });

  it("disconnects one saturated guest, updates sub count, and keeps healthy fan-out", async () => {
    const core = bootedCore();
    const frame = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "workspace:1",
      "surface:1",
      encoder.encode('{"format":"cmux.render-grid.v1"}'),
    );
    const host = new FakeSocket();
    const slow = new FakeSocket();
    const healthy = new FakeSocket();
    const slowCredit = attachment("c-slow", SLOW.user);
    slowCredit.outstanding = Array.from({ length: 128 }, (_, index) => ({
      nonce: uuid(index + 20),
      bytes: 1,
    }));
    const sockets = new Map([
      ["c-host", host],
      ["c-slow", slow],
      ["c-healthy", healthy],
    ]);
    const attachments = new Map([
      ["c-host", attachment("c-host", HOST.user)],
      ["c-slow", slowCredit],
      ["c-healthy", attachment("c-healthy", HEALTHY.user)],
    ]);
    const { runtime } = harness(core, sockets, attachments);

    await dispatchEffects(
      core.routeBinary("c-host", "workspace:1", "surface:1", frame, BINARY_KIND_GRID),
      runtime,
    );

    expect(slow.sent).toEqual([]);
    expect(slow.closes).toEqual([
      { code: SLOW_CLIENT_CLOSE_CODE, reason: SLOW_CLIENT_CLOSE_REASON },
    ]);
    expect(healthy.sent[0]).toEqual(frame);
    expect(
      host.sent
        .filter((message): message is string => typeof message === "string")
        .map((message) => JSON.parse(message) as Record<string, unknown>),
    ).toContainEqual({
      t: "guest-sub",
      ws: "workspace:1",
      pane: "surface:1",
      count: 1,
    });
    expect(sockets.has("c-slow")).toBe(false);
    expect(sockets.has("c-healthy")).toBe(true);
  });

  it("plateaus a non-ACKing socket while each healthy turn remains deliverable", async () => {
    const slow = new FakeSocket();
    const healthy = new FakeSocket();
    const slowCredit = attachment("slow");
    const healthyCredit = attachment("healthy");
    const sockets = new Map([
      ["slow", slow],
      ["healthy", healthy],
    ]);
    const attachments = new Map([
      ["slow", slowCredit],
      ["healthy", healthyCredit],
    ]);
    const { runtime } = harness(null, sockets, attachments);

    for (let index = 0; index < 129; index += 1) {
      const before = healthy.sent.length;
      await dispatchEffects(
        [
          errorEffect("slow", `slow-${index}`),
          errorEffect("healthy", `healthy-${index}`),
        ],
        runtime,
      );
      expect(healthy.sent.length).toBe(before + 2);
      const nonce = ackNonceFrom(healthy, before);
      expect(releaseDeliveryCredit(healthy, healthyCredit, nonce)).toBe("released");
      expect(healthyCredit.outstanding).toHaveLength(0);
    }

    expect(slow.sent).toHaveLength(128 * 2);
    expect(slow.closes).toEqual([
      { code: SLOW_CLIENT_CLOSE_CODE, reason: SLOW_CLIENT_CLOSE_REASON },
    ]);
    expect(sockets.has("slow")).toBe(false);
    expect(sockets.has("healthy")).toBe(true);
    expect(healthy.sent).toHaveLength(129 * 2);
  });
});
