// SPDX-License-Identifier: GPL-3.0-or-later

import { describe, expect, it } from "bun:test";

import {
  BINARY_KIND_GRID,
  decodeBinaryHeader,
  decodeGuestMessage,
  decodeHostMessage,
  encodeBinaryHeader,
  isIdentityEmail,
  isProtocolId,
  MAX_BINARY_FRAME_BYTES,
  MAX_JSON_FRAME_BYTES,
  MAX_LAYOUT_DEPTH,
  MAX_LAYOUT_PANES,
  MAX_TERMINAL_INPUT_BYTES,
  parseAckMessage,
  parseCursorPos,
  parseGuestMessage,
  parseHostMessage,
  parseWorkspaceLayout,
} from "../src/protocol";

function exactClientJson(bytes: number): string {
  const empty = JSON.stringify({ t: "hello", proto: 1, pad: "" });
  return JSON.stringify({
    t: "hello",
    proto: 1,
    pad: "x".repeat(bytes - new TextEncoder().encode(empty).byteLength),
  });
}

describe("binary frame header", () => {
  it("round-trips", () => {
    const payload = new TextEncoder().encode('{"format":"cmux.render-grid.v1"}');
    const frame = encodeBinaryHeader(BINARY_KIND_GRID, "workspace:12", "surface:7", payload);
    const header = decodeBinaryHeader(frame);
    expect(header).not.toBeNull();
    expect(header?.kind).toBe(BINARY_KIND_GRID);
    expect(header?.ws).toBe("workspace:12");
    expect(header?.pane).toBe("surface:7");
    expect(frame.subarray(header!.payloadOffset)).toEqual(payload);
  });

  it("handles empty payloads and unicode ids", () => {
    const frame = encodeBinaryHeader(2, "ws-日本", "p", new Uint8Array(0));
    const header = decodeBinaryHeader(frame);
    expect(header?.ws).toBe("ws-日本");
    expect(header?.payloadOffset).toBe(frame.length);
  });

  it("rejects truncated buffers", () => {
    const frame = encodeBinaryHeader(1, "workspace:1", "surface:1", new Uint8Array(8));
    expect(decodeBinaryHeader(frame.subarray(0, 2))).toBeNull();
    expect(decodeBinaryHeader(frame.subarray(0, 5))).toBeNull();
    expect(decodeBinaryHeader(new Uint8Array(0))).toBeNull();
  });

  it("refuses oversize ids at encode time", () => {
    expect(() =>
      encodeBinaryHeader(1, "w".repeat(300), "p", new Uint8Array(0)),
    ).toThrow();
  });

  it("rejects invalid UTF-8 ids and oversized frames", () => {
    expect(decodeBinaryHeader(new Uint8Array([1, 1, 0xff, 1, 0x70]))).toBeNull();
    expect(decodeBinaryHeader(new Uint8Array(MAX_BINARY_FRAME_BYTES))).toBeNull();
    expect(decodeBinaryHeader(new Uint8Array(MAX_BINARY_FRAME_BYTES + 1))).toBeNull();
  });

  it("accepts a complete frame at 1 MiB - 1 and rejects exact or over", () => {
    const headerBytes = 3 + 1 + 1;
    const accepted = encodeBinaryHeader(
      BINARY_KIND_GRID,
      "w",
      "p",
      new Uint8Array(MAX_BINARY_FRAME_BYTES - headerBytes - 1),
    );
    expect(accepted.byteLength).toBe(MAX_BINARY_FRAME_BYTES - 1);
    expect(decodeBinaryHeader(accepted)?.payloadOffset).toBe(headerBytes);
    expect(() =>
      encodeBinaryHeader(
        BINARY_KIND_GRID,
        "w",
        "p",
        new Uint8Array(MAX_BINARY_FRAME_BYTES - headerBytes),
      ),
    ).toThrow("binary frame too large");
    expect(decodeBinaryHeader(new Uint8Array(MAX_BINARY_FRAME_BYTES))).toBeNull();
    expect(decodeBinaryHeader(new Uint8Array(MAX_BINARY_FRAME_BYTES + 1))).toBeNull();
  });

  it("fails closed for malformed declared lengths and deterministic fuzz", () => {
    for (const malformed of [
      new Uint8Array([1]),
      new Uint8Array([1, 255, 0]),
      new Uint8Array([1, 1, 0x77]),
      new Uint8Array([1, 1, 0x77, 255]),
      new Uint8Array([1, 2, 0x77, 0xff, 1, 0x70]),
    ]) {
      expect(decodeBinaryHeader(malformed)).toBeNull();
    }

    let state = 0x5eed1234;
    for (let sample = 0; sample < 1_000; sample += 1) {
      state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
      const bytes = new Uint8Array(state % 512);
      for (let index = 0; index < bytes.length; index += 1) {
        state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
        bytes[index] = state & 0xff;
      }
      expect(() => decodeBinaryHeader(bytes)).not.toThrow();
      const decoded = decodeBinaryHeader(bytes);
      if (decoded) {
        expect(decoded.payloadOffset).toBeLessThanOrEqual(bytes.length);
        expect(decoded.ws.length).toBeGreaterThan(0);
        expect(decoded.pane.length).toBeGreaterThan(0);
      }
    }
  });
});

