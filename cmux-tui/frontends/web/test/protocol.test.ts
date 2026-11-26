import { describe, expect, it } from "vitest";
import { SUPPORTED_PROTOCOL, supportsProtocol } from "../src/lib/protocol";

describe("protocol compatibility", () => {
  it("accepts protocol 12 and rejects incompatible versions", () => {
    expect(SUPPORTED_PROTOCOL).toBe(12);
    expect(supportsProtocol(12)).toBe(true);
    expect(supportsProtocol(6)).toBe(false);
    expect(supportsProtocol(7)).toBe(false);
    expect(supportsProtocol(8)).toBe(false);
    expect(supportsProtocol(9)).toBe(false);
    expect(supportsProtocol(10)).toBe(false);
    expect(supportsProtocol(11)).toBe(false);
  });
});
