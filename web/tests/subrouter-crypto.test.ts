import { describe, expect, test } from "bun:test";

import {
  SubrouterTenantKeyDecryptionError,
  SubrouterTenantKeySecretError,
  decryptTenantKey,
  encryptTenantKey,
} from "../services/subrouter/crypto";

const secret = Buffer.alloc(32, 7).toString("base64");

describe("subrouter tenant key crypto", () => {
  test("round-trips a tenant key without storing plaintext", () => {
    const tenantKey = "srt_0123456789abcdef0123456789abcdef";
    const encrypted = encryptTenantKey(tenantKey, secret);

    expect(encrypted.startsWith("v1:")).toBe(true);
    expect(encrypted).not.toContain(tenantKey);
    expect(decryptTenantKey(encrypted, secret)).toBe(tenantKey);
  });

  test("rejects tampered ciphertext", () => {
    const encrypted = encryptTenantKey("srt_0123456789abcdef0123456789abcdef", secret);
    const parts = encrypted.split(":");
    parts[2] = Buffer.alloc(16, 3).toString("base64");

    expect(() => decryptTenantKey(parts.join(":"), secret)).toThrow(SubrouterTenantKeyDecryptionError);
  });

  test("rejects a non-256-bit secret", () => {
    const shortSecret = Buffer.alloc(31, 1).toString("base64");

    expect(() => encryptTenantKey("srt_0123456789abcdef0123456789abcdef", shortSecret)).toThrow(
      SubrouterTenantKeySecretError,
    );
  });
});
