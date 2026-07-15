import { describe, expect, it } from "vitest";
import { SUPPORTED_PROTOCOL, supportsProtocol } from "../src/lib/protocol";

describe("protocol compatibility", () => {
  it("accepts protocol 7 and rejects incompatible versions", () => {
    expect(SUPPORTED_PROTOCOL).toBe(7);
    expect(supportsProtocol(7)).toBe(true);
    expect(supportsProtocol(6)).toBe(false);
    expect(supportsProtocol(8)).toBe(false);
  });
});
