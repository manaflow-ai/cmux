import { describe, expect, it } from "vitest";
import { SUPPORTED_PROTOCOL, supportsProtocol } from "../src/lib/protocol";

describe("protocol compatibility", () => {
  it("accepts protocol 9 and rejects incompatible versions", () => {
    expect(SUPPORTED_PROTOCOL).toBe(9);
    expect(supportsProtocol(9)).toBe(true);
    expect(supportsProtocol(6)).toBe(false);
    expect(supportsProtocol(7)).toBe(false);
    expect(supportsProtocol(8)).toBe(false);
  });
});
