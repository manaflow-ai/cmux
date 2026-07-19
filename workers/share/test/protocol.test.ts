import { describe, expect, it } from "bun:test";

import {
  BINARY_KIND_GRID,
  decodeBinaryHeader,
  encodeBinaryHeader,
} from "../src/protocol";

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
});
