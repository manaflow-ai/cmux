import { describe, expect, test } from "bun:test";
import { parseCredential } from "../services/coderouter/accounts";
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
  test("accepts complete Codex and OpenCode Go credentials", () => {
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
  });

  test("rejects incomplete secrets before they reach Stack", () => {
    expect(parseCredential({ ...codex, refreshToken: "" })).toBeNull();
    expect(parseCredential({ ...codex, expiresAt: "soon" })).toBeNull();
    expect(parseCredential({ ...codex, provider: "claude" })).toBeNull();
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
