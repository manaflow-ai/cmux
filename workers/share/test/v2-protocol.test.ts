// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import { validateBinaryIngress } from "../src/ingress";
import {
  createSocketAttachment,
  dispatchEffects,
  parseSocketAttachment,
  releaseDeliveryCredit,
  type OutboundEffectRuntime,
  type OutboundSocket,
} from "../src/outbound";
import {
  decodeTerminalFrame as decodeWorkerTerminalFrame,
  MAX_BINARY_FRAME_BYTES,
  parseGuestMessage,
  PROTO_VERSION,
} from "../src/protocol";
import type { ServerMessage } from "../src/protocol";
import {
  INPUT_RATE_LIMIT_PER_ROOM,
  INPUT_RATE_LIMIT_PER_SOCKET,
  RATE_LIMIT_CLOSE_CODE,
  RATE_LIMIT_CLOSE_REASON,
  ShareSessionCore,
} from "../src/session";
import type { Effect } from "../src/session";

const T0 = 1_700_000_000_000;
const PROTOCOL_V2 = 2;
const TERMINAL_TRANSPORT_VERSION = 1;
const BINARY_KIND_BASELINE = 1;
const BINARY_KIND_OUTPUT = 2;
const BINARY_KIND_INPUT = 3;
const BINARY_KIND_FORWARDED_INPUT = 4;
const TERMINAL_HEADER_BYTES = 56;
const TERMINAL_RESYNC_PER_SOCKET = 2;
const TERMINAL_RESYNC_PER_ROOM = 8;
const RATE_WINDOW_MS = 1_000;
const ZERO_EPOCH = "00000000-0000-0000-0000-000000000000";
const EPOCH = "11111111-2222-4333-8444-555555555555";
const WS = "workspace:1";
const PANE = "surface:1";
const INVALID_FRAME_REASON = "invalid terminal frame";
const DISALLOWED_FRAME_REASON = "terminal frame kind not allowed";

const HOST = { user: "u-host", email: "host@cmux.com", hostToken: true };
const ALICE = { user: "u-alice", email: "alice@example.com", hostToken: false };
const BOB = { user: "u-bob", email: "bob@example.com", hostToken: false };
const CAROL = { user: "u-carol", email: "carol@example.com", hostToken: false };
const PENDING = { user: "u-pending", email: "pending@example.com", hostToken: false };

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

interface TerminalFrame {
  version: number;
  kind: number;
  flags: number;
  epoch: string;
  sequenceStart: bigint;
  sequenceEnd: bigint;
  rows: number;
  columns: number;
  ws: string;
  pane: string;
  user: string;
  payload: Uint8Array;
}

function uuidBytes(uuid: string): Uint8Array {
  const hex = uuid.replaceAll("-", "");
  if (!/^[0-9a-f]{32}$/i.test(hex)) throw new Error("invalid test UUID");
  return Uint8Array.from(
    Array.from({ length: 16 }, (_, index) =>
      Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16),
    ),
  );
}

