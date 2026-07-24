// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  APPLICATION_INGRESS_WINDOW_MS,
  ApplicationIngressLimiter,
  MAX_APPLICATION_BYTES_PER_WINDOW,
  MAX_APPLICATION_MESSAGES_PER_WINDOW,
  validateBinaryIngress,
} from "../src/ingress";
import {
  BINARY_KIND_GRID,
  encodeBinaryHeader,
  MAX_BINARY_FRAME_BYTES,
  parseAckMessage,
  parseGuestMessage,
} from "../src/protocol";

const T0 = 1_700_000_000_000;

describe("guest application ingress budget", () => {
  it("accepts 120 messages, rejects 121, and resets at one second", () => {
    const limiter = new ApplicationIngressLimiter();
    for (let index = 0; index < MAX_APPLICATION_MESSAGES_PER_WINDOW; index += 1) {
      expect(limiter.consume("guest", 1, T0)).toBe(true);
    }
    expect(limiter.consume("guest", 1, T0)).toBe(false);
    expect(limiter.consume("guest", 1, T0 + APPLICATION_INGRESS_WINDOW_MS - 1)).toBe(
      false,
    );
    expect(limiter.consume("guest", 1, T0 + APPLICATION_INGRESS_WINDOW_MS)).toBe(true);
  });

  it("accepts exactly 512 KiB of UTF-8 accounting and rejects one byte over", () => {
    const limiter = new ApplicationIngressLimiter();
    const frame = 64 * 1024 - 1;
    for (let index = 0; index < 8; index += 1) {
      expect(limiter.consume("guest", frame, T0)).toBe(true);
    }
    expect(limiter.consume("guest", MAX_APPLICATION_BYTES_PER_WINDOW - frame * 8, T0)).toBe(
      true,
    );
    expect(limiter.profile("guest")?.bytes).toBe(MAX_APPLICATION_BYTES_PER_WINDOW);
    expect(limiter.consume("guest", 1, T0)).toBe(false);
    expect(limiter.consume("guest", 3, T0 + APPLICATION_INGRESS_WINDOW_MS)).toBe(true);
    expect(limiter.profile("guest")?.bytes).toBe(3);
  });

  it("keeps exact matching ACK traffic exempt while fabricated ACKs stay bounded", () => {
    const limiter = new ApplicationIngressLimiter();
    const ackBytes = new TextEncoder().encode(
      JSON.stringify({ t: "ack", nonce: crypto.randomUUID() }),
    ).byteLength;
    for (let index = 0; index < 1_000; index += 1) {
      expect(limiter.consume("guest", ackBytes, T0)).toBe(true);
      limiter.refund("guest", ackBytes, T0);
    }
    expect(limiter.profile("guest")).toEqual({
      startedAt: T0,
      messages: 0,
      bytes: 0,
    });

    // Unknown, duplicate, pending, viewer, and invalid messages deliberately
    // receive no refund and share the same bounded abuse profile.
    for (let index = 0; index < MAX_APPLICATION_MESSAGES_PER_WINDOW; index += 1) {
      expect(limiter.consume("fabricated", ackBytes, T0)).toBe(true);
    }
    expect(limiter.consume("fabricated", ackBytes, T0)).toBe(false);
  });

  it("charges a padded matching-nonce envelope because it is not an exact ACK", () => {
    const limiter = new ApplicationIngressLimiter();
    const nonce = crypto.randomUUID();
    const padded = JSON.stringify({
      t: "ack",
      nonce,
      padding: "x".repeat(60 * 1024),
    });
    const bytes = new TextEncoder().encode(padded).byteLength;
    expect(limiter.consume("guest", bytes, T0)).toBe(true);
    const decoded = JSON.parse(padded) as unknown;
    expect(parseAckMessage(decoded)).toBeNull();
    expect(parseGuestMessage(decoded)).toBeNull();
    // Neither parser produces a dispatchable message, so the DO takes its
    // invalid-message close path without releasing or refunding the charge.
    expect(limiter.profile("guest")).toEqual({
      startedAt: T0,
      messages: 1,
      bytes,
    });
  });

  it("removes closed profiles and never retains more than connected sockets", () => {
    const limiter = new ApplicationIngressLimiter();
    for (let index = 0; index < 32; index += 1) {
      limiter.consume(`guest-${index}`, 1, T0);
    }
    expect(limiter.profileCount).toBe(32);
    for (let index = 0; index < 32; index += 1) {
      limiter.remove(`guest-${index}`);
    }
    expect(limiter.profileCount).toBe(0);
  });
});

describe("binary ingress decisions", () => {
  it("accepts host limit - 1 and closes exact/over with 1009", () => {
    const fixedHeaderBytes = 3 + 1 + 1;
    const accepted = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "w",
      "p",
      new Uint8Array(MAX_BINARY_FRAME_BYTES - fixedHeaderBytes - 1),
    );
    expect(validateBinaryIngress(true, accepted)).toMatchObject({
      ok: true,
      header: { kind: BINARY_KIND_GRID, ws: "w", pane: "p" },
    });
    expect(validateBinaryIngress(true, new Uint8Array(MAX_BINARY_FRAME_BYTES))).toEqual({
      ok: false,
      code: 1009,
      reason: "binary message too large",
    });
    expect(validateBinaryIngress(true, new Uint8Array(MAX_BINARY_FRAME_BYTES + 1))).toEqual({
      ok: false,
      code: 1009,
      reason: "binary message too large",
    });
  });

  it("rejects guest, truncated, invalid UTF-8, and unknown-kind frames with no header", () => {
    const valid = encodeBinaryHeader(BINARY_KIND_GRID, "w", "p", new Uint8Array([1]));
    expect(validateBinaryIngress(false, valid)).toEqual({
      ok: false,
      code: 4400,
      reason: "guest binary not allowed",
    });
    for (const invalid of [
      valid.subarray(0, 2),
      new Uint8Array([BINARY_KIND_GRID, 1, 0xff, 1, 0x70]),
      encodeBinaryHeader(0x02, "w", "p", new Uint8Array([1])),
    ]) {
      const decision = validateBinaryIngress(true, invalid);
      expect(decision).toEqual({
        ok: false,
        code: 4400,
        reason: "invalid binary message",
      });
      expect(decision).not.toHaveProperty("header");
    }
  });
});
