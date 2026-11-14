import { describe, expect, it } from "vitest";
import { base64UrlEncode, utf8 } from "../src/crypto";
import { signAccessToken, verifyAccessToken } from "../src/jwt";

const SECRET = "test-secret";

describe("access tokens", () => {
  it("round-trips", async () => {
    const { token, expiresAt } = await signAccessToken(SECRET, "user-1", 3600, 1000);
    expect(expiresAt).toBe(4600);
    const claims = await verifyAccessToken(SECRET, token, 2000);
    expect(claims?.sub).toBe("user-1");
    expect(claims?.typ).toBe("user");
  });
  it("rejects expired tokens", async () => {
    const { token } = await signAccessToken(SECRET, "u", 10, 1000);
    expect(await verifyAccessToken(SECRET, token, 1010)).toBeNull();
  });
  it("rejects a different secret", async () => {
    const { token } = await signAccessToken(SECRET, "u", 10);
    expect(await verifyAccessToken("other", token)).toBeNull();
  });
  it("rejects tampered payloads", async () => {
    const { token } = await signAccessToken(SECRET, "u", 3600);
    const [h, , s] = token.split(".");
    const forged = base64UrlEncode(utf8(JSON.stringify({ iss: "cmux-next-mobile-native", sub: "admin", typ: "user", exp: 9e9 })));
    expect(await verifyAccessToken(SECRET, `${h}.${forged}.${s}`)).toBeNull();
  });
  it("rejects alg none and garbage", async () => {
    const none = `${base64UrlEncode(utf8('{"alg":"none"}'))}.${base64UrlEncode(utf8('{"sub":"x"}'))}.`;
    expect(await verifyAccessToken(SECRET, none)).toBeNull();
    expect(await verifyAccessToken(SECRET, "not-a-jwt")).toBeNull();
  });
});