function uuidString(bytes: Uint8Array): string {
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

function encodeTerminalFrame(frame: TerminalFrame): Uint8Array {
  const ws = encoder.encode(frame.ws);
  const pane = encoder.encode(frame.pane);
  const user = encoder.encode(frame.user);
  if (ws.length > 0xffff || pane.length > 0xffff || user.length > 0xffff) {
    throw new Error("test frame identifier too large");
  }
  const out = new Uint8Array(
    TERMINAL_HEADER_BYTES + ws.length + pane.length + user.length + frame.payload.length,
  );
  const view = new DataView(out.buffer);
  out.set(encoder.encode("CMXS"), 0);
  view.setUint8(4, frame.version);
  view.setUint8(5, frame.kind);
  view.setUint16(6, frame.flags, false);
  out.set(uuidBytes(frame.epoch), 8);
  view.setBigUint64(24, frame.sequenceStart, false);
  view.setBigUint64(32, frame.sequenceEnd, false);
  view.setUint16(40, frame.rows, false);
  view.setUint16(42, frame.columns, false);
  view.setUint16(44, ws.length, false);
  view.setUint16(46, pane.length, false);
  view.setUint16(48, user.length, false);
  view.setUint16(50, 0, false);
  view.setUint32(52, frame.payload.length, false);
  let offset = TERMINAL_HEADER_BYTES;
  out.set(ws, offset);
  offset += ws.length;
  out.set(pane, offset);
  offset += pane.length;
  out.set(user, offset);
  offset += user.length;
  out.set(frame.payload, offset);
  return out;
}

function decodeTerminalFrame(bytes: Uint8Array): TerminalFrame | null {
  if (bytes.length < TERMINAL_HEADER_BYTES) return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  try {
    if (decoder.decode(bytes.subarray(0, 4)) !== "CMXS") return null;
    const wsLength = view.getUint16(44, false);
    const paneLength = view.getUint16(46, false);
    const userLength = view.getUint16(48, false);
    const payloadLength = view.getUint32(52, false);
    let offset = TERMINAL_HEADER_BYTES;
    const wsEnd = offset + wsLength;
    const paneEnd = wsEnd + paneLength;
    const userEnd = paneEnd + userLength;
    const payloadEnd = userEnd + payloadLength;
    if (payloadEnd !== bytes.length) return null;
    const ws = decoder.decode(bytes.subarray(offset, wsEnd));
    offset = wsEnd;
    const pane = decoder.decode(bytes.subarray(offset, paneEnd));
    offset = paneEnd;
    const user = decoder.decode(bytes.subarray(offset, userEnd));
    return {
      version: view.getUint8(4),
      kind: view.getUint8(5),
      flags: view.getUint16(6, false),
      epoch: uuidString(bytes.subarray(8, 24)),
      sequenceStart: view.getBigUint64(24, false),
      sequenceEnd: view.getBigUint64(32, false),
      rows: view.getUint16(40, false),
      columns: view.getUint16(42, false),
      ws,
      pane,
      user,
      payload: bytes.slice(userEnd, payloadEnd),
    };
  } catch {
    return null;
  }
}

function baselineFrame(payload = encoder.encode("\u001b[2J\u001b[Hready")): Uint8Array {
  return encodeTerminalFrame({
    version: TERMINAL_TRANSPORT_VERSION,
    kind: BINARY_KIND_BASELINE,
    flags: 0,
    epoch: EPOCH,
    sequenceStart: 42n,
    sequenceEnd: 42n,
    rows: 24,
    columns: 80,
    ws: WS,
    pane: PANE,
    user: "",
    payload,
  });
}

function outputFrame(payload = encoder.encode("next")): Uint8Array {
  return encodeTerminalFrame({
    version: TERMINAL_TRANSPORT_VERSION,
    kind: BINARY_KIND_OUTPUT,
    flags: 0,
    epoch: EPOCH,
    sequenceStart: 42n,
    sequenceEnd: 42n + BigInt(payload.length),
    rows: 0,
    columns: 0,
    ws: WS,
    pane: PANE,
    user: "",
    payload,
  });
}

function inputFrame(payload = encoder.encode("printf input\\n")): Uint8Array {
  return encodeTerminalFrame({
    version: TERMINAL_TRANSPORT_VERSION,
    kind: BINARY_KIND_INPUT,
    flags: 0,
    epoch: ZERO_EPOCH,
    sequenceStart: 0n,
    sequenceEnd: 0n,
    rows: 0,
    columns: 0,
    ws: WS,
    pane: PANE,
    user: "",
    payload,
  });
}

function newCore(): ShareSessionCore {
  return new ShareSessionCore(
    ShareSessionCore.create("code123", { user: HOST.user, email: HOST.email }, T0),
  );
}

function bootedCore(): ShareSessionCore {
  const core = newCore();
  core.connect("c-host", HOST, T0);
  core.handleHost(
    "c-host",
    {
      t: "hello",
      proto: PROTO_VERSION,
      shared: [{ id: WS, title: "main" }],
      layouts: [
        {
          ws: WS,
          tree: { kind: "pane", pane: PANE, content: "terminal", cols: 80, rows: 24 },
        },
      ],
    },
    T0,
  );
  return core;
}

function approveGuest(
  core: ShareSessionCore,
  id: string,
  identity: typeof ALICE,
  role: "editor" | "viewer",
): void {
  core.connect(id, identity, T0);
  core.handleHost("c-host", { t: "approve", user: identity.user, role }, T0);
}

function effects(value: Effect[] | undefined): Effect[] {
  return value ?? [];
}

function sends(all: Effect[], to?: string): ServerMessage[] {
  return all
    .filter((effect): effect is Extract<Effect, { kind: "send" }> => effect.kind === "send")
    .filter((effect) => to === undefined || effect.to === to)
    .map((effect) => effect.msg);
}

function binarySends(all: Effect[]): Array<{ to: string; data: Uint8Array }> {
  return all
    .filter(
      (effect): effect is Extract<Effect, { kind: "sendBinary" }> =>
        effect.kind === "sendBinary",
    )
    .map(({ to, data }) => ({ to, data }));
}

function closes(all: Effect[]): Array<{ to: string; code: number; reason: string }> {
  return all
    .filter((effect): effect is Extract<Effect, { kind: "close" }> => effect.kind === "close")
    .map(({ to, code, reason }) => ({ to, code, reason }));
}

function routeFrame(
  core: ShareSessionCore,
  from: string,
  frame: Uint8Array,
  now: number = T0,
): Effect[] {
  const decoded = decodeTerminalFrame(frame);
  if (!decoded) throw new Error("invalid test frame");
  const routeBinary = core.routeBinary as (
    fromId: string,
    ws: string,
    pane: string,
    data: Uint8Array,
    kind: number,
    receivedAt: number,
  ) => Effect[];
  return routeBinary.call(
    core,
    from,
    decoded.ws,
    decoded.pane,
    frame,
    decoded.kind,
    now,
  );
}

function terminalResync(
  core: ShareSessionCore,
  from: string,
  now: number,
  user = "u-forged",
): Effect[] {
  return effects(
    core.handleGuest(
      from,
      { t: "terminal-resync", user, ws: WS, pane: PANE } as never,
      now,
    ) as Effect[] | undefined,
  );
}

describe("protocol v2 negotiation", () => {
  it("uses JSON protocol 2 in snapshots", () => {
    expect(PROTO_VERSION).toBe(PROTOCOL_V2);
    const snapshot = sends(newCore().connect("c-host", HOST, T0), "c-host").find(
      (message) => message.t === "session-state",
    );
    expect(snapshot).toMatchObject({ t: "session-state", proto: PROTOCOL_V2 });
  });

  it("closes host and guest hello mismatches explicitly", () => {
    const hostCore = newCore();
    hostCore.connect("c-host", HOST, T0);
    expect(
      closes(
        hostCore.handleHost(
          "c-host",
          { t: "hello", proto: 1, shared: [], layouts: [] },
          T0,
        ),
      ),
    ).toEqual([{ to: "c-host", code: 4406, reason: "unsupported protocol" }]);

    const guestCore = newCore();
    guestCore.connect("c-alice", ALICE, T0);
    expect(
      closes(
        guestCore.handleGuest("c-alice", { t: "hello", proto: 1 }, T0),
      ),
    ).toEqual([{ to: "c-alice", code: 4406, reason: "unsupported protocol" }]);
  });
});

describe("terminal transport v1 framing", () => {
  it("decodes the fixed 56-byte baseline, output, and input headers", () => {
    for (const frame of [baselineFrame(), outputFrame(), inputFrame()]) {
      const expected = decodeTerminalFrame(frame);
      if (!expected) throw new Error("invalid test frame");
      expect(decodeWorkerTerminalFrame(frame)).toMatchObject({
        kind: expected.kind,
        ws: WS,
        pane: PANE,
        payloadOffset: TERMINAL_HEADER_BYTES + encoder.encode(WS).length + encoder.encode(PANE).length,
      });
    }
  });

  it("admits only host baseline/output and guest input", () => {
    for (const frame of [baselineFrame(), outputFrame()]) {
      const expected = decodeTerminalFrame(frame);
      if (!expected) throw new Error("invalid test frame");
      expect(validateBinaryIngress(true, frame)).toMatchObject({
        ok: true,
        header: { kind: expected.kind, ws: WS, pane: PANE },
      });
      expect(validateBinaryIngress(false, frame)).toEqual({
        ok: false,
        code: 4400,
        reason: DISALLOWED_FRAME_REASON,
      });
    }

    expect(validateBinaryIngress(false, inputFrame())).toMatchObject({
      ok: true,
      header: { kind: BINARY_KIND_INPUT, ws: WS, pane: PANE },
    });
    expect(validateBinaryIngress(true, inputFrame())).toEqual({
      ok: false,
      code: 4400,
      reason: DISALLOWED_FRAME_REASON,
    });
  });

  it("rejects unknown, malformed, and semantically invalid terminal frames", () => {
    const badPayloadLength = inputFrame().slice();
    const badPayloadView = new DataView(
      badPayloadLength.buffer,
      badPayloadLength.byteOffset,
      badPayloadLength.byteLength,
    );
    badPayloadView.setUint32(52, badPayloadView.getUint32(52, false) + 1, false);

    const invalidFrames = [
      new Uint8Array([0x43, 0x4d, 0x58]),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        version: 2,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        flags: 1,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(baselineFrame())!,
        epoch: ZERO_EPOCH,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(outputFrame())!,
        sequenceEnd: 43n,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        epoch: EPOCH,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        rows: 24,
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        user: "u-forged",
      }),
      encodeTerminalFrame({
        ...decodeTerminalFrame(inputFrame())!,
        kind: 0xff,
      }),
      badPayloadLength,
    ];

    for (const frame of invalidFrames) {
      expect(validateBinaryIngress(false, frame)).toEqual({
        ok: false,
        code: 4400,
        reason: INVALID_FRAME_REASON,
      });
    }

    expect(validateBinaryIngress(false, new Uint8Array(MAX_BINARY_FRAME_BYTES))).toEqual({
      ok: false,
      code: 1009,
      reason: "binary message too large",
    });
  });
});

