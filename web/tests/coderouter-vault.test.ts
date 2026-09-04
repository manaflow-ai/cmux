import { describe, expect, test } from "bun:test";
import { apiKeyAccountId, parseCredential } from "../services/coderouter/accounts";
import { parseVault } from "../services/coderouter/vault";

const codex = {
  provider: "codex",
  accessToken: "access",
  refreshToken: "refresh",
  idToken: "id",
  accountId: "account-1",
  email: "person@example.com",
  expiresAt: Date.now() + 3_600_000,
};

describe("coderouter vault", () => {
  test("accepts complete Codex, OpenCode Go, and Claude credentials", () => {
    expect(parseCredential(codex)).toEqual(codex);
    expect(parseCredential({
      provider: "opencode-go",
      accessToken: "access",
      refreshToken: "refresh",
      accountId: "user-1",
      email: "person@example.com",
      orgId: "org-1",
      orgName: "Personal",
      expiresAt: Date.now() + 3_600_000,
    })?.provider).toBe("opencode-go");
    const claude = {
      provider: "claude",
      accessToken: "access",
      refreshToken: "refresh",
      accountId: "claude-account-1",
      email: "person@example.com",
      subscriptionType: "max",
      expiresAt: Number.MAX_SAFE_INTEGER,
    };
    expect(parseCredential(claude)).toEqual(claude);
    expect(
      parseCredential({ ...claude, subscriptionType: undefined })?.provider,
    ).toBe("claude");
  });

  test("accepts provider API keys, deriving a hashed identity and a label", () => {
    const parsed = parseCredential({ provider: "anthropic-apikey", apiKey: "sk-ant-api03-secret", label: "work" });
    expect(parsed).toEqual({
      provider: "anthropic-apikey",
      apiKey: "sk-ant-api03-secret",
      accountId: apiKeyAccountId("sk-ant-api03-secret"),
      email: "work",
    });
    expect(apiKeyAccountId("sk-ant-api03-secret")).not.toContain("secret");
    expect(parseCredential({ provider: "openai-apikey", apiKey: "sk-x" })?.email).toBe(apiKeyAccountId("sk-x"));
    // A caller-chosen id cannot make the same key a second account.
    expect(parseCredential({ provider: "openai-apikey", apiKey: "sk-x", accountId: "mine" })?.accountId)
      .toBe(apiKeyAccountId("sk-x"));
    expect(parseCredential({ provider: "openai-apikey", apiKey: "" })).toBeNull();
    expect(parseCredential({ provider: "openai-apikey" })).toBeNull();
  });

  test("rejects incomplete secrets before they reach Stack", () => {
    expect(parseCredential({ ...codex, refreshToken: "" })).toBeNull();
    expect(parseCredential({ ...codex, expiresAt: "soon" })).toBeNull();
    expect(parseCredential({ ...codex, provider: "gemini" })).toBeNull();
  });

  test("fails closed on malformed Stack server metadata", () => {
    expect(() => parseVault({
      version: 1,
      accounts: {
        "account-1": { revision: 1, credential: { ...codex, refreshToken: "" } },
      },
    })).toThrow("invalid coderouter vault account");
  });

  test("treats an absent vault as an empty versioned vault", () => {
    expect(parseVault(undefined)).toEqual({ version: 1, accounts: {} });
  });
});