describe("runtime JSON envelopes", () => {
  it("sanitizes guest input and never accepts a caller-supplied identity", () => {
    expect(
      parseGuestMessage({
        t: "input",
        user: "forged-user",
        ws: "workspace:1",
        pane: "surface:1",
        data: "ls\n",
      }),
    ).toEqual({
      t: "input",
      ws: "workspace:1",
      pane: "surface:1",
      data: "ls\n",
    });
  });

  it("rejects malformed, unsupported, and oversized guest messages", () => {
    expect(decodeGuestMessage("{")).toBeNull();
    expect(decodeGuestMessage(JSON.stringify({ t: "follow", user: "u-host" }))).toBeNull();
    expect(
      decodeGuestMessage(
        JSON.stringify({
          t: "input",
          ws: "workspace:1",
          pane: "surface:1",
          data: "界".repeat(Math.ceil(MAX_TERMINAL_INPUT_BYTES / 3) + 1),
        }),
      ),
    ).toBeNull();
    expect(decodeGuestMessage(" ".repeat(MAX_JSON_FRAME_BYTES + 1))).toBeNull();
  });

  it("accepts client JSON at 64 KiB - 1 and rejects exact or over", () => {
    expect(decodeGuestMessage(exactClientJson(MAX_JSON_FRAME_BYTES - 1))).toEqual({
      t: "hello",
      proto: 1,
    });
    expect(decodeGuestMessage(exactClientJson(MAX_JSON_FRAME_BYTES))).toBeNull();
    expect(decodeGuestMessage(exactClientJson(MAX_JSON_FRAME_BYTES + 1))).toBeNull();
  });

  it("accepts only bounded ACK nonces without Unicode controls", () => {
    expect(parseAckMessage({ t: "ack", nonce: crypto.randomUUID() })).not.toBeNull();
    expect(
      parseAckMessage({
        t: "ack",
        nonce: crypto.randomUUID(),
        padding: "x".repeat(60 * 1024),
      }),
    ).toBeNull();
    expect(parseAckMessage({ t: "ack", nonce: "" })).toBeNull();
    expect(parseAckMessage({ t: "ack", nonce: "x".repeat(65) })).toBeNull();
    for (const control of ["\u0000", "\u001f", "\u007f", "\u0085", "\u009f"]) {
      expect(parseAckMessage({ t: "ack", nonce: `before${control}after` })).toBeNull();
    }
  });

  it("rejects full Unicode Cc controls in ids and identity email", () => {
    for (const control of ["\u0000", "\u007f", "\u0085", "\u009f"]) {
      expect(isProtocolId(`workspace${control}hidden`)).toBe(false);
      expect(isIdentityEmail(`user${control}@example.com`)).toBe(false);
      expect(
        parseGuestMessage({
          t: "input",
          ws: `workspace${control}hidden`,
          pane: "surface:1",
          data: "x",
        }),
      ).toBeNull();
    }
  });

  it("rejects unsafe chat and input identifiers", () => {
    expect(
      parseGuestMessage({
        t: "input",
        ws: "workspace:1",
        pane: "surface:\u0000hidden",
        data: "x",
      }),
    ).toBeNull();
    expect(
      parseGuestMessage({
        t: "chat",
        text: "hello",
        bubble: { ws: "", pane: "surface:1", x: 0.5, y: 0.5 },
      }),
    ).toBeNull();
  });

  it("requires finite normalized cursor coordinates", () => {
    expect(parseCursorPos({ ws: "workspace:1", pane: "surface:1", x: 0, y: 1 })).not.toBeNull();
    for (const x of [Number.NaN, Number.POSITIVE_INFINITY, -0.01, 1.01]) {
      expect(parseCursorPos({ ws: "workspace:1", pane: "surface:1", x, y: 0.5 })).toBeNull();
    }
  });

  it("allows at most one shared workspace and only matching layouts", () => {
    expect(
      parseHostMessage({
        t: "hello",
        proto: 1,
        shared: [
          { id: "workspace:1", title: "one" },
          { id: "workspace:2", title: "two" },
        ],
        layouts: [],
      }),
    ).toBeNull();
    expect(
      parseHostMessage({
        t: "hello",
        proto: 1,
        shared: [{ id: "workspace:1", title: "one" }],
        layouts: [{ ws: "workspace:2", tree: null }],
      }),
    ).toBeNull();
    expect(
      decodeHostMessage(
        JSON.stringify({
          t: "hello",
          proto: 1,
          shared: [{ id: "workspace:1", title: "one" }],
          layouts: [{ ws: "workspace:1", tree: null }],
        }),
      ),
    ).not.toBeNull();
  });

  it("bounds layout depth and terminal count", () => {
    let deep: unknown = { kind: "pane", pane: "surface:deep", content: "terminal" };
    for (let i = 0; i < MAX_LAYOUT_DEPTH; i += 1) {
      deep = {
        kind: "split",
        axis: "h",
        ratio: 0.5,
        a: deep,
        b: { kind: "pane", pane: `surface:side-${i}`, content: "other" },
      };
    }
    expect(parseWorkspaceLayout({ ws: "workspace:1", tree: deep })).toBeNull();

    const panes = Array.from({ length: MAX_LAYOUT_PANES + 1 }, (_, i) => ({
      kind: "pane" as const,
      pane: `surface:${i}`,
      content: "terminal" as const,
    }));
    while (panes.length > 1) {
      const a = panes.shift();
      const b = panes.shift();
      if (!a || !b) throw new Error("missing layout node");
      panes.push({ kind: "split", axis: "h", ratio: 0.5, a, b } as never);
    }
    expect(parseWorkspaceLayout({ ws: "workspace:1", tree: panes[0] })).toBeNull();
  });
});
