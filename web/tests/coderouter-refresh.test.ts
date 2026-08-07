import { describe, expect, test } from "bun:test";
import {
  CodeRouterCredentialBroken,
  CodeRouterRefreshBusy,
  createCredentialRefresher,
  isTerminalRefreshError,
  refreshProviderCredential,
  type CredentialRefreshDependencies,
} from "../services/coderouter/refresh";
import type { EncryptedCredential } from "../services/coderouter/encryption";
import type { CodexCredential } from "../services/coderouter/types";

const expired: CodexCredential = {
  provider: "codex",
  accessToken: "old-access",
  refreshToken: "old-refresh",
  idToken: "old-id",
  accountId: "provider-account",
  email: "person@example.com",
  expiresAt: 1,
};
const envelope: EncryptedCredential = {
  accountId: "00000000-0000-4000-8000-000000000001",
  teamId: "team-1",
  provider: "codex",
  credentialRevision: 1,
  algorithm: "aes-256-gcm",
  ciphertext: "ciphertext",
  nonce: "nonce",
  authTag: "tag",
  encryptedDataKey: "key",
  kmsKeyId: "kms-key",
};

describe("coderouter credential refresh coordination", () => {
  test("only one simultaneous refresh claims an account", async () => {
    let leaseAvailable = true;
    let releaseProvider!: () => void;
    const providerGate = new Promise<void>((resolve) => {
      releaseProvider = resolve;
    });
    let claimed!: () => void;
    const didClaim = new Promise<void>((resolve) => {
      claimed = resolve;
    });
    const dependencies = fakeDependencies({
      claim: async () => {
        if (!leaseAvailable) return null;
        leaseAvailable = false;
        claimed();
        return "lease-1";
      },
      refresh: async () => {
        await providerGate;
        return refreshed();
      },
    });
    const refresh = createCredentialRefresher(dependencies);
    const first = refresh(input());
    await didClaim;
    await expect(refresh(input())).rejects.toBeInstanceOf(CodeRouterRefreshBusy);
    releaseProvider();
    expect((await first).refreshToken).toBe("new-refresh");
  });

  test("an abandoned lease becomes claimable after expiry", async () => {
    let now = 0;
    let leaseExpiresAt = 1_000;
    const dependencies = fakeDependencies({
      claim: async () => {
        if (leaseExpiresAt > now) return null;
        leaseExpiresAt = now + 30_000;
        return "replacement-lease";
      },
    });
    const refresh = createCredentialRefresher(dependencies);
    await expect(refresh(input())).rejects.toBeInstanceOf(CodeRouterRefreshBusy);
    now = 1_001;
    expect((await refresh(input())).accessToken).toBe("new-access");
  });

  test("persists a rotated provider refresh token at the next revision", async () => {
    let completed:
      | Parameters<CredentialRefreshDependencies["complete"]>[0]
      | undefined;
    const refresh = createCredentialRefresher(fakeDependencies({
      complete: async (value) => {
        completed = value;
      },
    }));
    const result = await refresh(input());
    expect(result.refreshToken).toBe("new-refresh");
    expect(completed?.credential.refreshToken).toBe("new-refresh");
    expect(completed?.encrypted.credentialRevision).toBe(2);
  });

  test("marks invalid provider refresh tokens broken without returning them", async () => {
    let terminalFailure = false;
    const refresh = createCredentialRefresher(fakeDependencies({
      refresh: async () => {
        throw new Error("invalid_grant");
      },
      isTerminal: () => true,
      failureCode: () => "invalid_grant",
      fail: async (_account, _lease, terminal, code) => {
        terminalFailure = terminal && code === "invalid_grant";
      },
    }));
    await expect(refresh(input())).rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(terminalFailure).toBe(true);
  });

  test("does not return a refreshed token when the RDS CAS fails", async () => {
    let failedLease = false;
    const refresh = createCredentialRefresher(fakeDependencies({
      complete: async () => {
        throw new Error("database unavailable");
      },
      fail: async () => {
        failedLease = true;
      },
    }));
    await expect(refresh(input())).rejects.toThrow("database unavailable");
    expect(failedLease).toBe(true);
  });
});

describe("coderouter provider refresh responses", () => {
  test("accepts and uses provider refresh-token rotation", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      Response.json({
        access_token: "rotated-access",
        refresh_token: "rotated-refresh",
        id_token: "rotated-id",
        expires_in: 3600,
      })) as typeof fetch;
    try {
      const result = await refreshProviderCredential(expired);
      if (result.provider !== "codex") throw new Error("unexpected provider");
      expect(result.accessToken).toBe("rotated-access");
      expect(result.refreshToken).toBe("rotated-refresh");
      expect(result.idToken).toBe("rotated-id");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  test("classifies an invalidated refresh token as terminal", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = (async () =>
      Response.json(
        { error: { code: "invalid_grant" } },
        { status: 400 },
      )) as typeof fetch;
    try {
      let failure: unknown;
      try {
        await refreshProviderCredential(expired);
      } catch (error) {
        failure = error;
      }
      expect(isTerminalRefreshError(failure)).toBe(true);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});

function input() {
  return {
    teamId: "team-1",
    accountId: envelope.accountId,
    expectedRevision: 1,
  };
}

function refreshed(): CodexCredential {
  return {
    ...expired,
    accessToken: "new-access",
    refreshToken: "new-refresh",
    idToken: "new-id",
    expiresAt: Date.now() + 3_600_000,
  };
}

function fakeDependencies(
  overrides: Partial<CredentialRefreshDependencies> = {},
): CredentialRefreshDependencies {
  return {
    read: async () => ({ envelope, credential: expired }),
    decrypt: async () => expired,
    claim: async () => "lease-1",
    release: async () => {},
    refresh: async () => refreshed(),
    encrypt: async (value) => ({
      ...envelope,
      credentialRevision: value.credentialRevision,
    }),
    complete: async () => {},
    fail: async () => {},
    isTerminal: () => false,
    failureCode: () => "refresh_unavailable",
    ...overrides,
  };
}
