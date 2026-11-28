import { describe, expect, it } from "vitest";
import {
  base64UrlDecode,
  base64UrlEncode,
  generateEmailCode,
  generatePairingCode,
  generateToken,
  normalizePairingCode,
  PAIRING_ALPHABET,
  randomInt,
  sha256Hex,
  timingSafeEqual,
} from "../src/crypto";
import { q } from "../src/db";

describe("codes", () => {
  it("email codes are 6 digits", () => {
    for (let i = 0; i < 500; i++) expect(generateEmailCode()).toMatch(/^\d{6}$/);
  });
  it("pairing codes use the unambiguous alphabet", () => {
    for (let i = 0; i < 500; i++) {
      const c = generatePairingCode();
      expect(c).toHaveLength(8);
      for (const ch of c) expect(PAIRING_ALPHABET).toContain(ch);
      expect(c).not.toMatch(/[01IO]/);
    }
  });
  it("pairing codes normalize with or without a dash or spaces", () => {
    expect(normalizePairingCode("abcd-efgh")).toBe("ABCDEFGH");
    expect(normalizePairingCode(" ab cd efgh ")).toBe("ABCDEFGH");
  });
  it("randomInt stays in range and covers it", () => {
    const seen = new Set<number>();
    for (let i = 0; i < 2000; i++) {
      const v = randomInt(10);
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThan(10);
      seen.add(v);
    }
    expect(seen.size).toBe(10);
  });
  it("tokens carry a prefix and 256 bits", () => {
    const t = generateToken("cnh");
    expect(t).toMatch(/^cnh_[A-Za-z0-9_-]{43}$/);
    expect(generateToken("cnh")).not.toBe(t);
  });
});

describe("encoding and hashing", () => {
  it("base64url round-trips", () => {
    const bytes = new Uint8Array([0, 255, 62, 63, 1, 2, 3]);
    expect(base64UrlDecode(base64UrlEncode(bytes))).toEqual(bytes);
    expect(base64UrlEncode(bytes)).not.toMatch(/[+/=]/);
  });
  it("sha256Hex matches a known vector", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  });
  it("timingSafeEqual", () => {
    expect(timingSafeEqual("abc", "abc")).toBe(true);
    expect(timingSafeEqual("abc", "abd")).toBe(false);
    expect(timingSafeEqual("abc", "abcd")).toBe(false);
  });
});

describe("sql escaping", () => {
  it("escapes quotes and backslashes", () => {
    expect(q("SELECT ? AS a", ["x' OR '1'='1"])).toBe("SELECT 'x\\' OR \\'1\\'=\\'1' AS a");
    expect(q("SELECT ?", ["a\\b"])).toBe("SELECT 'a\\\\b'");
  });
  it("formats nulls, numbers and UTC dates", () => {
    expect(q("? ? ?", [null, 5, new Date("2026-01-02T03:04:05.678Z")])).toBe("NULL 5 '2026-01-02 03:04:05.678'");
  });
});
