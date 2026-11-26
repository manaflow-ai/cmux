import { describe, expect, it } from "vitest";
import { toTerminalStreamEvent } from "./terminalTransport";

const bytes = new Uint8Array([104, 105]);

describe("toTerminalStreamEvent", () => {
  it("maps vt-state and resized to a replay at the server's size", () => {
    expect(toTerminalStreamEvent({ event: "vt-state", cols: 80, rows: 24, data: bytes }, 1n)).toEqual({
      kind: "replay",
      cols: 80,
      rows: 24,
      data: bytes,
    });
    expect(toTerminalStreamEvent({ event: "resized", cols: 100, rows: 30, data: bytes, replay: bytes }, 1n)).toEqual({
      kind: "replay",
      cols: 100,
      rows: 30,
      data: bytes,
    });
  });

  it("passes output bytes through", () => {
    expect(toTerminalStreamEvent({ event: "output", data: bytes }, 1n)).toEqual({ kind: "output", data: bytes });
  });

  it("reports overflow only for this surface", () => {
    expect(toTerminalStreamEvent({ event: "overflow", scope: "surface", surface: 1n }, 1n)).toEqual({
      kind: "overflow",
    });
    expect(toTerminalStreamEvent({ event: "overflow", scope: "surface", surface: 2n }, 1n)).toBeNull();
  });

  it("ends on detached and ignores the rest", () => {
    expect(toTerminalStreamEvent({ event: "detached" }, 1n)).toEqual({ kind: "ended" });
    expect(toTerminalStreamEvent({ event: "colors-changed" }, 1n)).toBeNull();
  });
});