describe("terminal binary authorization and routing", () => {
  it("routes host baseline/output only to active subscribers", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    approveGuest(core, "c-bob", BOB, "viewer");
    approveGuest(core, "c-carol", CAROL, "editor");
    core.connect("c-pending", PENDING, T0);
    core.handleGuest("c-alice", { t: "sub", ws: WS, pane: PANE }, T0);
    core.handleGuest("c-bob", { t: "sub", ws: WS, pane: PANE }, T0);
    core.handleGuest("c-pending", { t: "sub", ws: WS, pane: PANE }, T0);

    for (const frame of [baselineFrame(), outputFrame()]) {
      const routed = binarySends(routeFrame(core, "c-host", frame));
      expect(routed.map(({ to }) => to)).toEqual(["c-alice", "c-bob"]);
      expect(routed.every(({ data }) => data === frame)).toBe(true);
      for (const sender of ["c-alice", "c-bob", "c-carol", "c-pending", "c-unknown"]) {
        expect(routeFrame(core, sender, frame)).toEqual([]);
      }
    }
  });

  it("forwards active editor input to the host with verified identity injected", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    approveGuest(core, "c-bob", BOB, "viewer");
    approveGuest(core, "c-carol", CAROL, "editor");
    core.connect("c-pending", PENDING, T0);
    core.handleGuest("c-alice", { t: "sub", ws: WS, pane: PANE }, T0);
    core.handleGuest("c-bob", { t: "sub", ws: WS, pane: PANE }, T0);
    const input = inputFrame(encoder.encode("echo verified\n"));

    const forwarded = binarySends(routeFrame(core, "c-alice", input));
    expect(forwarded).toHaveLength(1);
    expect(forwarded[0]?.to).toBe("c-host");
    const decoded = decodeTerminalFrame(forwarded[0]?.data ?? new Uint8Array());
    expect(decoded).toMatchObject({
      version: TERMINAL_TRANSPORT_VERSION,
      kind: BINARY_KIND_FORWARDED_INPUT,
      flags: 0,
      epoch: ZERO_EPOCH,
      sequenceStart: 0n,
      sequenceEnd: 0n,
      rows: 0,
      columns: 0,
      ws: WS,
      pane: PANE,
      user: ALICE.user,
    });
    expect(decoded?.payload).toEqual(encoder.encode("echo verified\n"));

    for (const sender of [
      "c-host",
      "c-bob",
      "c-carol",
      "c-pending",
      "c-unknown",
    ]) {
      expect(routeFrame(core, sender, input)).toEqual([]);
    }
  });

  it("shares the 60/socket/s terminal-input budget with JSON input", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    core.handleGuest("c-alice", { t: "sub", ws: WS, pane: PANE }, T0);
    const binary = inputFrame(encoder.encode("b"));
    const jsonAccepted = INPUT_RATE_LIMIT_PER_SOCKET / 2;
    let accepted = 0;

    for (let index = 0; index < jsonAccepted; index += 1) {
      accepted += sends(
        core.handleGuest(
          "c-alice",
          { t: "input", ws: WS, pane: PANE, data: "j" },
          T0,
        ),
        "c-host",
      ).filter((message) => message.t === "guest-input").length;
    }
    for (
      let index = jsonAccepted;
      index < INPUT_RATE_LIMIT_PER_SOCKET;
      index += 1
    ) {
      accepted += binarySends(routeFrame(core, "c-alice", binary, T0)).length;
    }
    expect(accepted).toBe(INPUT_RATE_LIMIT_PER_SOCKET);

    const rejected = routeFrame(core, "c-alice", binary, T0);
    expect(binarySends(rejected)).toEqual([]);
    expect(closes(rejected)).toEqual([
      {
        to: "c-alice",
        code: RATE_LIMIT_CLOSE_CODE,
        reason: RATE_LIMIT_CLOSE_REASON,
      },
    ]);
    expect(
      binarySends(routeFrame(core, "c-alice", binary, T0 + RATE_WINDOW_MS)),
    ).toHaveLength(1);
  });

  it("shares the 240/room/s terminal-input budget with JSON input", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 5 }, (_, index) => ({
      id: `c-input-${index}`,
      identity: {
        user: `u-input-${index}`,
        email: `input-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) {
      approveGuest(core, guest.id, guest.identity, "editor");
      core.handleGuest(guest.id, { t: "sub", ws: WS, pane: PANE }, T0);
    }
    const binary = inputFrame(encoder.encode("b"));
    const jsonPerGuest = INPUT_RATE_LIMIT_PER_SOCKET / 2;
    let accepted = 0;

    for (const guest of guests.slice(0, 4)) {
      for (let index = 0; index < jsonPerGuest; index += 1) {
        accepted += sends(
          core.handleGuest(
            guest.id,
            { t: "input", ws: WS, pane: PANE, data: "j" },
            T0,
          ),
          "c-host",
        ).filter((message) => message.t === "guest-input").length;
      }
      for (
        let index = jsonPerGuest;
        index < INPUT_RATE_LIMIT_PER_SOCKET;
        index += 1
      ) {
        accepted += binarySends(routeFrame(core, guest.id, binary, T0)).length;
      }
    }
    expect(accepted).toBe(INPUT_RATE_LIMIT_PER_ROOM);

    const rejected = routeFrame(core, guests[4]!.id, binary, T0);
    expect(binarySends(rejected)).toEqual([]);
    expect(closes(rejected)).toEqual([]);
    expect(sends(rejected, guests[4]!.id)).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit exceeded" },
    ]);
    expect(routeFrame(core, guests[4]!.id, binary, T0)).toEqual([]);
    expect(
      binarySends(
        routeFrame(core, guests[4]!.id, binary, T0 + RATE_WINDOW_MS),
      ),
    ).toHaveLength(1);
  });
});

describe("terminal resync recovery", () => {
  it("parses terminal-resync without trusting a caller-supplied identity", () => {
    expect(
      parseGuestMessage({
        t: "terminal-resync",
        user: "u-forged",
        ws: WS,
        pane: PANE,
      }),
    ).toEqual({ t: "terminal-resync", ws: WS, pane: PANE } as never);
  });

  it("forwards only active subscribed requests with verified identity", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    approveGuest(core, "c-bob", BOB, "viewer");
    approveGuest(core, "c-carol", CAROL, "editor");
    core.connect("c-pending", PENDING, T0);
    core.handleGuest("c-alice", { t: "sub", ws: WS, pane: PANE }, T0);
    core.handleGuest("c-bob", { t: "sub", ws: WS, pane: PANE }, T0);

    expect(sends(terminalResync(core, "c-alice", T0), "c-host")).toEqual([
      { t: "guest-resync", user: ALICE.user, ws: WS, pane: PANE } as never,
    ]);
    expect(sends(terminalResync(core, "c-bob", T0), "c-host")).toEqual([
      { t: "guest-resync", user: BOB.user, ws: WS, pane: PANE } as never,
    ]);
    for (const sender of ["c-carol", "c-pending", "c-unknown"]) {
      expect(terminalResync(core, sender, T0)).toEqual([]);
    }
  });

  it("accepts two resyncs per socket, reports N+1 once, and resets at one second", () => {
    const core = bootedCore();
    approveGuest(core, "c-alice", ALICE, "editor");
    core.handleGuest("c-alice", { t: "sub", ws: WS, pane: PANE }, T0);

    for (let index = 0; index < TERMINAL_RESYNC_PER_SOCKET; index += 1) {
      expect(sends(terminalResync(core, "c-alice", T0), "c-host")).toHaveLength(1);
    }
    const rejected = terminalResync(core, "c-alice", T0);
    expect(sends(rejected, "c-host")).toEqual([]);
    expect(sends(rejected, "c-alice")).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit reached" },
    ]);
    expect(closes(rejected)).toEqual([]);
    expect(terminalResync(core, "c-alice", T0)).toEqual([]);

    expect(
      sends(terminalResync(core, "c-alice", T0 + RATE_WINDOW_MS - 1), "c-host"),
    ).toEqual([]);
    expect(
      sends(terminalResync(core, "c-alice", T0 + RATE_WINDOW_MS), "c-host"),
    ).toHaveLength(1);
  });

  it("accepts eight room resyncs, reports N+1 once, and resets at one second", () => {
    const core = bootedCore();
    const guests = Array.from({ length: 5 }, (_, index) => ({
      id: `c-guest-${index}`,
      identity: {
        user: `u-guest-${index}`,
        email: `guest-${index}@example.com`,
        hostToken: false,
      },
    }));
    for (const guest of guests) {
      approveGuest(core, guest.id, guest.identity, "viewer");
      core.handleGuest(guest.id, { t: "sub", ws: WS, pane: PANE }, T0);
    }

    let forwarded = 0;
    for (const guest of guests.slice(0, 4)) {
      for (let index = 0; index < 2; index += 1) {
        forwarded += sends(terminalResync(core, guest.id, T0), "c-host").length;
      }
    }
    expect(forwarded).toBe(TERMINAL_RESYNC_PER_ROOM);

    const rejected = terminalResync(core, guests[4]!.id, T0);
    expect(sends(rejected, "c-host")).toEqual([]);
    expect(sends(rejected, guests[4]!.id)).toEqual([
      { t: "error", code: "rate_limited", message: "rate limit reached" },
    ]);
    expect(closes(rejected)).toEqual([]);
    expect(terminalResync(core, guests[4]!.id, T0)).toEqual([]);

    expect(
      sends(terminalResync(core, guests[4]!.id, T0 + RATE_WINDOW_MS), "c-host"),
    ).toHaveLength(1);
  });
});

class AckSocket implements OutboundSocket {
  readonly sent: Array<string | ArrayBuffer | ArrayBufferView> = [];
  readonly serialized: unknown[] = [];
  readonly closed: Array<{ code?: number; reason?: string }> = [];

  send(data: string | ArrayBuffer | ArrayBufferView): void {
    this.sent.push(data);
  }

  serializeAttachment(value: unknown): void {
    this.serialized.push(structuredClone(value));
  }

  close(code?: number, reason?: string): void {
    this.closed.push({ code, reason });
  }
}

describe("v2 binary delivery credit", () => {
  it("persists ACK credit before a baseline and releases it after hibernation", async () => {
    const socket = new AckSocket();
    const attachment = createSocketAttachment({
      connId: "c-viewer",
      user: BOB.user,
      email: BOB.email,
      host: false,
    });
    const sockets = new Map([["c-viewer", socket]]);
    const attachments = new Map([["c-viewer", attachment]]);
    const runtime: OutboundEffectRuntime<AckSocket> = {
      core: null,
      sockets,
      attachments,
      now: () => T0,
      randomUUID: () => "00000000-0000-4000-8000-000000000001",
      persist: async () => {},
      setAlarm: async () => {},
      clearAlarm: async () => {},
      deleteAllStorage: async () => {},
      removeSocketState: () => {},
      logInvariant: () => {},
    };
    const frame = baselineFrame();

    await dispatchEffects([{ kind: "sendBinary", to: "c-viewer", data: frame }], runtime);

    expect(socket.sent[0]).toEqual(frame);
    const ack = JSON.parse(socket.sent[1] as string) as { t?: string; nonce?: string };
    expect(ack.t).toBe("ack-request");
    expect(typeof ack.nonce).toBe("string");
    const restored = parseSocketAttachment(socket.serialized.at(-1));
    expect(restored?.outstanding).toEqual([
      expect.objectContaining({ nonce: ack.nonce }),
    ]);
    if (!restored || !ack.nonce) throw new Error("missing restored ACK credit");
    const wakeSocket = new AckSocket();
    expect(releaseDeliveryCredit(wakeSocket, restored, ack.nonce)).toBe("released");
    expect(restored.outstanding).toEqual([]);
  });
});
