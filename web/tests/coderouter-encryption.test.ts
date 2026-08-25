import { describe, expect, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  decryptCredential,
  encryptCredential,
  coalescingCredentialsProvider,
  type CredentialKeyService,
  type EncryptedCredential,
} from "../services/coderouter/encryption";
import type { CodeRouterCredential } from "../services/coderouter/types";

const credential: CodeRouterCredential = {
  provider: "codex",
  accessToken: "access-secret-value",
  refreshToken: "refresh-secret-value",
  idToken: "id-secret-value",
  accountId: "provider-account",
  email: "person@example.com",
  expiresAt: 1_900_000_000_000,
};

describe("coderouter credential envelope encryption", () => {
  test("round trips without exposing provider secrets", async () => {
    const keys = fakeKeys();
    const encrypted = await encrypt(keys);

    expect(await decryptCredential(encrypted, keys)).toEqual(credential);
    const serialized = JSON.stringify(encrypted);
    expect(serialized).not.toContain(credential.accessToken);
    expect(serialized).not.toContain(credential.refreshToken);
    expect(serialized).not.toContain(credential.idToken);
  });

  test("rejects tampered ciphertext", async () => {
    const keys = fakeKeys();
    const encrypted = await encrypt(keys);
    const bytes = Buffer.from(encrypted.ciphertext, "base64");
    bytes[0] ^= 1;

    await expect(
      decryptCredential({
        ...encrypted,
        ciphertext: bytes.toString("base64"),
      }, keys),
    ).rejects.toThrow();
  });

  test("binds ciphertext to tenant and revision through AAD", async () => {
    const keys = fakeKeys();
    const encrypted = await encrypt(keys);

    await expect(
      decryptCredential({ ...encrypted, teamId: "other-team" }, keys),
    ).rejects.toThrow();
    await expect(
      decryptCredential({
        ...encrypted,
        credentialRevision: encrypted.credentialRevision + 1,
      }, keys),
    ).rejects.toThrow();
  });

  test("rejects a data key from the wrong KMS envelope", async () => {
    const encrypted = await encrypt(fakeKeys());
    await expect(
      decryptCredential(encrypted, fakeKeys()),
    ).rejects.toThrow();
  });

  test("does not include provider secrets in KMS failures", async () => {
    for (const failure of [
      "KMS access denied",
      "KMS request timed out",
      "KMS throttling exception",
    ]) {
      const unavailable: CredentialKeyService = {
        async generateDataKey() {
          throw new Error(failure);
        },
        async decryptDataKey() {
          throw new Error(failure);
        },
      };
      let message = "";
      try {
        await encrypt(unavailable);
      } catch (error) {
        message = error instanceof Error ? error.message : String(error);
      }
      expect(message).toContain(failure);
      expect(message).not.toContain(credential.accessToken);
      expect(message).not.toContain(credential.refreshToken);
      expect(message).not.toContain(credential.idToken);
    }
  });
});

describe("coderouter Vercel OIDC credentials", () => {
  test("coalesces parallel AWS role exchanges and refreshes before expiry", async () => {
    let calls = 0;
    let now = 1_000;
    const provider = coalescingCredentialsProvider(async () => {
      calls++;
      await Promise.resolve();
      return {
        accessKeyId: `access-${calls}`,
        secretAccessKey: "secret",
        expiration: new Date(now + 10 * 60 * 1_000),
      };
    }, () => now);
    const first = await Promise.all([provider(), provider(), provider()]);
    expect(calls).toBe(1);
    expect(first.map((value) => value.accessKeyId)).toEqual([
      "access-1",
      "access-1",
      "access-1",
    ]);
    now += 6 * 60 * 1_000;
    expect((await provider()).accessKeyId).toBe("access-2");
    expect(calls).toBe(2);
  });
});

async function encrypt(keys: CredentialKeyService): Promise<EncryptedCredential> {
  return await encryptCredential({
    accountId: "00000000-0000-4000-8000-000000000001",
    teamId: "team-1",
    provider: "codex",
    credentialRevision: 1,
    credential,
    keyId: "test-key",
    keys,
  });
}

function fakeKeys(): CredentialKeyService {
  const dataKey = randomBytes(32);
  return {
    async generateDataKey() {
      return {
        plaintext: Buffer.from(dataKey),
        encrypted: Buffer.from(dataKey),
      };
    },
    async decryptDataKey({ encrypted }) {
      if (!Buffer.from(encrypted).equals(dataKey)) {
        throw new Error("wrong test key");
      }
      return Buffer.from(dataKey);
    },
  };
}
