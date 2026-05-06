import { describe, expect, test } from "bun:test";
import {
  HIVE_PAIRING_MAX_TTL_SECONDS,
  validateHivePairingExpiry,
} from "../services/hive/actor";

describe("hive pairing expiry policy", () => {
  test("accepts short lived pairing expirations", () => {
    const nowUnix = 1_000;

    expect(() =>
      validateHivePairingExpiry(nowUnix + HIVE_PAIRING_MAX_TTL_SECONDS, nowUnix),
    ).not.toThrow();
  });

  test("rejects expired pairings", () => {
    expect(() => validateHivePairingExpiry(999, 1_000)).toThrow("Pairing is expired");
  });

  test("rejects pairing expirations beyond the max ttl", () => {
    const nowUnix = 1_000;

    expect(() =>
      validateHivePairingExpiry(nowUnix + HIVE_PAIRING_MAX_TTL_SECONDS + 1, nowUnix),
    ).toThrow("Pairing expiration is too far in the future");
  });
});
