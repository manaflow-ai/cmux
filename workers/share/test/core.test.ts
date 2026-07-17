// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.

import { describe, expect, it } from "bun:test";
import {
  appendChat,
  BASE62_ALPHABET,
  base64UrlEncode,
  CHAT_HISTORY_CAP,
  frameWithinLimit,
  generateHostToken,
  generateShareId,
  HOST_COLOR,
  joinStateForVerdict,
  MAX_CHAT_TEXT_LENGTH,
  MAX_HOST_FRAME_BYTES,
  MAX_VIEWER_FRAME_BYTES,
  newTokenBucket,
  parseIncoming,
  PALETTE_SIZE,
  sha256Hex,
  SHARE_ID_LENGTH,
  tryTakeToken,
  viewerColor,
  type RandomFill,
  type StoredChatMessage,
} from "../src/core";

const cryptoFill: RandomFill = (bytes) => crypto.getRandomValues(bytes);

/** Deterministic fill cycling through the given byte values. */
function sequenceFill(values: number[]): RandomFill {
  let i = 0;
  return (bytes) => {
    for (let j = 0; j < bytes.length; j++) {
      bytes[j] = values[i % values.length]!;
      i++;
    }
    return bytes;
  };
}

describe("generateShareId", () => {
  it("produces base62 ids of the configured length", () => {
    const id = generateShareId(cryptoFill);
    expect(id).toHaveLength(SHARE_ID_LENGTH);
    expect(id).toMatch(/^[0-9A-Za-z]+$/);
  });

  it("rejection-samples bytes >= 248 instead of biasing", () => {
    // 255 must be skipped (248..255 are rejected); 0 maps to alphabet[0].
    const id = generateShareId(sequenceFill([255, 0]), 4);
    expect(id).toBe(BASE62_ALPHABET[0]!.repeat(4));
  });

  it("maps accepted bytes with byte % 62", () => {
    const id = generateShareId(sequenceFill([61, 62, 123]), 3);
    // 61 -> 'z' (index 61), 62 -> index 0, 123 -> index 123-62=61 -> 'z'
    expect(id).toBe(`${BASE62_ALPHABET[61]}${BASE62_ALPHABET[0]}${BASE62_ALPHABET[61]}`);
  });

  it("produces distinct ids", () => {
    expect(generateShareId(cryptoFill)).not.toBe(generateShareId(cryptoFill));
  });
});

