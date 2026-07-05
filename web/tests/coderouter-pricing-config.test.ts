import { describe, expect, test } from "bun:test";
import { priceUsageMicros } from "../services/coderouter/pricing";
import { poolConfigFromRows } from "../services/coderouter/repository";

describe("coderouter pricing", () => {
  test("rounds each token component up and supports date-suffixed model ids", () => {
    expect(priceUsageMicros("claude-sonnet-4-5-20250929", {
      inputTokens: 1,
      outputTokens: 1,
      cacheReadTokens: 1,
      cacheWriteTokens: 1,
      estimated: false,
    })).toBe(23);
    expect(priceUsageMicros("unknown-model", {
      inputTokens: 1,
      outputTokens: 1,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
      estimated: true,
    })).toBeNull();
  });
});

describe("coderouter pool config assembly", () => {
  test("matches the pinned worker wire shape without leaking provider emails", () => {
    const config = poolConfigFromRows({
      teamId: "team-1",
      family: "anthropic",
      balanceMicros: 123,
      managedEnabled: true,
      configVersion: 42,
      keys: [{
        id: "key-1",
        revokedAt: null,
        policy: { allowedClasses: ["oauth", "byok", "invalid"] } as never,
      }],
      credentials: [{
        id: "credential-1",
        kind: "api_key",
        class: "byok",
        status: "active",
        label: "Team key",
        providerAccountId: null,
        encryptedSecret: "crv1:iv:ciphertext",
      }, {
        id: "credential-2",
        kind: "oauth",
        class: "oauth",
        status: "needs_reauth",
        label: null,
        providerAccountId: "acct-1",
        encryptedSecret: null,
      }],
    });

    expect(config).toEqual({
      poolId: "team-1:anthropic",
      teamId: "team-1",
      family: "anthropic",
      configVersion: 42,
      keys: [{ kid: "key-1", revoked: false, policy: { allowedClasses: ["oauth", "byok"] } }],
      credentials: [{
        id: "credential-1",
        kind: "api_key",
        class: "byok",
        status: "active",
        label: "Team key",
        encryptedSecret: "crv1:iv:ciphertext",
      }, {
        id: "credential-2",
        kind: "oauth",
        class: "oauth",
        status: "needs_reauth",
        providerAccountId: "acct-1",
      }],
      managed: { enabled: true },
      balanceMicros: 123,
    });
  });
});
