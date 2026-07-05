import { describe, expect, test } from "bun:test";
import { decryptSecret, encryptSecret } from "../services/coderouter/crypto";
import { mintCallerKey, sha256Hex, verifyCallerKey } from "../services/coderouter/keys";

const encoder = new TextEncoder();

describe("coderouter crypto", () => {
  test("round-trips crv1 envelopes and rejects tampering", async () => {
    const masterKey = Buffer.alloc(32, 7).toString("base64");
    const encrypted = await encryptSecret("provider-secret", masterKey);

    expect(encrypted.startsWith("crv1:")).toBe(true);
    await expect(decryptSecret(encrypted, masterKey)).resolves.toBe("provider-secret");

    const parts = encrypted.split(":");
    const cipher = parts[2] ?? "";
    parts[2] = `${cipher.slice(0, -2)}${cipher.endsWith("AA") ? "BB" : "AA"}`;
    const tampered = parts.join(":");
    await expect(decryptSecret(tampered, masterKey)).rejects.toThrow();
  });
});

describe("coderouter caller keys", () => {
  test("mints worker-compatible crk keys and hashes the full key", async () => {
    const secret = "signing-secret";
    const minted = await mintCallerKey({
      teamId: "team-1",
      kid: "11111111-1111-4111-8111-111111111111",
      issuedAtSeconds: 1_777_000_000,
      secret,
    });

    expect(minted.key.startsWith("crk_")).toBe(true);
    expect(await verifyCallerKey(minted.key, secret)).toEqual({
      v: 1,
      kid: "11111111-1111-4111-8111-111111111111",
      team: "team-1",
      iat: 1_777_000_000,
    });
    expect(await workerStyleVerify(minted.key, secret)).toBe(true);
    expect(await sha256Hex(minted.key)).toMatch(/^[0-9a-f]{64}$/);
  });

  test("rejects tampered keys", async () => {
    const minted = await mintCallerKey({ teamId: "team-1", secret: "signing-secret" });
    const tampered = `${minted.key.slice(0, -1)}${minted.key.endsWith("A") ? "B" : "A"}`;

    expect(await verifyCallerKey(tampered, "signing-secret")).toBeNull();
  });
});

async function workerStyleVerify(key: string, secret: string): Promise<boolean> {
  const dot = key.indexOf(".");
  if (!key.startsWith("crk_") || dot < 0) return false;
  const signed = key.slice(0, dot);
  const signature = key.slice(dot + 1);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const expected = Buffer.from(await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(signed))).toString("base64url");
  if (signature !== expected) return false;
  const payload = JSON.parse(Buffer.from(key.slice(4, dot), "base64url").toString("utf8"));
  return payload.v === 1 && payload.team === "team-1";
}
