import { describe, expect, test } from "bun:test";
import { bearerToken, timingSafeEqualString } from "../src/internalAuth";
import { mintCallerKeyForTests, verifyCallerKey } from "../src/keys";

describe("caller keys", () => {
  test("round-trips and rejects tampering", async () => {
    const secret = "test-secret";
    const payload = { v: 1 as const, kid: "kid-1", team: "team-1", iat: 123 };
    const key = await mintCallerKeyForTests(payload, secret);
    await expect(verifyCallerKey(key, secret)).resolves.toEqual(payload);
    await expect(verifyCallerKey(`${key.slice(0, -1)}x`, secret)).resolves.toBeNull();
    await expect(verifyCallerKey(key, "other")).resolves.toBeNull();
  });

  test("constant-time compare keeps length mismatch on the same path", () => {
    expect(timingSafeEqualString("abc", "abc")).toBe(true);
    expect(timingSafeEqualString("abc", "abd")).toBe(false);
    expect(timingSafeEqualString("abc", "abcx")).toBe(false);
  });

  test("extracts bearer tokens", () => {
    const headers = new Headers({ authorization: "Bearer secret" });
    expect(bearerToken(headers)).toBe("secret");
  });
});