describe("generateHostToken / base64UrlEncode", () => {
  it("is url-safe base64 without padding, 43 chars for 32 bytes", () => {
    const token = generateHostToken(cryptoFill);
    expect(token).toHaveLength(43);
    expect(token).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("base64UrlEncode substitutes +/ and strips padding", () => {
    // 0xfb 0xff -> base64 "+/8=" -> url-safe "-_8"
    expect(base64UrlEncode(new Uint8Array([0xfb, 0xff]))).toBe("-_8");
  });
});

describe("sha256Hex", () => {
  it("matches a known digest", async () => {
    expect(await sha256Hex("abc")).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });
});

describe("viewerColor", () => {
  it("never collides with the host color", () => {
    for (let ordinal = 0; ordinal < 30; ordinal++) {
      expect(viewerColor(ordinal)).not.toBe(HOST_COLOR);
    }
  });

  it("cycles through the 9 non-host palette slots", () => {
    const first = Array.from({ length: PALETTE_SIZE - 1 }, (_, i) => viewerColor(i));
    expect(new Set(first).size).toBe(PALETTE_SIZE - 1);
    expect(viewerColor(PALETTE_SIZE - 1)).toBe(viewerColor(0));
  });
});

describe("joinStateForVerdict", () => {
  it("maps verdicts to states", () => {
    expect(joinStateForVerdict(undefined)).toBe("pending");
    expect(joinStateForVerdict("approved")).toBe("approved");
    expect(joinStateForVerdict("denied")).toBe("denied");
  });
});

describe("appendChat", () => {
  function msg(n: number): StoredChatMessage {
    return { type: "chat", participantId: "p", ts: n, text: `m${n}`, x: 0, y: 0 };
  }

  it("appends below the cap", () => {
    expect(appendChat([msg(1)], msg(2), 3)).toEqual([msg(1), msg(2)]);
  });

  it("drops the oldest entries above the cap", () => {
    const history = [msg(1), msg(2), msg(3)];
    expect(appendChat(history, msg(4), 3)).toEqual([msg(2), msg(3), msg(4)]);
  });

  it("does not mutate the input history", () => {
    const history = [msg(1)];
    appendChat(history, msg(2), 1);
    expect(history).toEqual([msg(1)]);
  });

  it("defaults the cap to CHAT_HISTORY_CAP", () => {
    const history = Array.from({ length: CHAT_HISTORY_CAP }, (_, i) => msg(i));
    const next = appendChat(history, msg(999));
    expect(next).toHaveLength(CHAT_HISTORY_CAP);
    expect(next[next.length - 1]).toEqual(msg(999));
    expect(next[0]).toEqual(msg(1));
  });
});

describe("token bucket", () => {
  it("allows a burst then drops until refill", () => {
    const t0 = 1_000_000;
    const bucket = newTokenBucket(t0, 3);
    expect(tryTakeToken(bucket, t0, 3, 3)).toBe(true);
    expect(tryTakeToken(bucket, t0, 3, 3)).toBe(true);
    expect(tryTakeToken(bucket, t0, 3, 3)).toBe(true);
    expect(tryTakeToken(bucket, t0, 3, 3)).toBe(false);
    // One token refills after 1/3 s at 3/s.
    expect(tryTakeToken(bucket, t0 + 334, 3, 3)).toBe(true);
    expect(tryTakeToken(bucket, t0 + 334, 3, 3)).toBe(false);
  });

  it("caps refill at burst", () => {
    const t0 = 0;
    const bucket = newTokenBucket(t0, 2);
    expect(tryTakeToken(bucket, t0 + 60_000, 2, 2)).toBe(true);
    expect(tryTakeToken(bucket, t0 + 60_000, 2, 2)).toBe(true);
    expect(tryTakeToken(bucket, t0 + 60_000, 2, 2)).toBe(false);
  });

  it("tolerates a clock going backwards", () => {
    const bucket = newTokenBucket(10_000, 1);
    expect(tryTakeToken(bucket, 10_000, 1, 1)).toBe(true);
    expect(tryTakeToken(bucket, 5_000, 1, 1)).toBe(false);
  });
});

describe("frameWithinLimit", () => {
  it("enforces the smaller viewer cap and larger host cap", () => {
    expect(frameWithinLimit("viewer", MAX_VIEWER_FRAME_BYTES)).toBe(true);
    expect(frameWithinLimit("viewer", MAX_VIEWER_FRAME_BYTES + 1)).toBe(false);
    expect(frameWithinLimit("host", MAX_VIEWER_FRAME_BYTES + 1)).toBe(true);
    expect(frameWithinLimit("host", MAX_HOST_FRAME_BYTES)).toBe(true);
    expect(frameWithinLimit("host", MAX_HOST_FRAME_BYTES + 1)).toBe(false);
  });
});

describe("parseIncoming", () => {
  it("drops non-objects and unknown types", () => {
    expect(parseIncoming("host", null)).toBeNull();
    expect(parseIncoming("host", "cursor")).toBeNull();
    expect(parseIncoming("host", [])).toBeNull();
    expect(parseIncoming("host", { type: "nope" })).toBeNull();
    expect(parseIncoming("host", { type: 42 })).toBeNull();
  });

  it("restricts viewers to cursor and chat (read-only protocol)", () => {
    for (const type of ["layout", "term", "term_resize", "textbox", "snapshot", "join_response", "end"]) {
      expect(parseIncoming("viewer", { type })).toBeNull();
    }
    expect(parseIncoming("viewer", { type: "cursor", x: 0.5, y: 0.5 })).toEqual({
      type: "cursor",
      x: 0.5,
      y: 0.5,
    });
    expect(parseIncoming("viewer", { type: "chat", text: "hi", x: 0, y: 1 })).toEqual({
      type: "chat",
      text: "hi",
      x: 0,
      y: 1,
    });
  });

  it("clamps cursor coordinates to [0,1] and rejects non-finite", () => {
    expect(parseIncoming("viewer", { type: "cursor", x: -3, y: 7 })).toEqual({
      type: "cursor",
      x: 0,
      y: 1,
    });
    expect(parseIncoming("viewer", { type: "cursor", x: Number.NaN, y: 0 })).toBeNull();
    expect(parseIncoming("viewer", { type: "cursor", x: Infinity, y: 0 })).toBeNull();
    expect(parseIncoming("viewer", { type: "cursor", x: "0.5", y: 0 })).toBeNull();
  });

  it("trims, bounds, and rejects empty chat text", () => {
    expect(parseIncoming("viewer", { type: "chat", text: "  hi  ", x: 0, y: 0 })).toEqual({
      type: "chat",
      text: "hi",
      x: 0,
      y: 0,
    });
    expect(parseIncoming("viewer", { type: "chat", text: "   ", x: 0, y: 0 })).toBeNull();
    const long = parseIncoming("viewer", {
      type: "chat",
      text: "a".repeat(MAX_CHAT_TEXT_LENGTH + 100),
      x: 0,
      y: 0,
    });
    expect(long?.type).toBe("chat");
    if (long?.type === "chat") expect(long.text).toHaveLength(MAX_CHAT_TEXT_LENGTH);
  });

  it("validates host join_response", () => {
    expect(parseIncoming("host", { type: "join_response", requestId: "r1", allow: true })).toEqual({
      type: "join_response",
      requestId: "r1",
      allow: true,
    });
    expect(parseIncoming("host", { type: "join_response", requestId: "", allow: true })).toBeNull();
    expect(parseIncoming("host", { type: "join_response", requestId: "r1", allow: "yes" })).toBeNull();
  });

  it("validates host snapshot/layout envelopes", () => {
    expect(parseIncoming("host", { type: "snapshot", to: "p1", workspace: { panes: [] } })).toEqual({
      type: "snapshot",
      to: "p1",
      workspace: { panes: [] },
    });
    expect(parseIncoming("host", { type: "snapshot", to: "", workspace: {} })).toBeNull();
    expect(parseIncoming("host", { type: "snapshot", to: "p1", workspace: [] })).toBeNull();
    expect(parseIncoming("host", { type: "layout", workspace: {} })).toEqual({
      type: "layout",
      workspace: {},
    });
    expect(parseIncoming("host", { type: "layout", workspace: null })).toBeNull();
  });

  it("validates host term / term_resize / textbox", () => {
    expect(
      parseIncoming("host", { type: "term", surfaceId: "s1", seq: 1, data_b64: "AA==" }),
    ).toEqual({ type: "term", surfaceId: "s1", seq: 1, data_b64: "AA==" });
    expect(parseIncoming("host", { type: "term", surfaceId: "s1", seq: "1", data_b64: "" })).toBeNull();
    expect(parseIncoming("host", { type: "term", surfaceId: "", seq: 1, data_b64: "" })).toBeNull();

    expect(
      parseIncoming("host", { type: "term_resize", surfaceId: "s1", cols: 80, rows: 24 }),
    ).toEqual({ type: "term_resize", surfaceId: "s1", cols: 80, rows: 24 });
    expect(parseIncoming("host", { type: "term_resize", surfaceId: "s1", cols: 80 })).toBeNull();

    expect(
      parseIncoming("host", {
        type: "textbox",
        paneId: "p1",
        text: "draft",
        selStart: 0,
        selEnd: 5,
        active: true,
      }),
    ).toEqual({ type: "textbox", paneId: "p1", text: "draft", selStart: 0, selEnd: 5, active: true });
    expect(
      parseIncoming("host", { type: "textbox", paneId: "p1", text: "x", selStart: 0, selEnd: 1 }),
    ).toBeNull();
  });

  it("accepts host end", () => {
    expect(parseIncoming("host", { type: "end" })).toEqual({ type: "end" });
  });
});
