import { beforeEach, describe, expect, test } from "bun:test";

import { generateOpenAPIDocument } from "../orpc/server/openapi";
import {
  generateDeviceCode,
  generateUserCode,
  hashDeviceCode,
  isVaultConfigured,
  open,
  seal,
  VaultKeyMissingError,
} from "../services/subrouter/vaultCrypto";

// A fixed 32-byte key, so these tests never depend on deployment config.
const TEST_KEY = Buffer.alloc(32, 7).toString("base64");

describe("vault crypto", () => {
  beforeEach(() => {
    process.env.SR_VAULT_KEY = TEST_KEY;
  });

  test("round-trips a credential payload", () => {
    const secret = JSON.stringify({ refresh_token: "rt_abc", account: "a@example.com" });
    const sealed = seal(secret);
    expect(sealed.ciphertext).not.toContain("rt_abc");
    expect(open(sealed)).toBe(secret);
  });

  test("uses a fresh nonce per seal, so identical inputs differ at rest", () => {
    const a = seal("same");
    const b = seal("same");
    expect(a.nonce).not.toBe(b.nonce);
    expect(a.ciphertext).not.toBe(b.ciphertext);
    expect(open(a)).toBe("same");
    expect(open(b)).toBe("same");
  });

  test("rejects tampered ciphertext instead of returning garbage", () => {
    const sealed = seal("secret");
    const raw = Buffer.from(sealed.ciphertext, "base64");
    raw[0] = raw[0]! ^ 0xff;
    expect(() => open({ ...sealed, ciphertext: raw.toString("base64") })).toThrow();
  });

  test("rejects a ciphertext too short to carry an auth tag", () => {
    expect(() => open({ ciphertext: "AAAA", nonce: "AAAAAAAAAAAAAAAA", keyVersion: 1 })).toThrow(
      /too short/,
    );
  });

  test("refuses to operate without a configured key", () => {
    delete process.env.SR_VAULT_KEY;
    expect(isVaultConfigured()).toBe(false);
    expect(() => seal("secret")).toThrow(VaultKeyMissingError);
  });

  test("treats a wrong-length key as unconfigured rather than weakening the cipher", () => {
    process.env.SR_VAULT_KEY = Buffer.alloc(16, 1).toString("base64");
    expect(isVaultConfigured()).toBe(false);
    expect(() => seal("secret")).toThrow(VaultKeyMissingError);
  });
});

describe("device codes", () => {
  test("user codes avoid characters a human would misread aloud", () => {
    for (let i = 0; i < 200; i += 1) {
      const code = generateUserCode();
      expect(code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
      // 0/O and 1/I/L are the pairs that get transcribed wrong.
      expect(code).not.toMatch(/[01OIL]/);
    }
  });

  test("device codes are long, URL-safe and unique", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 100; i += 1) {
      const code = generateDeviceCode();
      expect(code).toMatch(/^[A-Za-z0-9_-]+$/);
      expect(code.length).toBeGreaterThanOrEqual(43);
      seen.add(code);
    }
    expect(seen.size).toBe(100);
  });

  test("hashing is deterministic and hides the code", () => {
    const code = generateDeviceCode();
    expect(hashDeviceCode(code)).toBe(hashDeviceCode(code));
    expect(hashDeviceCode(code)).not.toContain(code);
    expect(hashDeviceCode(code)).not.toBe(hashDeviceCode(generateDeviceCode()));
  });
});

describe("sr OpenAPI surface", () => {
  test("advertises every sr route with a stable operationId", async () => {
    const doc = await generateOpenAPIDocument();
    const expected: ReadonlyArray<[string, string, string]> = [
      ["/sr/device/start", "post", "sr.device.start"],
      ["/sr/device/poll", "post", "sr.device.poll"],
      ["/sr/accounts/push", "post", "sr.accounts.push"],
      ["/sr/accounts", "get", "sr.accounts.list"],
    ];
    for (const [path, method, operationId] of expected) {
      const operation = (
        doc.paths?.[path] as Record<string, { operationId?: string }> | undefined
      )?.[method];
      expect(operation?.operationId).toBe(operationId);
    }
    expect(doc.servers?.[0]?.url).toBe("/api/v1");
  });

  test("push accepts a batch, so bulk upload is one request", async () => {
    const doc = await generateOpenAPIDocument();
    const push = doc.paths?.["/sr/accounts/push"] as {
      post?: { requestBody?: { content?: Record<string, { schema?: unknown }> } };
    };
    const schema = push.post?.requestBody?.content?.["application/json"]?.schema as {
      properties?: { accounts?: { type?: string; maxItems?: number } };
    };
    expect(schema?.properties?.accounts?.type).toBe("array");
    expect(schema?.properties?.accounts?.maxItems).toBe(100);
  });

  test("the list response never exposes credential material", async () => {
    const doc = await generateOpenAPIDocument();
    const serialized = JSON.stringify(
      (doc.paths?.["/sr/accounts"] as { get?: { responses?: unknown } })?.get?.responses,
    );
    expect(serialized).not.toContain("credential");
    expect(serialized).not.toContain("ciphertext");
  });
});
