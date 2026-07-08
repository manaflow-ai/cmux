import { describe, expect, test } from "bun:test";
import { normalizeVaultSessionSearch } from "../services/vault/sessionList";

describe("vault session list search", () => {
  test("normalizes q into escaped contains and prefix patterns", () => {
    expect(normalizeVaultSessionSearch("  abc_%\\  ")).toEqual({
      raw: "abc_%\\",
      containsPattern: "%abc\\_\\%\\\\%",
      prefixPattern: "abc\\_\\%\\\\%",
    });
  });

  test("ignores empty q values", () => {
    expect(normalizeVaultSessionSearch("   ")).toBeNull();
    expect(normalizeVaultSessionSearch(null)).toBeNull();
  });
});
